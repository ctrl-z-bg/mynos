let () =
  print_string "Hello from OCaml on MyNOS!\n";
  for i = 1 to 5 do
    Printf.printf "%d * %d = %d\n" i i (i * i)
  done
