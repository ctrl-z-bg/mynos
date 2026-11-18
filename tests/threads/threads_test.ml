(* OCaml's systhreads on MyNOS (mynos-09i): threads in one domain, Mutex,
   Condition, Event, Thread.delay; and a thread that waits in a MyNOS call
   (sleep, an IPC receive) while the others run: the stubs that block give
   the runtime lock up. *)

let check what ok =
  Printf.printf "threads: %-46s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  (* a counter, three threads, a mutex *)
  let m = Mutex.create () and n = ref 0 in
  let worker () = for _ = 1 to 1000 do Mutex.lock m; incr n; Mutex.unlock m; Thread.yield () done in
  let ts = List.init 3 (fun _ -> Thread.create worker ()) in
  List.iter Thread.join ts;
  ok &&& check "three threads, a mutex: 3000" (!n = 3000);
  (* a condition: a producer and a consumer *)
  let c = Condition.create () and q = Queue.create () in
  let sum = ref 0 in
  let cons = Thread.create (fun () ->
      for _ = 1 to 10 do
        Mutex.lock m;
        while Queue.is_empty q do Condition.wait c m done;
        sum := !sum + Queue.pop q;
        Mutex.unlock m
      done) () in
  for i = 1 to 10 do
    Mutex.lock m; Queue.push i q; Condition.signal c; Mutex.unlock m;
    Thread.delay 0.01
  done;
  Thread.join cons;
  ok &&& check "a condition: producer and consumer (55)" (!sum = 55);
  (* Event: a synchronous channel *)
  let ch = Event.new_channel () in
  let t = Thread.create (fun () -> Event.sync (Event.send ch "over the channel")) () in
  let got = Event.sync (Event.receive ch) in
  Thread.join t;
  ok &&& check "Event: a message between threads" (got = "over the channel");
  (* Thread.delay *)
  let t0 = Mynos.uptime () in
  Thread.delay 0.2;
  ok &&& check "Thread.delay 0.2" (Mynos.uptime () -. t0 >= 0.18);
  (* a MyNOS call that waits must not stop the other threads: one sleeps
     (Mynos.sleep), one waits for a message that never comes (Mynos.recv
     with a timeout); meanwhile the main thread counts *)
  let count_while f =
    let busy = ref true and k = ref 0 in
    let t = Thread.create (fun () -> f (); busy := false) () in
    while !busy do incr k; Thread.yield () done;
    Thread.join t;
    !k in
  let k = count_while (fun () -> Mynos.sleep 0.3) in
  ok &&& check "Mynos.sleep lets the other threads run" (k > 100);
  let port = Mynos.alloc_port () in
  let k = count_while (fun () ->
      (* a channel to ourselves: connect in a thread, listen here *)
      let lt = Thread.create (fun () -> try ignore (Mynos.listen port) with _ -> ()) () in
      let chn = Mynos.connect port in
      (try ignore (Mynos.recv ~timeout:0.3 chn) with Mynos.Error _ -> ());
      Thread.join lt) in
  ok &&& check "Mynos connect, listen, recv let the others run" (k > 100);
  print_endline (if !ok then "threads: all checks passed" else "threads: some checks failed")
