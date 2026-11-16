(* Reads lines from the keyboard through the console service (stdin) until
   end of file (Ctrl-D), and echoes them. *)
let () =
  print_string "console: type lines, Ctrl-D to end\n";
  let rec loop n =
    print_string "> "; flush stdout;
    match read_line () with
    | line -> Printf.printf "console: line %d: %S\n%!" n line; loop (n + 1)
    | exception End_of_file -> Printf.printf "\nconsole: end of input after %d lines\n" (n - 1)
  in
  loop 1
