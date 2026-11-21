(* du [-s] [-h] [-b] [PATH...]: the space under each directory, in KB
   (each file rounded up), its directories first; -s the total only, -h
   in K, M, G, -b in bytes, exact. *)

open Util

let main () =
  let set, paths = parse ~flags:"shb" ~usage:"[-shb] [PATH...]" "du" in
  let paths = if paths = [] then [ "." ] else paths in
  let show n path =
    let s =
      if flag set 'b' then string_of_int n
      else if flag set 'h' then human n
      else string_of_int ((n + 1023) / 1024) in
    Printf.printf "%-7s %s\n" s path in
  let rec walk top path =
    if is_dir path then begin
      let total = List.fold_left (fun acc c ->
          acc + walk false (if path = "/" then "/" ^ c else Filename.concat path c))
          0 (children path) in
      if top || not (flag set 's') then show total path;
      total
    end else begin
      let n = size path in
      let n = if flag set 'b' then n else (n + 1023) / 1024 * 1024 in
      if top then show n path;
      n
    end in
  List.iter (fun p ->
      if Sys.file_exists p then ignore (walk true p)
      else warn "%s: no such file or directory" p) paths;
  finish ()
