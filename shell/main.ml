(* The MyNOS shell: the OCaml toplevel, with the standard library and the
   MyNOS interfaces (.cmi) on the RAM disk, module Shell opened. It runs as
   init.byte, the first program ocamlrun starts. *)

let () =
  (* the RAM disk is the library directory: it is flat, "/" names it *)
  Clflags.no_std_include := true;
  Clflags.include_dirs := [ "/" ];
  Clflags.open_modules := [ "Shell" ];
  Clflags.noinit := true;
  print_string "\nMyNOS shell. Type help ();; for help.\n";
  flush stdout;
  exit (Topmain.main ())
