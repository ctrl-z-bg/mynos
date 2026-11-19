(* domains.ml: OCaml 5 domains *)
let rec fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

let () =
  let ds = List.map (fun n -> Domain.spawn (fun () -> (n, fib n))) [ 20; 21; 22 ] in
  List.iter (fun d -> let n, f = Domain.join d in Printf.printf "fib %d = %d\n" n f) ds;
  let hits = Atomic.make 0 in
  let ds = List.init 4 (fun _ ->
      Domain.spawn (fun () -> for _ = 1 to 1000 do Atomic.incr hits done)) in
  List.iter Domain.join ds;
  Printf.printf "hits: %d\n" (Atomic.get hits)
