(* ssh: MyNOS's SSH client.

     ssh [-p PORT] [-l USER] [-i KEYFILE] [-t|-T] [USER@]HOST [COMMAND...]

   Keys: /disk/ssh/id_ed25519 (ssh-keygen makes it) and those of -i, in
   OpenSSH's format, not encrypted; then the password, asked. The
   servers' keys: /disk/ssh/known_hosts, written the first time (after a
   yes), checked every other: a changed key is refused. Without a command,
   a shell with a terminal ("vt100", the window's size), in raw mode; ~.
   at the start of a line disconnects. *)

let known_file = Filename.concat Net_io.ssh_dir "known_hosts"
let id_file = Filename.concat Net_io.ssh_dir "id_ed25519"

let die m = prerr_endline ("ssh: " ^ m); exit 255

let console_mode ~raw =
  try
    if raw then Mynos.console_mode ~canon:false ~echo:false ~isig:false ~vmin:1 ~vtime:0 ()
    else Mynos.console_mode ~canon:true ~echo:true ~isig:true ()
  with Mynos.Error _ -> ()

(* a password, typed unseen: keys one by one without echo (consoled
   echoes a line being edited whatever the mode says: mynos-tk0z) *)
let read_secret () =
  (try Mynos.console_mode ~canon:false ~echo:false ~isig:false ~vmin:1 ~vtime:0 ()
   with Mynos.Error _ -> ());
  let b = Buffer.create 32 and one = Bytes.create 1 in
  let rec go () =
    match Unix.read Unix.stdin one 0 1 with
    | 0 -> if Buffer.length b = 0 then None else Some (Buffer.contents b)
    | _ ->
      (match Bytes.get one 0 with
       | '\r' | '\n' -> Some (Buffer.contents b)
       | '\003' | '\004' -> None
       | '\127' | '\b' -> Buffer.truncate b (max 0 (Buffer.length b - 1)); go ()
       | '\021' -> Buffer.clear b; go ()
       | c -> Buffer.add_char b c; go ())
    | exception Unix.Unix_error _ -> None in
  let r = go () in
  console_mode ~raw:false;
  print_newline ();
  r

let ask prompt ~echo =
  print_string prompt; flush stdout;
  if echo then (try Some (input_line stdin) with End_of_file -> None)
  else read_secret ()

let check_host host port pub =
  match Ssh_keys.known known_file host port with
  | l when List.mem pub l -> true
  | _ :: _ ->
    prerr_endline "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@";
    prerr_endline "@  WARNING: THE HOST KEY HAS CHANGED: someone may be in   @";
    prerr_endline "@  the middle, or the server was installed again.         @";
    prerr_endline "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@";
    prerr_endline ("Its key now: ED25519 " ^ Ssh_keys.fingerprint pub);
    prerr_endline ("If the change is expected, take its line out of " ^ known_file ^ ".");
    false
  | [] ->
    Printf.printf "The host %s is not known.\nIts key: ED25519 %s\n" (Ssh_keys.host_name host port)
      (Ssh_keys.fingerprint pub);
    (match ask "Trust it and remember it (yes/no)? " ~echo:true with
     | Some a when String.lowercase_ascii (String.trim a) = "yes" ->
       Net_io.ensure_dir ();
       Ssh_keys.remember known_file host port pub;
       Printf.printf "Remembered in %s.\n%!" known_file;
       true
     | _ -> false)

let load_key f =
  match Ssh_keys.of_file (Net_io.read_file f) with
  | Ok k -> Some k
  | Error e -> prerr_endline ("ssh: " ^ f ^ ": " ^ e); None
  | exception Sys_error _ -> None

let main args =
  let port = ref 22 and user = ref None and keys = ref [] and tty = ref None in
  let rec opts = function
    | "-p" :: p :: rest -> port := (try int_of_string p with _ -> die "bad port"); opts rest
    | "-l" :: u :: rest -> user := Some u; opts rest
    | "-i" :: f :: rest -> keys := f :: !keys; opts rest
    | "-t" :: rest -> tty := Some true; opts rest
    | "-T" :: rest -> tty := Some false; opts rest
    | dest :: rest when dest <> "" && dest.[0] <> '-' -> dest, rest
    | _ -> prerr_endline "usage: ssh [-p PORT] [-l USER] [-i KEYFILE] [-t|-T] [USER@]HOST [COMMAND...]";
      exit 2 in
  let dest, command = opts args in
  let host = match String.rindex_opt dest '@' with
    | Some i -> user := Some (String.sub dest 0 i); String.sub dest (i + 1) (String.length dest - i - 1)
    | None -> dest in
  let user = match !user with
    | Some u -> u | None -> Option.value (Sys.getenv_opt "USER") ~default:"root" in
  let command = match command with [] -> None | l -> Some (String.concat " " l) in
  let pty = Option.value !tty ~default:(command = None) in
  let keys = List.filter_map load_key (List.rev !keys @ (if Sys.file_exists id_file then [ id_file ] else [])) in
  let sock = try Net_io.connect host !port
    with e -> die (Printf.sprintf "%s port %d: %s" host !port (Net_io.error e)) in
  let io = Net_io.io sock in
  let code =
    try
      let tr = Ssh_transport.create ~check_host:(check_host host !port) Ssh_transport.Client io in
      Ssh_client.authenticate tr ~user
        { keys;
          password = (fun () -> ask (Printf.sprintf "%s@%s's password: " user host) ~echo:false);
          banner = (fun b -> print_string b; flush stdout) };
      let size = Console.size () in
      let s = Ssh_client.open_session tr ~command
          ~pty:(if pty then Some ("vt100", fst size, snd size) else None) in
      if pty then console_mode ~raw:true;
      let finished = ref false in
      (* the keys, to the server; ~. after a new line disconnects *)
      ignore (Thread.create (fun () ->
          let buf = Bytes.create 1024 in
          let line_start = ref true and tilde = ref false in
          let rec go () =
            let got = Net_io.read_input buf (fun () -> !finished) in
            let n = String.length got in
            if n = 0 then (if not !finished then Ssh_client.send_eof s)
            else begin
              let buf = Bytes.of_string got in
              let b = Buffer.create n in
              let quit = ref false in
              for i = 0 to n - 1 do
                let c = Bytes.get buf i in
                if pty && !tilde then begin
                  tilde := false;
                  if c = '.' then quit := true
                  else (if c <> '~' then Buffer.add_char b '~'; Buffer.add_char b c)
                end else if pty && !line_start && c = '~' then tilde := true
                else Buffer.add_char b c;
                line_start := (c = '\r' || c = '\n')
              done;
              if !quit then begin
                console_mode ~raw:false;
                print_string "\r\nConnection closed.\r\n"; flush stdout;
                Ssh_transport.disconnect_with tr "disconnected by user"; exit 255
              end;
              if Buffer.length b = 0 || Ssh_client.send_input s (Buffer.contents b) then go ()
            end in
          go ()) ());
      (* the window's size, as it changes *)
      if pty then ignore (Thread.create (fun () ->
          let last = ref size in
          while not !finished do
            Thread.delay 1.0;
            let now = Console.size () in
            if now <> !last then begin
              last := now; (try Ssh_client.resize s (fst now) (snd now) with _ -> ())
            end
          done) ());
      let code = Ssh_client.run s
          ~output:(fun d -> print_string d; flush stdout)
          ~errors:(fun d -> prerr_string d; flush stderr) in
      finished := true;
      Ssh_transport.disconnect_with tr "disconnected by user";
      code
    with
    | Ssh_transport.Disconnected m -> console_mode ~raw:false; prerr_endline ("\nssh: " ^ m); 255
    | Ssh_client.Failed m -> console_mode ~raw:false; prerr_endline ("ssh: " ^ m); 255 in
  if pty then console_mode ~raw:false;
  io.close ();
  exit code
