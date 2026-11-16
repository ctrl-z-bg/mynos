let () =
  print_endline "spawning a domain...";
  let d = Domain.spawn (fun () -> 6 * 7) in
  Printf.printf "domain result: %d\n" (Domain.join d)
