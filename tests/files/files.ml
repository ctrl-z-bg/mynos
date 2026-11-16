(* Files from OCaml: the standard library's channels, through the file
   functions of libmynos, to the memrofs service. This program is itself
   loaded by ocamlrun from the RAM disk, as init.byte. *)

let check what ok =
  Printf.printf "files: %-36s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  ok &&& check "Sys.file_exists on a file" (Sys.file_exists "AUTOEXEC.BAT");
  ok &&& check "Sys.file_exists on a missing file"
    (not (Sys.file_exists "nothing.txt"));
  let ic = open_in "AUTOEXEC.BAT" in
  let len = in_channel_length ic in
  let first = input_line ic in
  ok &&& check "input_line" (first = "Hello from memrofs!");
  seek_in ic 6;
  let s = really_input_string ic 4 in
  ok &&& check "seek_in, really_input_string" (s = "from");
  seek_in ic 0;
  let all = really_input_string ic len in
  ok &&& check "in_channel_length and whole read"
    (String.length all = len && len > 20);
  close_in ic;
  ok &&& check "open_in of a missing file fails"
    (match open_in "nothing.txt" with
     | _ -> false | exception Sys_error _ -> true);
  ok &&& check "open_out fails (read-only)"
    (match open_out "new.txt" with
     | _ -> false | exception Sys_error _ -> true);
  print_endline (if !ok then "files: all checks passed"
                 else "files: SOME CHECKS FAILED")
