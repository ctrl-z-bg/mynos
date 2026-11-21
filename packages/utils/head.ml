(* head [-n N] [FILE...]: the first N lines (10). *)

open Util

let main () =
  let set, files = parse ~valued:"n" ~usage:"[-n N] [FILE...]" "head" in
  let n = int_value set 'n' 10 in
  let many = List.length files > 1 in
  let first = ref true in
  each_input files (fun file ic ->
      if many then begin
        if not !first then print_newline ();
        Printf.printf "==> %s <==\n" file
      end;
      first := false;
      (try for _ = 1 to n do print_endline (input_line ic) done
       with End_of_file -> ()));
  finish ()
