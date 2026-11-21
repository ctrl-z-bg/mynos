(* tail [-n N] [FILE...]: the last N lines (10); -n +N from line N on. *)

open Util

let main () =
  let set, files = parse ~valued:"n" ~usage:"[-n N|+N] [FILE...]" "tail" in
  let from, n = match value set 'n' with
    | Some v when String.length v > 1 && v.[0] = '+' ->
      (match int_of_string_opt (String.sub v 1 (String.length v - 1)) with
       | Some k -> true, k
       | None -> die "-n: not a number: %s" v)
    | _ -> false, int_value set 'n' 10 in
  let many = List.length files > 1 in
  let first = ref true in
  each_input files (fun file ic ->
      if many then begin
        if not !first then print_newline ();
        Printf.printf "==> %s <==\n" file
      end;
      first := false;
      let ls = lines ic in
      let len = List.length ls in
      let skip = if from then max 0 (n - 1) else max 0 (len - n) in
      List.iteri (fun i l -> if i >= skip then print_endline l) ls);
  finish ()
