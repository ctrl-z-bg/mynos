(* wc [-l] [-w] [-c] [FILE...]: lines, words and bytes; without options,
   all three. A total for more than one file. *)

open Util

let main () =
  let set, files = parse ~flags:"lwc" ~usage:"[-lwc] [FILE...]" "wc" in
  let all = not (flag set 'l' || flag set 'w' || flag set 'c') in
  let show (l, w, c) label =
    let cols = List.filter_map (fun (k, v) -> if all || flag set k then Some (Printf.sprintf "%7d" v) else None)
        [ 'l', l; 'w', w; 'c', c ] in
    print_endline (String.concat " " cols ^ (if label = "-" then "" else " " ^ label)) in
  let total = ref (0, 0, 0) and n = ref 0 in
  each_input files (fun file ic ->
      let s = In_channel.input_all ic in
      let lines = ref 0 and words = ref 0 and inword = ref false in
      String.iter (fun c ->
          if c = '\n' then incr lines;
          let space = c = ' ' || c = '\n' || c = '\t' || c = '\r' in
          if not space && not !inword then incr words;
          inword := not space) s;
      let r = (!lines, !words, String.length s) in
      show r file;
      let (a, b, c) = !total and (x, y, z) = r in
      total := (a + x, b + y, c + z); incr n);
  if !n > 1 then show !total "total";
  finish ()
