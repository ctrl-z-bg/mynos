(* grep [-i] [-v] [-n] [-c] [-l] [-r] [-F] PATTERN [FILE...]: the lines
   that match. PATTERN is a regular expression of OCaml's Str (as Emacs
   writes them: . * + ? [...] ^ $, \| between alternatives, \( \) a
   group); -F a plain string. Exit status 0 if a line matched, 1 if none,
   2 on an error. *)

open Util

let main () =
  let set, ops = parse ~flags:"ivnclrFh" ~usage:"[-ivnclrFh] PATTERN [FILE...]" "grep" in
  let pattern, files = match ops with p :: fs -> p, fs | [] -> usage "[-ivnclrFh] PATTERN [FILE...]" in
  let re =
    let p = if flag set 'F' then Str.quote pattern else pattern in
    try if flag set 'i' then Str.regexp_case_fold p else Str.regexp p
    with Failure m | Invalid_argument m -> die "%s: %s" pattern m in
  let matches l =
    (try ignore (Str.search_forward re l 0); true with Not_found -> false)
    <> flag set 'v' in
  (* -r: the files under the directories *)
  let rec expand f =
    if flag set 'r' && is_dir f then
      List.concat_map (fun c -> expand (Filename.concat f c)) (children f)
    else [ f ] in
  let files = List.concat_map expand files in
  let label = (List.length files > 1 || flag set 'r') && not (flag set 'h') in
  let found = ref false in
  each_input files (fun file ic ->
      let n = ref 0 and count = ref 0 in
      (try
         while true do
           let l = input_line ic in
           incr n;
           if matches l then begin
             found := true; incr count;
             if flag set 'l' then raise Exit;
             if not (flag set 'c') then
               print_endline ((if label then file ^ ":" else "")
                              ^ (if flag set 'n' then string_of_int !n ^ ":" else "") ^ l)
           end
         done
       with End_of_file | Exit -> ());
      if flag set 'l' && !count > 0 then print_endline file
      else if flag set 'c' then
        print_endline ((if label then file ^ ":" else "") ^ string_of_int !count));
  exit (if !status > 0 then 2 else if !found then 0 else 1)
