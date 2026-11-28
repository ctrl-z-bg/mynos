(* nettools' SSH server on the host, for OpenSSH's client: 127.0.0.1:PORT,
   user test, password "secret" or the key of PUBFILE; "exec" answers
   with the command, a shell echoes in capitals until "q". One connection
   at a time, until killed. tests/nettools/interop.sh runs it.
     hostsshd.byte PORT PUBFILE *)

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

let () =
  let port = int_of_string Sys.argv.(1) in
  let key = In_channel.with_open_bin Sys.argv.(2) In_channel.input_all in
  let pub = Option.get (Ssh_keys.pub_of_line key) in
  let host = Ssh_keys.generate ~comment:"" in
  let backend = {
    Ssh_server.password = (fun ~user pw -> user = "test" && pw = "secret");
    key = (fun ~user k -> user = "test" && k = pub);
    failed = ignore;
    log = (fun m -> Printf.printf "server: %s\n%!" m);
    start = (fun ~user:_ ~pty ~command ~output ~errors:_ ~exited ->
        match command with
        | Some "big" ->
          (* a megabyte: with RekeyLimit, OpenSSH rekeys in the middle *)
          ignore (Thread.create (fun () ->
              for i = 0 to 1023 do output (Printf.sprintf "%1023d\n" i) done; exited 0) ());
          { input = ignore; input_eof = ignore; resize = (fun _ _ -> ()); stop = ignore }
        | Some c ->
          ignore (Thread.create (fun () -> output ("ran: " ^ c ^ "\n"); exited 7) ());
          { input = ignore; input_eof = ignore; resize = (fun _ _ -> ()); stop = ignore }
        | None ->
          let q = Queue.create () and m = Mutex.create () and cv = Condition.create () in
          let push e = Mutex.lock m; Queue.push e q; Condition.signal cv; Mutex.unlock m in
          let rec work () =
            Mutex.lock m;
            while Queue.is_empty q do Condition.wait cv m done;
            let e = Queue.pop q in
            Mutex.unlock m;
            match e with
            | `Out s -> output s; work ()
            | `In d when String.contains d 'q' -> output "bye\r\n"; exited 0
            | `In d -> output (String.uppercase_ascii d); work ()
            | `End -> exited 0 in
          ignore (Thread.create work ());
          push (`Out (match pty with
              | Some (t, c, r) -> Printf.sprintf "pty %s %dx%d\r\n" t c r | None -> "no pty\r\n"));
          { input = (fun d -> push (`In d)); input_eof = (fun () -> push `End);
            resize = (fun c r -> push (`Out (Printf.sprintf "now %dx%d\r\n" c r))); stop = ignore });
  } in
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen s 4;
  Printf.printf "listening on %d, host key %s\n%!" port (Ssh_keys.fingerprint host.pub);
  while true do
    let fd, _ = Unix.accept s in
    (try
       let tr = Ssh_transport.create ~host_seed:host.seed Ssh_transport.Server (io fd) in
       Ssh_server.serve tr backend
     with e -> Printf.printf "server: ends: %s\n%!" (Printexc.to_string e));
    (try Unix.close fd with _ -> ())
  done
