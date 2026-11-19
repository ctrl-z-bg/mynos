(* The MyNOS shell: the OCaml toplevel, with the standard library and the
   MyNOS interfaces (.cmi) on the RAM disk, module Shell opened. sh starts
   it (the ocaml command); in 2002-2004 it was the first program, run as
   init.byte. *)

let () =
  (* the RAM disk is the library directory: it is flat, "/" names it *)
  Clflags.no_std_include := true;
  Clflags.include_dirs := [ "/" ];
  Clflags.open_modules := [ "Shell" ];
  Clflags.noinit := true;
  print_string "\nMyNOS shell. Type help ();; for help.\n";
  flush stdout;
  exit (Topmain.main ())
