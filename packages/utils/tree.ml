(* tree [-a] [-d] [-L N] [DIR...]: the files under DIR (.), as a tree:
   -a also those whose name starts with a dot, -d directories only, -L at
   most N levels. *)

open Util

let main () =
  let set, dirs = parse ~flags:"ad" ~valued:"L" ~usage:"[-ad] [-L N] [DIR...]" "tree" in
  let levels = int_value set 'L' max_int in
  let dirs = if dirs = [] then [ "." ] else dirs in
  let ndirs = ref 0 and nfiles = ref 0 in
  let rec walk path prefix level =
    let cs = List.filter (fun c ->
        (flag set 'a' || c.[0] <> '.')
        && (not (flag set 'd') || is_dir (Filename.concat path c))) (children path) in
    let last = List.length cs - 1 in
    List.iteri (fun i c ->
        let p = Filename.concat path c in
        let d = is_dir p in
        if d then incr ndirs else incr nfiles;
        print_endline (prefix ^ (if i = last then "\u{2514}\u{2500}\u{2500} " else "\u{251C}\u{2500}\u{2500} ")
                       ^ c ^ (if d then "/" else ""));
        if d && level < levels then
          walk p (prefix ^ (if i = last then "    " else "\u{2502}   ")) (level + 1)) cs in
  List.iter (fun d ->
      if is_dir d then begin print_endline d; walk d "" 1 end
      else warn "%s: not a directory" d) dirs;
  Printf.printf "\n%d directories, %d files\n" !ndirs !nfiles;
  finish ()
