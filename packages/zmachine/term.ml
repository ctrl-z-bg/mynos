(* Term: what both of zmachine's faces share (finding the story, words
   wrapped to a width), and its face in the terminal: the status line in
   reverse video, the upper window's lines before each prompt. No window:
   it also runs on the host, for testing. *)

let story_path arg =
  if Sys.file_exists arg && not (Sys.is_directory arg) then arg
  else
    (* a package of data: its story file *)
    let dir = Filename.concat "/disk/pkg" arg in
    match Sys.readdir dir with
    | files ->
      (match List.find_opt (fun f ->
           List.exists (fun e -> Filename.check_suffix (String.lowercase_ascii f) e)
             [ ".z1"; ".z2"; ".z3"; ".z4"; ".z5"; ".z7"; ".z8"; ".zblorb"; ".dat" ])
           (List.sort compare (Array.to_list files)) with
       | Some f -> Filename.concat dir f
       | None -> failwith (arg ^ ": no story file in " ^ dir))
    | exception Sys_error _ -> failwith (arg ^ ": no such file, nor package")

let default_save story =
  let base = Filename.remove_extension (Filename.basename story) in
  "/disk/" ^ base ^ ".sav"

(* the number of characters (code points) of a UTF-8 string *)
let length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s; !n

(* {1 Words wrapped to a width} *)

(* text into lines of at most [width] characters, broken at spaces; the
   first line goes on from column [col] *)
let wrap width col text =
  let lines = ref [] and cur = Buffer.create 128 and c = ref col in
  let flush () = lines := Buffer.contents cur :: !lines; Buffer.clear cur; c := 0 in
  let pieces = String.split_on_char '\n' text in
  List.iteri (fun i piece ->
      if i > 0 then flush ();
      (* words, each with the spaces before it *)
      let n = String.length piece in
      let j = ref 0 in
      while !j < n do
        let s = !j in
        while !j < n && piece.[!j] = ' ' do incr j done;
        while !j < n && piece.[!j] <> ' ' do incr j done;
        let w = String.sub piece s (!j - s) in
        let len = length w in
        if !c + len > width && !c > 0 then begin
          flush ();
          let w = String.trim w in
          Buffer.add_string cur w; c := length w
        end else begin
          Buffer.add_string cur w; c := !c + len
        end
      done) pieces;
  List.rev (Buffer.contents cur :: !lines)

(* {1 In the terminal} *)

let terminal path =
  let cols = 80 in
  let vm = Zvm.create ~cols ~rows:24 ~name:(Filename.basename path)
      (In_channel.with_open_bin path In_channel.input_all) in
  let col = ref 0 in
  let reverse s = "\027[7m" ^ s ^ "\027[0m" in
  (* the text printed; [before_last], if given, comes before its last
     line (the status line, before the prompt) *)
  let show_lower ?(before_last = ignore) () =
    let runs = Zvm.take_lower vm.Zvm.screen in
    (* the runs up to the last newline, and those after it *)
    let split runs =
      let rec go = function
        | [] -> [], []
        | (t, st) :: rest ->
          match go rest with
          | (_ :: _ as a), b -> (t, st) :: a, b
          | [], b ->
            match String.rindex_opt t '\n' with
            | Some i ->
              [ (String.sub t 0 (i + 1), st) ],
              (String.sub t (i + 1) (String.length t - i - 1), st) :: b
            | None -> [], (t, st) :: b in
      go runs in
    let out runs =
      List.iter (fun (text, st) ->
          let lines = wrap cols !col text in
          List.iteri (fun i l ->
              if i > 0 then (print_newline (); col := 0);
              print_string (if st.Zvm.bold then "\027[1m" ^ l ^ "\027[0m" else l);
              col := !col + length l) lines) runs in
    let a, b = split runs in
    out a; before_last (); out b;
    flush stdout in
  let last_upper = ref "" in
  let show_upper () =
    let s = vm.Zvm.screen in
    (match s.Zvm.status with
     | Some (place, right) ->
       let pad = max 1 (cols - 2 - length place - length right) in
       if !col > 0 then (print_newline (); col := 0);
       print_endline (reverse (" " ^ place ^ String.make pad ' ' ^ right ^ " "));
       s.Zvm.status <- None
     | None ->
       let rows = Array.to_list (Array.map (fun row ->
           String.concat "" (Array.to_list (Array.map fst row))) s.Zvm.upper) in
       let rows = List.filter (fun r -> String.trim r <> "") rows in
       let text = String.concat "\n" rows in
       if text <> "" && text <> !last_upper then begin
         if !col > 0 then (print_newline (); col := 0);
         List.iter (fun r -> print_endline (reverse r)) rows;
         last_upper := text
       end);
    flush stdout in
  let read () =
    match input_line stdin with
    | l -> col := 0; Some (String.trim l)
    | exception End_of_file -> None in
  let rec go () =
    let w = Zvm.run vm in
    (match w with
     | Zvm.Line _ -> show_lower ~before_last:show_upper ()
     | _ -> show_lower ());
    match w with
    | Zvm.Quit -> if !col > 0 then print_newline ()
    | Zvm.Line _ ->
      (match read () with
       | Some l -> Zvm.give_line vm l; go ()
       | None -> print_newline ())
    | Zvm.Key ->
      (match read () with
       | Some l -> Zvm.give_key vm (if l = "" then 13 else Char.code l.[0]); go ()
       | None -> ())
    | Zvm.File_name _ ->
      let d = default_save path in
      Printf.printf "File name [%s]: %!" d;
      let f = match read () with Some "" -> d | Some f -> f | None -> "" in
      let msg = Zvm.give_file vm f in
      if msg <> "" then (print_endline msg; col := 0);
      go () in
  go ()

