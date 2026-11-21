(* sort [-r] [-n] [-f] [-u] [-k N] [FILE...]: the lines, sorted: -n as
   numbers, -f without case, -r reversed, -u once each, -k by the Nth
   field (fields between blanks). *)

open Util

let field k l =
  if k <= 1 then l
  else
    let words = List.filter (( <> ) "") (String.split_on_char ' '
                                           (String.map (fun c -> if c = '\t' then ' ' else c) l)) in
    (* from the Nth field to the end, as sort -k N does *)
    let rec drop i = function
      | _ :: rest when i > 1 -> drop (i - 1) rest
      | ws -> String.concat " " ws in
    drop k words

(* the number at the start of a line (0 if none), as sort -n reads it *)
let number s =
  let s = String.trim s in
  let n = String.length s in
  let i = ref 0 in
  if !i < n && (s.[!i] = '-' || s.[!i] = '+') then incr i;
  while !i < n && ((s.[!i] >= '0' && s.[!i] <= '9') || s.[!i] = '.') do incr i done;
  Option.value (float_of_string_opt (String.sub s 0 !i)) ~default:0.

let main () =
  let set, files = parse ~flags:"rnfu" ~valued:"k" ~usage:"[-rnfu] [-k N] [FILE...]" "sort" in
  let k = int_value set 'k' 1 in
  let all = ref [] in
  each_input files (fun _ ic -> all := List.rev_append (lines ic) !all);
  let key l = let f = field k l in if flag set 'f' then String.lowercase_ascii f else f in
  let cmp a b =
    let c =
      if flag set 'n' then compare (number (key a)) (number (key b))
      else compare (key a) (key b) in
    let c = if c = 0 && not (flag set 'u') then compare a b else c in
    if flag set 'r' then -c else c in
  let sorted = List.stable_sort cmp (List.rev !all) in
  let sorted = if flag set 'u' then
      let rec dedup = function
        | a :: (b :: _ as rest) when cmp a b = 0 -> dedup (a :: List.tl rest)
        | a :: rest -> a :: dedup rest
        | [] -> [] in
      dedup sorted
    else sorted in
  List.iter print_endline sorted;
  finish ()
