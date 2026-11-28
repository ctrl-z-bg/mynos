(* sshd: MyNOS's SSH server. Each session runs sh with a console of its
   own, as a terminal window gives one (gui/terminal.ml): a console/1
   service that sshd serves, named in sh's MYNOS_CONSOLE. With a terminal
   (pty-req) the console edits the line as the window does (Backspace,
   Ctrl-U, Ctrl-D; Ctrl-C ends the program sh waits for) and turns "\n"
   into "\r\n"; without one, bytes go through as they are.

     sshd [-p PORT] [-v]

   Who may log in: /disk/ssh/passwd, lines "USER PASSWORD" (in clear, for
   now), and /disk/ssh/authorized_keys, OpenSSH's lines of public keys
   (ssh-ed25519), good for any user name: MyNOS has one user. The host
   key, /disk/ssh/ssh_host_ed25519_key, is made the first time. *)

let verbose = ref false
let log m = Printf.printf "sshd: %s\n%!" m

let host_key_file = Filename.concat Net_io.ssh_dir "ssh_host_ed25519_key"
let passwd_file = Filename.concat Net_io.ssh_dir "passwd"
let keys_file = Filename.concat Net_io.ssh_dir "authorized_keys"

let host_key () =
  if Sys.file_exists host_key_file then
    match Ssh_keys.of_file (Net_io.read_file host_key_file) with
    | Ok k -> k
    | Error e -> failwith (host_key_file ^ ": " ^ e)
  else begin
    Net_io.ensure_dir ();
    let k = Ssh_keys.generate ~comment:"root@mynos" in
    Net_io.write_file host_key_file (Ssh_keys.to_file k);
    Net_io.write_file ~perm:0o644 (host_key_file ^ ".pub") (Ssh_keys.pub_line k ^ "\n");
    log ("made the host key " ^ host_key_file);
    k
  end

let passwords () =
  List.filter_map (fun l ->
      let l = String.trim l in
      if l = "" || l.[0] = '#' then None
      else match String.index_opt l ' ' with
        | Some i -> Some (String.sub l 0 i, String.trim (String.sub l (i + 1) (String.length l - i - 1)))
        | None -> None) (Ssh_keys.read_lines passwd_file)

let same a b = Poly1305.equal (Sha2.sha256 a) (Sha2.sha256 b)

(* {1 The sessions' consoles} *)

type console = {
  name : string;
  port : int;
  mutable busy : bool;
  lock : Mutex.t;
  (* the session's, while busy *)
  input : Buffer.t;               (* given to readers *)
  mutable line : string;          (* being edited (canonical mode) *)
  mutable eof : bool;               (* Ctrl-D: one read gets the end *)
  mutable closed : bool;            (* the channel's EOF: every read *)
  mutable pending : (int * int * float) list;   (* channel, max, deadline *)
  mutable canon : bool;
  mutable echo : bool;
  mutable isig : bool;
  mutable vmin : int;
  mutable vtime : int;
  mutable foreground : int;
  mutable size : int * int;
  mutable pty : bool;
  mutable out : string -> unit;
}

let consoles : console list ref = ref []
let consoles_lock = Mutex.create ()

let reply ch s =
  (try Mynos.send ch s with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let read_reply s = Console.reply (Console.Read 0) s

(* give waiting reads what there is (under the lock) *)
let serve_reads c =
  let now = Mynos.uptime () in
  c.pending <- List.filter (fun (chn, max, deadline) ->
      if Buffer.length c.input > 0 then begin
        let n = min max (Buffer.length c.input) in
        let s = Buffer.sub c.input 0 n in
        let rest = Buffer.sub c.input n (Buffer.length c.input - n) in
        Buffer.clear c.input; Buffer.add_string c.input rest;
        reply chn (read_reply s); false
      end else if c.eof || c.closed then (c.eof <- false; reply chn (read_reply ""); false)
      else if deadline > 0. && now >= deadline then (reply chn (read_reply ""); false)
      else true) c.pending

(* output to the client: with a terminal, "\n" as "\r\n" *)
let onlcr s =
  if not (String.contains s '\n') then s else begin
    let b = Buffer.create (String.length s + 16) in
    String.iteri (fun i ch ->
        if ch = '\n' && (i = 0 || s.[i - 1] <> '\r') then Buffer.add_string b "\r\n"
        else Buffer.add_char b ch) s;
    Buffer.contents b
  end

let write c s = c.out (if c.pty then onlcr s else s)

(* the client's keys (under the lock) *)
let keys c s =
  let n = String.length s in
  let i = ref 0 in
  let kill_foreground () =
    let pid = c.foreground in
    c.foreground <- 0; c.line <- ""; Buffer.clear c.input;
    write c "^C\n";
    (try Mynos.kill pid with Mynos.Error _ -> ()) in
  while !i < n do
    let ch = s.[!i] in
    incr i;
    if c.pty && ch = '\003' && c.isig && c.foreground > 0 then kill_foreground ()
    else if not c.pty || not c.canon then begin
      Buffer.add_char c.input ch;
      if c.pty && c.echo && ch >= ' ' then write c (String.make 1 ch)
    end else
      match ch with
      | '\r' | '\n' ->
        if ch = '\n' && !i >= 2 && s.[!i - 2] = '\r' then ()   (* \r\n: one *)
        else begin
          if c.echo then write c "\n";
          Buffer.add_string c.input (c.line ^ "\n"); c.line <- ""
        end
      | '\127' | '\b' ->
        let l = String.length c.line in
        if l > 0 then begin
          (* a whole UTF-8 character *)
          let j = ref (l - 1) in
          while !j > 0 && Char.code c.line.[!j] land 0xC0 = 0x80 do decr j done;
          c.line <- String.sub c.line 0 !j;
          if c.echo then write c "\b \b"
        end
      | '\021' ->                                          (* Ctrl-U *)
        if c.echo then
          String.iter (fun ch -> if Char.code ch land 0xC0 <> 0x80 then write c "\b \b") c.line;
        c.line <- ""
      | '\004' ->                                          (* Ctrl-D *)
        if c.line = "" then c.eof <- true
        else (Buffer.add_string c.input c.line; c.line <- "")
      | '\027' ->
        (* an escape sequence (the arrows...): nothing in a line *)
        if !i < n && (s.[!i] = '[' || s.[!i] = 'O') then begin
          incr i;
          while !i < n && not (s.[!i] >= '@' && s.[!i] <= '~') do incr i done;
          incr i
        end
      | ch when Char.code ch < 0x20 -> ()
      | ch -> c.line <- c.line ^ String.make 1 ch; if c.echo then write c (String.make 1 ch)
  done;
  serve_reads c

let handle c chn msg =
  match Console.decode msg with
  | Error answer -> reply chn answer
  | Ok (Console.Protocol.Request req) ->
    Mutex.lock c.lock;
    let after = ref None in
    (try
       let ok (type a) (r : a Console.request) (v : a) = reply chn (Console.reply r v) in
       match req with
       | Console.Read len ->
         let deadline =
           if not c.canon && c.vmin = 0 && c.vtime > 0
           then Mynos.uptime () +. float c.vtime /. 10. else 0. in
         c.pending <- c.pending @ [ (chn, max 1 len, deadline) ];
         serve_reads c
       | Console.Mode (mode, vm, vt) as r ->
         c.canon <- mode land Console.canon <> 0; c.echo <- mode land Console.echo <> 0;
         c.isig <- mode land Console.nosig = 0;
         c.vmin <- vm; c.vtime <- vt;
         if c.canon then c.line <- "";
         ok r ()
       | Console.Keymap _ as r -> ok r Console.layout_us
       | Console.Foreground pid as r ->
         let caller = try Mynos.channel_peer chn with Mynos.Error _ -> -1 in
         let child = List.exists (fun (p : Mynos.process) -> p.p_pid = pid && p.parent = caller)
             (try Mynos.processes () with Mynos.Error _ -> []) in
         if pid = 0 || child then c.foreground <- pid;
         ok r ()
       | Console.Write data as r ->
         (* written after the lock: the client's window may make it wait *)
         after := Some (fun () -> write c data; reply chn (Console.reply r ()))
       | Console.Size as r -> ok r c.size
       | Console.Ready as r -> ok r (Buffer.length c.input > 0 || c.eof || c.closed)
     with e -> Mutex.unlock c.lock; raise e);
    Mutex.unlock c.lock;
    Option.iter (fun f -> f ()) !after

let serve c =
  while true do
    match Mynos.listen c.port with
    | chn ->
      (match Mynos.recv ~timeout:1.0 chn with
       | msg -> if c.busy then handle c chn msg else reply chn (Console.error_reply "no session")
       | exception Mynos.Error _ -> (try Mynos.free_channel chn with Mynos.Error _ -> ()))
    | exception Mynos.Error _ -> ()
  done

(* a console for a session: a free one, or a new name (the registry keeps
   names for the process's life: they are used again) *)
let take_console () =
  Mutex.lock consoles_lock;
  let c = match List.find_opt (fun c -> not c.busy) !consoles with
    | Some c -> c
    | None ->
      let name = Printf.sprintf "ssh%d.%d" (Mynos.getpid ()) (List.length !consoles) in
      let c = { name; port = Mynos.register name; busy = false; lock = Mutex.create ();
                input = Buffer.create 256; line = ""; eof = false; closed = false; pending = [];
                canon = true; echo = true; isig = true; vmin = 1; vtime = 0; foreground = 0;
                size = (80, 24); pty = false; out = ignore } in
      consoles := c :: !consoles;
      ignore (Thread.create serve c);
      c in
  c.busy <- true;
  Mutex.unlock consoles_lock;
  c

let release c =
  Mutex.lock c.lock;
  List.iter (fun (chn, _, _) -> reply chn (read_reply "")) c.pending;
  c.pending <- []; Buffer.clear c.input; c.line <- ""; c.eof <- false; c.closed <- false;
  c.foreground <- 0;
  c.canon <- true; c.echo <- true; c.isig <- true; c.out <- ignore;
  Mutex.unlock c.lock;
  Mutex.lock consoles_lock; c.busy <- false; Mutex.unlock consoles_lock

(* a process and all it started *)
let kill_tree pid =
  let ps = try Mynos.processes () with Mynos.Error _ -> [] in
  let rec below p = p :: List.concat_map (fun (q : Mynos.process) ->
      if q.parent = p then below q.p_pid else []) ps in
  List.iter (fun p -> try Mynos.kill p with Mynos.Error _ -> ()) (List.rev (below pid))

let start ~user ~pty ~command ~output ~errors:_ ~exited =
  let c = take_console () in
  Mutex.lock c.lock;
  c.pty <- pty <> None;
  c.size <- (match pty with Some (_, cols, rows) -> (cols, rows) | None -> (80, 24));
  c.out <- output;
  Mutex.unlock c.lock;
  let env = Array.append
      (Array.of_list (List.filter (fun kv ->
           not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                  [ "MYNOS_CONSOLE"; "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR"; "USER" ]))
           (Array.to_list (Mynos.environment ()))))
      [| "MYNOS_CONSOLE=" ^ c.name; "PATH=/disk/bin:/"; "HOME=/disk"; "OCAMLLIB=/"; "USER=" ^ user |] in
  let argv = match command with
    | None -> [| "ocamlrun"; "/sh.byte" |]
    | Some cmd -> [| "ocamlrun"; "/sh.byte"; "-c"; cmd |] in
  let pid = try Mynos.spawn ~env "ocamlrun" argv with e -> release c; raise e in
  if !verbose then log (Printf.sprintf "%s: session %s, sh %d" user c.name pid);
  let stopped = ref false in
  ignore (Thread.create (fun () ->
      let code = match Mynos.wait pid with
        | Mynos.Exited n -> n | Mynos.Signaled _ -> 255
        | exception Mynos.Error _ -> 255 in
      release c;
      if not !stopped then exited code) ());
  { Ssh_server.input = (fun d -> Mutex.lock c.lock; keys c d; Mutex.unlock c.lock);
    input_eof = (fun () -> Mutex.lock c.lock; c.closed <- true; serve_reads c; Mutex.unlock c.lock);
    resize = (fun cols rows -> Mutex.lock c.lock; c.size <- (cols, rows); Mutex.unlock c.lock);
    stop = (fun () -> stopped := true; kill_tree pid) }

let backend = {
  Ssh_server.password = (fun ~user pw ->
      List.exists (fun (u, p) -> u = user && same p pw) (passwords ()));
  key = (fun ~user:_ pub -> List.mem pub (Ssh_keys.authorized keys_file));
  failed = (fun () -> Thread.delay 1.0);
  start;
  log = (fun m -> if !verbose then log m);
}

let main args =
  let port = ref 22 in
  let rec opts = function
    | "-p" :: p :: rest -> port := int_of_string p; opts rest
    | "-v" :: rest -> verbose := true; opts rest
    | [] -> ()
    | _ -> prerr_endline "usage: sshd [-p PORT] [-v]"; exit 2 in
  opts args;
  let key = host_key () in
  if passwords () = [] && Ssh_keys.authorized keys_file = [] then begin
    prerr_endline ("sshd: nobody may log in: write " ^ passwd_file
                   ^ " (lines \"USER PASSWORD\") or " ^ keys_file ^ " (public keys)");
    exit 1
  end;
  (try Sys.chdir "/disk" with Sys_error _ -> ());
  let ls = try Net_io.call (Net.Listen !port)
    with e -> prerr_endline ("sshd: port " ^ string_of_int !port ^ ": " ^ Net_io.error e); exit 1 in
  log (Printf.sprintf "listening on port %d, host key %s" !port (Ssh_keys.fingerprint key.pub));
  let accept = Net.connect () in
  while true do
    match Net.call accept (Net.Accept ls) with
    | (sock, addr, rport) ->
      ignore (Thread.create (fun () ->
          let from = Printf.sprintf "%s:%d" addr rport in
          log ("connection from " ^ from);
          let io = Net_io.io sock in
          (* two minutes to log in (OpenSSH's LoginGraceTime), then no limit *)
          let timeout ms = try Net_io.call (Net.Set_timeout (sock, ms)) with _ -> () in
          timeout 120_000;
          (try
             let tr = Ssh_transport.create ~host_seed:key.seed Ssh_transport.Server io in
             Ssh_server.serve ~authenticated:(fun () -> timeout 0) tr backend
           with
           | Ssh_transport.Disconnected m -> log (from ^ ": " ^ m)
           | Ssh_server.Refused m -> log (from ^ ": refused: " ^ m)
           | e -> log (from ^ ": " ^ Printexc.to_string e));
          io.close ()) ())
    | exception e -> log ("accept: " ^ Net_io.error e); Thread.delay 1.0
  done
