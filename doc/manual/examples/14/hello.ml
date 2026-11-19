(* hello.ml: an OCaml program for MyNOS *)
let () =
  let st = Mynos.stats () in
  Printf.printf "hello from pid %d, parent %d\n" (Mynos.getpid ()) st.Mynos.ppid;
  Printf.printf "%d processes, up for %.2f s\n" st.Mynos.processes (Mynos.uptime ());
  Array.iteri (fun i a -> if i > 0 then Printf.printf "argument %d: %s\n" i a) Sys.argv
