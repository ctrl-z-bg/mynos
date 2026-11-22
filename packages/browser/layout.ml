(* Layout: a page's tokens as lines of text, for a width in cells (the
   font is 8 x 16, every character one cell). Blocks (paragraphs,
   headings, lists, quotes, tables as rows of cells, preformatted text)
   start new lines; inline text is wrapped at spaces. Each line is made of
   spans with their style and, for links, their target. *)

type style = {
  bold : bool;
  colour : int;
  underline : bool;
  strike : bool;
  link : string option;            (* the href, as written *)
}

type span = { col : int; text : string; style : style }

type line = {
  spans : span list;
  rule : bool;                     (* a horizontal rule *)
  bar : int;                       (* quote bars at its left (blockquote depth) *)
}

type page = {
  title : string;
  lines : line array;
  anchors : (string * int) list;   (* id or name -> line *)
  base : string option;            (* <base href> *)
}

let text_colour = 0x1A2228
let link_colour = 0x1A5FB4
let heading_colour = 0x1F4F7A
let muted = 0x5F6B76
let code_colour = 0x8B2252

let plain = { bold = false; colour = text_colour; underline = false; strike = false; link = None }

let cells s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s; !n

(* the first [k] cells of s, and the rest *)
let split_cells s k =
  let i = ref 0 and c = ref 0 in
  while !i < String.length s && !c < k do
    incr i;
    while !i < String.length s && Char.code s.[!i] land 0xC0 = 0x80 do incr i done;
    incr c
  done;
  (String.sub s 0 !i, String.sub s !i (String.length s - !i))

let nbsp_to_space w =
  if not (String.contains w '\xa0') then w
  else begin
    let b = Buffer.create (String.length w) and i = ref 0 and n = String.length w in
    while !i < n do
      if !i + 1 < n && w.[!i] = '\xc2' && w.[!i + 1] = '\xa0' then begin
        Buffer.add_char b ' '; i := !i + 2 end
      else begin Buffer.add_char b w.[!i]; incr i end
    done;
    Buffer.contents b
  end

let block_tags = [ "p"; "div"; "section"; "article"; "header"; "footer"; "nav"; "main";
                   "aside"; "form"; "fieldset"; "figure"; "figcaption"; "address"; "details";
                   "summary"; "center"; "table"; "caption"; "dl"; "legend"; "hgroup"; "menu" ]
let skipped = [ "script"; "style"; "head"; "template"; "svg"; "math"; "iframe"; "object";
                "select"; "canvas"; "audio"; "video"; "map"; "noembed" ]

let layout ~width tokens =
  let width = max 20 width in
  let lines = ref [] and anchors = ref [] and title = ref "" and base = ref None in
  let cur = ref [] and col = ref 0 in           (* the line being made: spans, reversed *)
  let indent = ref 0 and bars = ref 0 in
  let pending_space = ref false in
  let blank_wanted = ref 0 in                   (* empty lines due before the next text *)
  let line_count () = List.length !lines in
  let push_line ?(rule = false) () =
    lines := { spans = List.rev !cur; rule; bar = !bars } :: !lines;
    cur := []; col := 0; pending_space := false in
  let new_line () = if !cur <> [] then push_line () in
  let want_blank n =
    new_line ();
    blank_wanted := max !blank_wanted n in
  let start_text () =
    if !cur = [] then begin
      (* the blank lines owed, but not at the top of the page *)
      if !lines <> [] then
        for _ = 1 to !blank_wanted do push_line () done;
      blank_wanted := 0;
      col := !indent
    end in
  let add_word style w =
    let w_cells = cells w in
    if !cur <> [] && !pending_space && !col + 1 + w_cells > width then push_line ();
    start_text ();
    let spaced = !pending_space && !col > !indent in
    if spaced then incr col;
    pending_space := false;
    (* the same style right before, a space apart: one span (a link's
       underline goes on under its spaces) *)
    let merged = match !cur with
      | prev :: rest when spaced && prev.style = style && prev.col + cells prev.text + 1 = !col
                          && cells w <= width - !col ->
        cur := { prev with text = prev.text ^ " " ^ w } :: rest; col := !col + cells w; true
      | _ -> false in
    if not merged then
    (* a word longer than the line: cut *)
    let rec put w =
      let room = width - !col in
      if cells w <= room || room <= 0 then begin
        cur := { col = !col; text = w; style } :: !cur; col := !col + cells w
      end else begin
        let a, b = split_cells w room in
        cur := { col = !col; text = a; style } :: !cur;
        push_line (); col := !indent; put b
      end in
    put w in
  (* the style stack: each open element's style *)
  let styles = ref [ ("", plain) ] in
  let style () = snd (List.hd !styles) in
  let push name st = styles := (name, st) :: !styles in
  let pop name =
    if List.exists (fun (n, _) -> n = name) !styles then begin
      let rec drop = function
        | (n, _) :: rest when n = name -> rest
        | _ :: rest -> drop rest
        | [] -> [ ("", plain) ] in
      styles := drop !styles;
      if !styles = [] then styles := [ ("", plain) ]
    end in
  let pre = ref 0 and skip = ref 0 and in_title = ref false in
  let lists = ref [] in                          (* (ordered, counter) for each open list *)
  let table_cell = ref 0 in
  let text s =
    if !in_title then title := !title ^ s
    else if !skip > 0 then ()
    else if !pre > 0 then begin
      let parts = String.split_on_char '\n' s in
      List.iteri (fun i p ->
          if i > 0 then begin if !cur = [] then push_line () else push_line () end;
          if p <> "" then begin
            start_text ();
            let p = String.map (fun c -> if c = '\r' then ' ' else c) (Gfx.expand_tabs p) in
            cur := { col = !col; text = p; style = style () } :: !cur;
            col := !col + cells p
          end) parts
    end else begin
      let words = String.split_on_char ' '
          (String.map (fun c -> match c with '\n' | '\t' | '\r' | '\012' -> ' ' | c -> c) s) in
      let n = List.length words in
      List.iteri (fun i w ->
          (* a non-breaking space (U+00A0, C2 A0 in UTF-8): a space
             inside the word, which does not break *)
          let w = nbsp_to_space w in
          if i > 0 then pending_space := true;
          if w <> "" then add_word (style ()) w;
          if i = n - 1 && i > 0 && w = "" then pending_space := true) words;
      if String.length s > 0 && (s.[0] = ' ' || s.[0] = '\n') && !cur <> [] then ()
    end in
  let heading_level n = match n with
    | "h1" -> 1 | "h2" -> 2 | "h3" -> 3 | "h4" -> 4 | "h5" -> 5 | "h6" -> 6 | _ -> 0 in
  List.iter (function
      | Html.Text s -> text s
      | Html.Start (name, attrs) ->
        (match Html.attr "id" attrs with
         | Some id -> anchors := (id, line_count ()) :: !anchors | None -> ());
        if List.mem name skipped then begin
          if name = "head" then () else incr skip
        end
        else if name = "title" then in_title := true
        else if !skip > 0 then ()
        else begin
          let st = style () in
          match name with
          | "base" -> base := Html.attr "href" attrs
          | "br" -> if !cur = [] then push_line () else push_line ()
          | "hr" -> new_line (); blank_wanted := 0; push_line ~rule:true ()
          | "p" -> want_blank 1
          | "pre" | "listing" -> want_blank 1; incr pre; push name { st with colour = code_colour }
          | "blockquote" -> want_blank 1; indent := !indent + 2; incr bars
          | "ul" | "ol" | "dir" ->
            if !lists = [] then want_blank 1 else new_line ();
            let start = match Html.attr "start" attrs with
              | Some s -> (match int_of_string_opt s with Some n -> n - 1 | None -> 0) | None -> 0 in
            lists := (name = "ol", ref start) :: !lists;
            indent := !indent + 2
          | "li" ->
            new_line ();
            let mark = match !lists with
              | (true, n) :: _ -> incr n; string_of_int !n ^ "."
              | _ -> "\xe2\x80\xa2" in
            start_text ();
            let c = max 0 (!indent - 2) in
            cur := { col = c; text = mark; style = { st with colour = muted } } :: !cur;
            col := max !col (c + cells mark + 1)
          | "dt" -> new_line (); push name { st with bold = true }
          | "dd" -> new_line (); indent := !indent + 4
          | "tr" -> new_line (); table_cell := 0
          | "td" | "th" ->
            if !table_cell > 0 then begin
              start_text (); add_word { st with colour = muted } "|"; pending_space := true
            end;
            incr table_cell;
            if name = "th" then push name { st with bold = true }
          | "a" ->
            (match Html.attr "name" attrs with
             | Some id -> anchors := (id, line_count ()) :: !anchors | None -> ());
            (match Html.attr "href" attrs with
             | Some h -> push name { st with colour = link_colour; underline = true; link = Some h }
             | None -> push name st)
          | "b" | "strong" -> push name { st with bold = true }
          | "i" | "em" | "cite" | "var" | "dfn" -> push name { st with colour = (if st.link <> None then st.colour else 0x4B3C8E) }
          | "u" | "ins" -> push name { st with underline = true }
          | "s" | "strike" | "del" -> push name { st with strike = true; colour = muted }
          | "code" | "kbd" | "tt" | "samp" -> push name { st with colour = (if st.link <> None then st.colour else code_colour) }
          | "small" | "sub" | "sup" -> push name { st with colour = (if st.link <> None then st.colour else muted) }
          | "mark" -> push name { st with bold = true }
          | "img" ->
            let alt = match Html.attr "alt" attrs with Some a when String.trim a <> "" -> a | _ -> "image" in
            add_word { st with colour = (if st.link <> None then link_colour else muted) } ("[" ^ alt ^ "]")
          | "input" ->
            (match Option.map String.lowercase_ascii (Html.attr "type" attrs) with
             | Some "hidden" -> ()
             | Some ("submit" | "button" | "reset") ->
               add_word { st with colour = muted }
                 ("[" ^ Option.value (Html.attr "value" attrs) ~default:"Submit" ^ "]")
             | _ -> add_word { st with colour = muted } "[________]")
          | "textarea" -> add_word { st with colour = muted } "[text]"; incr skip
          | "button" -> push name { st with colour = muted }
          | _ ->
            let h = heading_level name in
            if h > 0 then begin
              want_blank 1;
              push name { st with bold = true; colour = heading_colour; underline = h = 1 }
            end
            else if List.mem name block_tags then new_line ()
        end
      | Html.End name ->
        if List.mem name skipped then begin
          if name <> "head" && !skip > 0 then decr skip
        end
        else if name = "title" then in_title := false
        else if name = "textarea" then (if !skip > 0 then decr skip)
        else if !skip > 0 then ()
        else begin
          match name with
          | "p" -> want_blank 1
          | "pre" | "listing" -> if !pre > 0 then decr pre; pop name; want_blank 1
          | "blockquote" -> indent := max 0 (!indent - 2); bars := max 0 (!bars - 1); want_blank 1
          | "ul" | "ol" | "dir" ->
            (match !lists with _ :: rest -> lists := rest | [] -> ());
            indent := max 0 (!indent - 2);
            if !lists = [] then want_blank 1 else new_line ()
          | "dd" -> indent := max 0 (!indent - 4); new_line ()
          | "dt" -> pop name; new_line ()
          | "table" -> want_blank 1
          | "li" | "tr" -> new_line ()
          | _ ->
            pop name;
            if heading_level name > 0 then want_blank 1
            else if List.mem name block_tags then new_line ()
        end)
    tokens;
  new_line ();
  let title = String.trim (String.concat " " (List.filter (( <> ) "")
                                                (String.split_on_char ' ' (String.map (fun c -> if c = '\n' then ' ' else c) !title)))) in
  { title; lines = Array.of_list (List.rev !lines); anchors = List.rev !anchors; base = !base }

(* the text, as --dump prints it *)
let to_text page =
  let b = Buffer.create 4096 in
  Array.iter (fun l ->
      if l.rule then Buffer.add_string b "----------------------------------------"
      else begin
        let col = ref 0 in
        List.iter (fun s ->
            if s.col > !col then Buffer.add_string b (String.make (s.col - !col) ' ');
            Buffer.add_string b s.text; col := max !col s.col + cells s.text) l.spans
      end;
      Buffer.add_char b '\n') page.lines;
  Buffer.contents b
