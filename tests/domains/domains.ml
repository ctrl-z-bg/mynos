(* OCaml 5 domains on MyNOS (mynos-l9h): Domain.spawn is a pthread, i.e. a
   Linux clone, with futexes behind Mutex, Condition and Domain.join. The
   domains share one CPU: they run in turn, not in parallel. *)

let check what ok =
  Printf.printf "domains: %-40s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let rec fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in

  (* results computed in other domains *)
  let ds = List.map (fun n -> Domain.spawn (fun () -> fib n)) [ 20; 21; 22 ] in
  ok &&& check "spawn and join three domains"
    (List.map Domain.join ds = [ fib 20; fib 21; fib 22 ]);

  (* a shared atomic counter *)
  let counter = Atomic.make 0 in
  let ds =
    List.init 4 (fun _ ->
        Domain.spawn (fun () ->
            for _ = 1 to 10_000 do Atomic.incr counter done)) in
  List.iter Domain.join ds;
  ok &&& check "Atomic counter from four domains" (Atomic.get counter = 40_000);

  (* a producer and a consumer: Mutex and Condition *)
  let m = Mutex.create () and c = Condition.create () in
  let queue = Queue.create () and finished = ref false in
  let consumer =
    Domain.spawn (fun () ->
        let sum = ref 0 and stop = ref false in
        while not !stop do
          Mutex.lock m;
          while Queue.is_empty queue && not !finished do Condition.wait c m done;
          (match Queue.take_opt queue with
           | Some x -> sum := !sum + x
           | None -> stop := true);
          Mutex.unlock m
        done;
        !sum) in
  for i = 1 to 1000 do
    Mutex.lock m;
    Queue.add i queue;
    Condition.signal c;
    Mutex.unlock m
  done;
  Mutex.lock m;
  finished := true;
  Condition.broadcast c;
  Mutex.unlock m;
  ok &&& check "producer and consumer (Mutex, Condition)"
    (Domain.join consumer = 500_500);

  (* domain-local state, and an exception crossing join *)
  let key = Domain.DLS.new_key (fun () -> 0) in
  Domain.DLS.set key 7;
  let other = Domain.join (Domain.spawn (fun () -> Domain.DLS.get key)) in
  ok &&& check "Domain.DLS is per domain" (other = 0 && Domain.DLS.get key = 7);
  ok &&& check "an exception comes back through join"
    (match Domain.join (Domain.spawn (fun () -> failwith "boom")) with
     | _ -> false
     | exception Failure m -> m = "boom");

  (* the garbage collector with several domains allocating *)
  let ds =
    List.init 3 (fun i ->
        Domain.spawn (fun () ->
            let l = ref [] in
            for j = 1 to 50_000 do l := (i, j) :: !l done;
            Gc.full_major ();
            List.length !l)) in
  ok &&& check "GC while three domains allocate"
    (List.map Domain.join ds = [ 50_000; 50_000; 50_000 ]);

  print_endline (if !ok then "domains: all checks passed" else "domains: FAIL")
