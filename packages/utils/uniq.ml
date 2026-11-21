(* uniq [-c] [-d] [-u] [-i] [FILE]: the lines, a run of equal ones once:
   -c with their count, -d only the repeated ones, -u only the others,
   -i without case. *)

open Util

let main () =
  let set, files = parse ~flags:"cdui" ~usage:"[-cdui] [FILE]" "uniq" in
  let same a b =
    if flag set 'i' then String.lowercase_ascii a = String.lowercase_ascii b else a = b in
  let out line n =
    if (not (flag set 'd') || n > 1) && (not (flag set 'u') || n = 1) then
      if flag set 'c' then Printf.printf "%7d %s\n" n line else print_endline line in
  each_input files (fun _ ic ->
      let rec go prev n =
        match input_line ic with
        | l when same l prev -> go prev (n + 1)
        | l -> out prev n; go l 1
        | exception End_of_file -> out prev n in
      match input_line ic with
      | first -> go first 1
      | exception End_of_file -> ());
  finish ()
