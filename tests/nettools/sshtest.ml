(* nettools' SSH client against its server, on the host, over a pair of
   sockets: the key exchange, both authentications, a shell with a
   terminal, a command, its exit status, a lot of data (the windows), the
   key files. The real interop (OpenSSH) is in MyNOS. *)

let fails = ref 0
let check name ok = if ok then Printf.printf "ok   %s\n%!" name
  else (incr fails; Printf.printf "FAIL %s\n%!" name)

(* no SIGPIPE (MyNOS has no signals): a write to a closed socket fails *)
let () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore

(* close: shut down (it wakes a thread reading); the fd is closed once,
   by who made it *)
let io fd = {
  Ssh_transport.read = (fun () ->
      let b = Bytes.create 16384 in
      match Unix.read fd b 0 16384 with n -> Bytes.sub_string b 0 n | exception _ -> "");
  write = (fun s -> ignore (Unix.write_substring fd s 0 (String.length s)));
  close = (fun () -> try Unix.shutdown fd Unix.SHUTDOWN_ALL with _ -> ());
}

let host = Ssh_keys.generate ~comment:"host"
let alice = Ssh_keys.generate ~comment:"alice@test"
let mallory = Ssh_keys.generate ~comment:"mallory"

let backend = {
  Ssh_server.password = (fun ~user pw -> user = "alice" && pw = "secret");
  key = (fun ~user pub -> user = "alice" && pub = alice.pub);
  failed = (fun () -> ());
  log = (fun m -> Printf.printf "     server: %s\n%!" m);
  start = (fun ~user:_ ~pty ~command ~output ~errors ~exited ->
      match command with
      | Some c ->
        output ("ran " ^ c ^ "\n"); errors "to stderr\n"; exited 3;
        { input = ignore; input_eof = ignore; resize = (fun _ _ -> ()); stop = ignore }
      | None ->
        (* as sh's console: the output from another thread than the
           connection's reader (which must stay free for window adjusts) *)
        let q = Queue.create () and m = Mutex.create () and c = Condition.create () in
        let push e = Mutex.lock m; Queue.push e q; Condition.signal c; Mutex.unlock m in
        let total = ref 0 in
        let rec work () =
          Mutex.lock m;
          while Queue.is_empty q do Condition.wait c m done;
          let e = Queue.pop q in
          Mutex.unlock m;
          match e with
          | `Out s -> output s; work ()
          | `In d -> total := !total + String.length d; output (String.uppercase_ascii d); work ()
          | `End -> output (Printf.sprintf "got %d\n" !total); exited 0 in
        ignore (Thread.create work ());
        push (`Out (match pty with Some (t, c, r) -> Printf.sprintf "pty %s %dx%d\n" t c r | None -> "no pty\n"));
        { input = (fun d -> push (`In d));
          input_eof = (fun () -> push `End);
          resize = (fun c r -> push (`Out (Printf.sprintf "now %dx%d\n" c r)));
          stop = ignore });
}

let session ~user ~keys ~password ~pty ~command ~input =
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let server = Thread.create (fun () ->
      try
        let tr = Ssh_transport.create ~host_seed:host.seed Ssh_transport.Server (io b) in
        Ssh_server.serve tr backend
      with e -> Printf.printf "     server ends: %s\n%!" (Printexc.to_string e)) () in
  let seen = ref "" in
  let client = ref None in
  let result =
    try
      let tr = Ssh_transport.create ~check_host:(fun pub -> seen := pub; pub = host.pub)
          Ssh_transport.Client (io a) in
      client := Some tr;
      Ssh_client.authenticate tr ~user
        { keys; password = (fun () -> password); banner = ignore };
      let s = Ssh_client.open_session tr ~pty ~command in
      let out = Buffer.create 100 and err = Buffer.create 100 in
      let writer = Thread.create (fun () ->
          List.iter (function
              | `Data d -> ignore (Ssh_client.send_input s d)
              | `Resize (c, r) -> Ssh_client.resize s c r
              | `Eof -> Ssh_client.send_eof s) input) () in
      let code = Ssh_client.run s ~output:(Buffer.add_string out) ~errors:(Buffer.add_string err) in
      Thread.join writer;
      Ssh_transport.disconnect_with tr "bye";
      Ok (code, Buffer.contents out, Buffer.contents err)
    with e -> Error (Printexc.to_string e) in
  (* the client's writer gone before its fd may be another's *)
  Option.iter Ssh_transport.shutdown !client;
  (try Unix.shutdown a Unix.SHUTDOWN_ALL with _ -> ());
  Thread.join server;
  (try Unix.close a with _ -> ());
  (try Unix.close b with _ -> ());
  result

let () =
  (match session ~user:"alice" ~keys:[] ~password:(Some "secret") ~pty:None
           ~command:(Some "ls -l") ~input:[] with
   | Ok (code, out, err) ->
     check "password, exec: output" (out = "ran ls -l\n");
     check "exec: stderr" (err = "to stderr\n");
     check "exec: exit status" (code = 3)
   | Error e -> check ("password, exec: " ^ e) false);
  (match session ~user:"alice" ~keys:[ mallory; alice ] ~password:None
           ~pty:(Some ("vt100", 100, 30)) ~command:None
           ~input:[ `Data "hello"; `Resize (120, 40); `Data (String.make 3_000_000 'x'); `Eof ] with
   | Ok (code, out, _) ->
     check "key (second tried), shell: pty" (String.starts_with ~prefix:"pty vt100 100x30\nHELLO" out);
     check "window-change" (String.length out > 30 && String.sub out 22 11 = "now 120x40\n");
     check "3 MB through the windows" (String.ends_with ~suffix:"got 3000005\n" out
                                        && String.length out = 3000005 + 17 + 11 + 12);
     check "shell: exit status" (code = 0)
   | Error e -> check ("key, shell: " ^ e) false);
  (match session ~user:"alice" ~keys:[ mallory ] ~password:(Some "wrong") ~pty:None
           ~command:(Some "x") ~input:[] with
   | Ok _ -> check "wrong password refused" false
   | Error e -> check ("wrong password refused (" ^ e ^ ")") true);
  (* the key file, OpenSSH's format, both ways *)
  let f = Ssh_keys.to_file alice in
  (match Ssh_keys.of_file f with
   | Ok k -> check "key file round trip" (k = alice)
   | Error e -> check ("key file: " ^ e) false);
  check "public line" (Ssh_keys.pub_of_line ("from=\"x\" " ^ Ssh_keys.pub_line alice) = Some alice.pub);
  (* ssh-keygen's: a key written by OpenSSH *)
  if Array.length Sys.argv > 2 then begin
    let read f = In_channel.with_open_bin f In_channel.input_all in
    match Ssh_keys.of_file (read Sys.argv.(1)) with
    | Ok k ->
      check "OpenSSH's key file" (Some k.pub = Ssh_keys.pub_of_line (read Sys.argv.(2)));
      check "OpenSSH's comment" (k.comment = "test@openssh")
    | Error e -> check ("OpenSSH's key file: " ^ e) false
  end;
  (* ours, for OpenSSH's ssh-keygen (interop.sh) *)
  if Array.length Sys.argv > 2 then begin
    let dir = Filename.dirname Sys.argv.(1) in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 (Filename.concat dir "ours")
      (fun oc -> output_string oc (Ssh_keys.to_file alice));
    Out_channel.with_open_bin (Filename.concat dir "ours.pub")
      (fun oc -> output_string oc (Ssh_keys.pub_line alice ^ "\n"))
  end;
  if !fails > 0 then (Printf.printf "%d failed\n" !fails; exit 1)
