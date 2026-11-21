(* manual: the MyNOS Reference Manual, inside MyNOS.

     manual             the manual in a window: its chapters, a search
     man NAME           a command's entry (chapter 13: man pkg), or a
                        module's (chapter 24: man Gui), in the terminal
     man -k WORD        the entries and sections that mention WORD
     man N              chapter N (man 13, man E for appendix E)

   The chapters are the package's Markdown files, in /disk/pkg/manual.
   On the console the text goes a screenful at a time: Space or Enter
   for more, Q to stop. *)

let dir = "/disk/pkg/manual"

let chapters () =
  (try Array.to_list (Sys.readdir dir) with Sys_error _ -> [])
  |> List.filter (fun f -> Filename.check_suffix f ".md" && f <> "README.md")
  |> List.sort compare

let read f = In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all

(* a chapter's title: its first heading *)
let title f =
  match List.find_opt (fun l -> String.starts_with ~prefix:"# " l) (String.split_on_char '\n' (read f)) with
  | Some l -> String.sub l 2 (String.length l - 2)
  | None -> f

(* the sections of a chapter whose heading satisfies [p]: heading and
   text, up to the next heading of the same level or above *)
let sections f p =
  let lines = String.split_on_char '\n' (read f) in
  let level l = let n = ref 0 in while !n < String.length l && l.[!n] = '#' do incr n done; !n in
  let rec go acc cur = function
    | [] -> List.rev (match cur with Some (lv, ls) -> (lv, List.rev ls) :: acc | None -> acc)
    | l :: rest ->
      let lv = level l in
      let acc, cur = match cur with
        | Some (clv, ls) when lv > 0 && lv <= clv -> ((clv, List.rev ls) :: acc, None)
        | c -> (acc, c) in
      (match cur with
       | None when lv > 0 && p (String.trim (String.sub l lv (String.length l - lv))) ->
         go acc (Some (lv, [ l ])) rest
       | Some (clv, ls) -> go acc (Some (clv, l :: ls)) rest
       | None -> go acc None rest) in
  List.map (fun (_, ls) -> String.concat "\n" ls) (go [] None lines)

let lower = String.lowercase_ascii

let contains s w =
  let s = lower s and w = lower w in
  let n = String.length w in
  let rec go i = i + n <= String.length s && (String.sub s i n = w || go (i + 1)) in
  n > 0 && go 0

(* {1 In the terminal} *)

(* bold on the console; plain into a file or a pipe. Struck text keeps
   its marks (the terminals show no strike); a quote's lines begin with a
   bar, a rule is a line *)
let ansi (l : Md.line) =
  let plain = Sys.getenv_opt "MYNOS_STDOUT" <> None in
  match l.Md.kind with
  | Md.Rule -> String.make 40 '-'
  | kind ->
    let spans = match kind, l.Md.spans with
      | Md.Quote, (_, s) :: rest -> ("  | ", s) :: rest
      | _, spans -> spans in
    String.concat "" (List.map (fun (t, style) ->
        match style with
        | Md.Bold when not plain -> "\027[1m" ^ t ^ "\027[0m"
        | Md.Struck -> "~~" ^ t ^ "~~"
        | _ -> t) spans)

(* a screenful at a time, on the console *)
let page lines =
  let console = Sys.getenv_opt "MYNOS_STDOUT" = None && Sys.getenv_opt "MYNOS_STDIN" = None in
  let rows = 23 in
  let rec go n = function
    | [] -> ()
    | l :: rest ->
      if console && n = rows then begin
        print_string "\027[7m-- more (Space, Enter: more; Q: stop) --\027[0m"; flush stdout;
        Mynos.console_mode ~canon:false ~echo:false ();
        let c = try input_char stdin with End_of_file -> 'q' in
        Mynos.console_mode ~canon:true ~echo:true ();
        print_string "\r\027[K";
        match c with
        | 'q' | 'Q' -> ()
        | '\r' | '\n' -> print_endline l; go (rows - 1) rest
        | _ -> print_endline l; go 1 rest
      end else begin print_endline l; go (n + 1) rest end in
  go 0 lines

let show text = page (List.map ansi (Md.render 80 text))

let man args =
  if chapters () = [] then (prerr_endline "man: the manual is not installed (pkg install manual)"; exit 2);
  match args with
  | [] | [ "-h" ] ->
    print_endline "usage: man NAME | man -k WORD | man CHAPTER  (the chapters: man -l)"; exit 2
  | [ "-l" ] -> List.iter (fun f -> print_endline (Filename.remove_extension f ^ "  " ^ title f)) (chapters ())
  | [ "-k"; w ] ->
    List.iter (fun f ->
        List.iter (fun l ->
            if String.starts_with ~prefix:"#" l && contains l w then
              Printf.printf "%-28s %s\n" (Filename.remove_extension f)
                (String.trim (String.map (fun c -> if c = '#' then ' ' else c) l)))
          (String.split_on_char '\n' (read f))) (chapters ())
  | [ name ] ->
    let up = String.uppercase_ascii name in
    (* a chapter: 13, 05, E *)
    let chapter = List.find_opt (fun f ->
        let b = Filename.remove_extension f in
        (match int_of_string_opt name with
         | Some n -> String.length b > 2 && int_of_string_opt (String.sub b 0 2) = Some n
         | None -> false)
        || lower b = "appendix-" ^ lower name ^ "" || String.starts_with ~prefix:("appendix-" ^ lower name ^ "-") (lower b))
        (chapters ()) in
    (match chapter with
     | Some f -> show (read f)
     | None ->
       let cmds = sections "13-command-reference.md" (fun h -> h = up || h = up ^ " (SOURCE)") in
       let mods = sections "24-reference.md" (fun h ->
           match String.index_opt h ' ' with
           | Some i ->
             let rest = String.sub h (i + 1) (String.length h - i - 1) in
             lower rest = lower name ^ "(3)" || lower rest = lower name ^ "(2)"
           | None -> false) in
       match cmds @ mods with
       | [] -> Printf.eprintf "man: no entry for %s (man -k %s searches)\n" name name; exit 1
       | found -> show (String.concat "\n\n" found))
  | _ -> print_endline "usage: man NAME | man -k WORD | man CHAPTER"; exit 2

(* {1 In a window} *)

let width = 900 and height = 600
let side = 270

type state = {
  files : string list;
  titles : string list;
  mutable chapter : int;
  mutable lines : Md.line list;
  mutable find : string;
  mutable found_at : int;                    (* the line found last *)
  mutable jump : int option;                 (* scroll to this line at the next frame *)
}

let window () =
  let files = chapters () in
  if files = [] then (prerr_endline "manual: the manual is not installed"; exit 2);
  let per = (width - side - 40) / Gfx.char_w in
  let st = { files; titles = List.map title files; chapter = 0;
             lines = Md.render per (read (List.hd files)); find = ""; found_at = -1; jump = None } in
  let open_chapter st i =
    st.chapter <- i; st.lines <- Md.render per (read (List.nth st.files i)); st.found_at <- -1 in
  Gui.run ~title:"Manual" width height st (fun ui st ->
      let g = ui.Gui.g in
      Gfx.fill g 0 0 side height 0xE6EBF0;
      Gui.label ~bold:true ui 12 10 "MyNOS Reference Manual";
      Gui.scroll ~colour:0xE6EBF0 ui 1 4 32 (side - 8) (height - 76) (fun top ->
          List.iteri (fun i t ->
              if Gui.list_item ui 4 (top + i * 22) (side - 24) ~selected:(i = st.chapter) t then
                open_chapter st i) st.titles;
          22 * List.length st.titles);
      st.find <- Gui.text_field ui 1 8 (height - 38) (side - 90) st.find;
      let enter = ui.Gui.field = 1 && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      if (Gui.button ui (side - 76) (height - 40) 68 "Find" || enter) && st.find <> "" then begin
        (* the next line that has it, in this chapter, then in the next ones *)
        let has (l : Md.line) = contains (String.concat "" (List.map fst l.Md.spans)) st.find in
        let rec search ch from tries =
          if tries > List.length st.files then ()
          else begin
            if ch <> st.chapter then open_chapter st ch;
            match List.find_index has (List.filteri (fun i _ -> i > from) st.lines) with
            | Some k -> st.found_at <- from + 1 + k; st.jump <- Some st.found_at
            | None -> search ((ch + 1) mod List.length st.files) (-1) (tries + 1)
          end in
        search st.chapter st.found_at 0
      end;
      let x = side + 16 in
      Gui.scroll ~colour:0xFFFFFF ui (100 + st.chapter) side 0 (width - side) height (fun top ->
          List.iteri (fun i (l : Md.line) ->
              let y = top + 12 + i * 18 in
              if y > -20 && y < height then begin
                if i = st.found_at then Gfx.fill g side y (width - side - 14) 18 0xFFF3C4;
                let colour = match l.Md.kind with
                  | Md.Heading _ -> 0x1F4F7A | Md.Code | Md.Table -> 0x37474F
                  | Md.Quote -> 0x2E3B45 | _ -> Gui.foreground in
                (match l.Md.kind with
                 | Md.Code -> Gfx.fill g (side + 8) y (width - side - 30) 18 0xF2F4F6
                 | Md.Quote ->
                   (* a box with a bar on its left, as the book's *)
                   Gfx.fill g (side + 8) y (width - side - 30) 18 0xF1F5F9;
                   Gfx.fill g (side + 8) y 3 18 0x2E5E8E
                 | Md.Rule -> Gfx.fill g x (y + 8) (width - side - 46) 1 0xC0C8D0
                 | _ -> ());
                let cx = ref x in
                List.iter (fun (t, style) ->
                    let w = Gfx.char_w * Md.cells t in
                    (match style with
                     | Md.Struck ->
                       ignore (Gfx.text g !cx y t Gui.muted);
                       Gfx.fill g !cx (y + Gfx.char_h / 2) w 1 Gui.muted
                     | _ -> ignore (Gfx.text ~bold:(style = Md.Bold) g !cx y t colour));
                    cx := !cx + w)
                  l.Md.spans
              end) st.lines;
          24 + 18 * List.length st.lines);
      (* a line found: at the top of the box, a few lines below it *)
      (match st.jump with
       | Some line -> st.jump <- None; Gui.scroll_to ui (100 + st.chapter) (12 + 18 * (line - 3))
       | None -> ());
      st)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | script :: rest when Filename.basename script = "man" && String.contains script '/' -> man rest
  | args when Filename.basename Sys.argv.(0) = "man" -> man args
  | [] -> window ()
  | args -> man args
