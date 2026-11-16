let () =
  print_string "Hello from OCaml ";
  print_endline Sys.ocaml_version;
  for i = 1 to 3 do Printf.printf "%d * %d = %d\n" i i (i * i) done;
  let l = List.init 100_000 (fun i -> i) in
  Printf.printf "GC test: sum = %d\n" (List.fold_left (+) 0 l);
  Printf.printf "float: %g %s\n" (sqrt 2.0) (string_of_float 3.14)
