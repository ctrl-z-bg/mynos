(* Commands of the MyNOS shell: see shell.mli. *)

let help () =
  print_string
    "This shell is the OCaml toplevel: type OCaml phrases ended by ;;\n\
     Commands (module Shell, already open):\n\
    \  ls ();;                    list the files of the RAM disk\n\
    \  cat \"AUTOEXEC.BAT\";;       print a file\n\
    \  run \"hello.byte\" [];;      start a program and wait for it\n\
    \  free ();;                  free memory\n\
     The MyNOS system calls are in module Mynos (#show Mynos;;).\n\
     Line editing: Backspace. #quit;; or Ctrl-D ends the shell.\n";
  flush stdout

let size name =
  match open_in_bin name with
  | ic -> let n = in_channel_length ic in close_in ic; n
  | exception Sys_error _ -> -1

let ls () =
  let files = Sys.readdir "/" in
  Array.sort compare files;
  Array.iter (fun f -> Printf.printf "%9d  %s\n" (size f) f) files;
  flush stdout

let cat name =
  print_string (In_channel.with_open_bin name In_channel.input_all);
  flush stdout

let run prog args =
  let argv =
    if Filename.check_suffix prog ".byte" then "ocamlrun" :: prog :: args
    else prog :: args in
  flush stdout;
  let pid = Mynos.spawn (List.hd argv) (Array.of_list argv) in
  Mynos.wait pid

let free () =
  let pages = (Mynos.stats ()).Mynos.free_pages in
  Printf.printf "%d KB free (%d pages)\n%!" (pages * 4) pages
