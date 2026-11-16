(* Commands of the MyNOS shell: see shell.mli. *)

let help () =
  print_string
    "This shell is the OCaml toplevel: type OCaml phrases ended by ;;\n\
     Commands (module Shell, already open):\n\
    \  ls ();;                     list the current directory (/: the RAM disk)\n\
    \  cd \"/disk\";; pwd ();;       change, show the current directory\n\
    \  ls ~dir:\"/tmp\" ();;         list /tmp (in memory)\n\
    \  ls ~dir:\"/disk\" ();;        list /disk (the FAT disk: it stays)\n\
    \  cat \"AUTOEXEC.BAT\";;        print a file\n\
    \  write \"/tmp/a.ml\" \"1+1;;\";; write a file\n\
    \  #use \"/tmp/a.ml\";;          run the phrases in a file\n\
    \  rm \"/tmp/a.ml\";;            remove a file\n\
    \  run \"hello.byte\" [];;       start a program and wait for it\n\
    \  edit \"/disk/a.ml\";;         edit a file (full screen)\n\
    \  compile \"/disk/a.ml\";;      compile it into /disk/a.byte (ocamlc)\n\
    \  free ();;                   free memory\n\
     The MyNOS system calls are in module Mynos (#show Mynos;;).\n\
     Line editing: Backspace; Up and Down recall previous lines.\n\
     #quit;; or Ctrl-D ends the shell (init starts a new one).\n";
  flush stdout

let size name =
  match open_in_bin name with
  | ic -> let n = in_channel_length ic in close_in ic; n
  | exception Sys_error _ -> -1

let ls ?(dir = ".") () =
  let files = Sys.readdir dir in
  Array.sort compare files;
  Array.iter (fun f ->
      let path = Filename.concat dir f in
      if Sys.is_directory path then Printf.printf "%9s  %s/\n" "dir" f
      else Printf.printf "%9d  %s\n" (size path) f)
    files;
  flush stdout

let cat name =
  print_string (In_channel.with_open_bin name In_channel.input_all);
  flush stdout

let write file text =
  Out_channel.with_open_bin file (fun oc -> output_string oc text)

let rm = Sys.remove

(* the environment of the programs the shell starts: the OCaml library is
   at the root of the RAM disk (for ocamlc) *)
let env = [| "OCAMLLIB=/" |]

let cd dir = Sys.chdir dir

let pwd () = print_endline (Sys.getcwd ())

(* a program named without a directory: in the current one, else a system
   program at the root of the RAM disk *)
let find prog =
  if String.contains prog '/' || Sys.file_exists prog then prog
  else if Sys.file_exists ("/" ^ prog) then "/" ^ prog
  else prog

let run prog args =
  let prog = if Filename.check_suffix prog ".byte" then find prog else prog in
  let argv =
    if Filename.check_suffix prog ".byte" then "ocamlrun" :: prog :: args
    else prog :: args in
  flush stdout;
  let pid = Mynos.spawn ~env (List.hd argv) (Array.of_list argv) in
  Mynos.wait pid

let compile ?output src =
  let out =
    match output with
    | Some o -> o
    | None -> Filename.remove_extension src ^ ".byte" in
  (* the runtime's primitives include MyNOS's: programs may use Mynos *)
  run "ocamlc.byte" [ "-use-prims"; "/primitives"; "mynos.cma"; "-o"; out; src ]

let edit file = ignore (run "edit.byte" [ file ])

let free () =
  let pages = (Mynos.stats ()).Mynos.free_pages in
  Printf.printf "%d KB free (%d pages)\n%!" (pages * 4) pages
