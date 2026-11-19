(* othreads.ml: OCaml threads; a thread that waits in a MyNOS call *)
let () =
  let m = Mutex.create () and c = Condition.create () in
  let box = ref None in
  (* a thread waits for a message on a port of ours, with a timeout *)
  let port = Mynos.alloc_port () in
  let server = Thread.create (fun () ->
      let ch = Mynos.listen port in
      let msg = Mynos.recv ~timeout:5.0 ch in
      Mynos.free_channel ch;
      Mutex.lock m; box := Some msg; Condition.signal c; Mutex.unlock m) () in
  (* meanwhile this one goes on: the waiting thread gave the lock up *)
  let ticker = Thread.create (fun () ->
      for i = 1 to 3 do Printf.printf "tick %d\n%!" i; Thread.delay 0.1 done) () in
  Thread.join ticker;
  let ch = Mynos.connect port in
  Mynos.send ch "hello, thread";
  Mynos.free_channel ch;
  Mutex.lock m;
  while !box = None do Condition.wait c m done;
  Mutex.unlock m;
  Thread.join server;
  Printf.printf "got: %s\n" (Option.get !box);
  (* Event: a rendezvous *)
  let e = Event.new_channel () in
  let t = Thread.create (fun () -> Event.sync (Event.send e 42)) () in
  Printf.printf "event: %d\n%!" (Event.sync (Event.receive e));
  Thread.join t
