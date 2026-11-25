(* par: the same work in N domains at once (the measurements of
   doc/decisions/smp.md): each counts the primes below LIMIT by trial
   division, computation only. With N processors, N domains take the time
   of one.
     par DOMAINS LIMIT *)

let primes limit =
  let count = ref 0 in
  for i = 2 to limit - 1 do
    let prime = ref true and d = ref 2 in
    while !prime && !d * !d <= i do
      if i mod !d = 0 then prime := false;
      incr d
    done;
    if !prime then incr count
  done;
  !count

let alloc limit =
  let n = ref 0 in
  for _ = 1 to limit / 1000 do
    n := !n + List.length (List.init 1000 (fun i -> (i, i)))
  done;
  !n

let () =
  let domains = int_of_string Sys.argv.(1) and limit = int_of_string Sys.argv.(2) in
  let alloc_mode = Array.length Sys.argv > 3 && Sys.argv.(3) = "alloc" in
  let primes = if alloc_mode then alloc else primes in
  let t0 = Unix.gettimeofday () in
  let ds = List.init domains (fun _ -> Domain.spawn (fun () -> primes limit)) in
  let total = List.fold_left (fun a d -> a + Domain.join d) 0 ds in
  Printf.printf "par: %d domains, %s %d: %d, in %.2f s\n%!"
    domains (if alloc_mode then "allocations" else "primes below") limit
    (total / domains) (Unix.gettimeofday () -. t0)
