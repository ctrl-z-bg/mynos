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

type span = {
  col : int;
  text : string;
  style : style;
  widget : (int * int) option;     (* a form's field: (form, field) *)
}

(* forms: what the page asks, and how it is sent *)
type field_kind = Text | Password | Hidden | Submit | Checkbox | Radio | Textarea | Select

type field = {
  fname : string;
  kind : field_kind;
  value : string;                  (* as the page gives it *)
  checked : bool;
  options : (string * string) list;   (* a select's: value, words *)
  label : string;                  (* a button's words *)
  cells : int;                     (* its width on the line *)
}

type form = { action : string; meth : string; fields : field array }

type line = {
  spans : span list;
  rule : bool;                     (* a horizontal rule *)
  bar : int;                       (* quote bars at its left (blockquote depth) *)
  picture : picture option;        (* a picture starts on this line *)
}
and picture = {
  src : string;                    (* as written *)
  alt : string;
  plink : string option;           (* inside a link: its href *)
  pw : int;                        (* its size on the page, in pixels *)
  ph : int;
}

let line_h = 18

type page = {
  title : string;
  lines : line array;
  anchors : (string * int) list;   (* id or name -> line *)
  base : string option;            (* <base href> *)
  forms : form array;
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
                "canvas"; "audio"; "video"; "map"; "noembed" ]

(* [size src]: a picture's size in pixels, when known (fetched, or its
   width and height attributes); a picture is laid out on lines of its
   own, as tall as it is, narrowed to the page *)
(* ---- a little CSS: what is hidden, and readable colours ---- *)

let void = [ "area"; "base"; "br"; "col"; "embed"; "hr"; "img"; "input"; "link"; "meta";
             "source"; "track"; "wbr"; "param" ]

let squeeze s = String.concat "" (String.split_on_char ' ' (String.lowercase_ascii s))

let hides decls =
  let d = squeeze decls in
  Html.contains d "display:none" || Html.contains d "visibility:hidden"

(* whether a media query holds for a screen [px] pixels wide: a list of
   queries (any one), each "[not|only] TYPE [and (FEATURE)]..." or just
   features; widths in px (or em, 16 px); a feature not known does not hold
   (forced-colors, hover...). Print does not. *)
let media_holds ~px query =
  let one q =
    let q = String.lowercase_ascii (String.trim q) in
    let neg, q =
      if String.starts_with ~prefix:"not " q then (true, String.sub q 4 (String.length q - 4))
      else if String.starts_with ~prefix:"only " q then (false, String.sub q 5 (String.length q - 5))
      else (false, q) in
    let parts =                                    (* split at " and " *)
      let b = Buffer.create (String.length q) and i = ref 0 and n = String.length q in
      while !i < n do
        if !i + 5 <= n && String.sub q !i 5 = " and " then (Buffer.add_char b '\001'; i := !i + 5)
        else (Buffer.add_char b q.[!i]; incr i)
      done;
      List.map String.trim (String.split_on_char '\001' (Buffer.contents b)) in
    let length v =
      let v = String.trim v in
      let num s = try Some (float_of_string (String.trim s)) with _ -> None in
      if String.ends_with ~suffix:"px" v then num (String.sub v 0 (String.length v - 2))
      else if String.ends_with ~suffix:"em" v then
        Option.map (fun f -> f *. 16.) (num (String.sub v 0 (String.length v - 2)))
      else num v in
    let holds part =
      match part with
      | "" | "all" | "screen" -> true
      | "print" | "speech" | "tv" | "handheld" | "projection" -> false
      | f when String.length f > 2 && f.[0] = '(' && f.[String.length f - 1] = ')' ->
        let f = String.sub f 1 (String.length f - 2) in
        (match String.index_opt f ':' with
         | Some i ->
           let name = String.trim (String.sub f 0 i)
           and v = String.sub f (i + 1) (String.length f - i - 1) in
           (match name, length v with
            | "max-width", Some w -> float px <= w
            | "min-width", Some w -> float px >= w
            | "orientation", _ -> String.trim v = "landscape"
            | "prefers-color-scheme", _ -> String.trim v = "light"
            | "prefers-reduced-motion", _ -> String.trim v = "no-preference"
            | _ -> false)
         | None -> f = "color")
      | _ -> false in
    let r = List.for_all holds parts in
    if neg then not r else r in
  List.exists one (String.split_on_char ',' query)

(* the simple selectors of rules that hide: (tag, class, id), any may be
   ""; the rules of @media blocks only if they hold for a window [px]
   wide; other @ blocks (fonts, animations, @supports) skipped *)
let hiding_rules ?(px = 880) css =
  let css = (* without comments *)
    let b = Buffer.create (String.length css) and i = ref 0 and n = String.length css in
    while !i < n do
      if !i + 1 < n && css.[!i] = '/' && css.[!i + 1] = '*' then begin
        i := !i + 2;
        while !i + 1 < n && not (css.[!i] = '*' && css.[!i + 1] = '/') do incr i done;
        i := !i + 2
      end else begin Buffer.add_char b css.[!i]; incr i end
    done;
    Buffer.contents b in
  let n = String.length css in
  let selectors prelude =
    List.filter_map (fun sel ->
        let sel = String.trim sel in
        if sel = "" || String.exists (fun c -> c = ' ' || c = ':' || c = '[' || c = '>'
                                                 || c = '+' || c = '~' || c = '*') sel then None
        else begin
          let cut c s = match String.index_opt s c with
            | Some j -> (String.sub s 0 j, String.sub s (j + 1) (String.length s - j - 1))
            | None -> (s, "") in
          let rest, id = cut '#' sel in
          let tag, cls = cut '.' rest in
          if String.contains cls '.' then None
          else Some (String.lowercase_ascii tag, cls, id)
        end) (String.split_on_char ',' prelude) in
  (* past the block that starts at i (just after its '{') *)
  let rec skip_block i depth =
    if i >= n then n
    else match css.[i] with
      | '{' -> skip_block (i + 1) (depth + 1)
      | '}' -> if depth = 0 then i + 1 else skip_block (i + 1) (depth - 1)
      | _ -> skip_block (i + 1) depth in
  let out = ref [] in
  (* the rules from i to the end of the enclosing block *)
  let rec rules i active =
    let j = ref i in
    while !j < n && css.[!j] <> '{' && css.[!j] <> '}' && css.[!j] <> ';' do incr j done;
    if !j >= n then n
    else if css.[!j] = '}' then !j + 1                       (* the block ends *)
    else begin
      let prelude = String.trim (String.sub css i (!j - i)) in
      if css.[!j] = ';' then rules (!j + 1) active           (* @import, @charset *)
      else if String.length prelude > 0 && prelude.[0] = '@' then begin
        let lower = String.lowercase_ascii prelude in
        if String.starts_with ~prefix:"@media" lower then begin
          let cond = String.sub prelude 6 (String.length prelude - 6) in
          rules (rules (!j + 1) (active && media_holds ~px cond)) active
        end else rules (skip_block (!j + 1) 0) active
      end else begin
        let k = ref (!j + 1) in
        while !k < n && css.[!k] <> '}' do incr k done;
        let decls = String.sub css (!j + 1) (!k - !j - 1) in
        if active && hides decls then out := !out @ selectors prelude;
        rules (min n (!k + 1)) active
      end
    end in
  let i = ref 0 in
  while !i < n do i := rules !i true done;
  !out

let named_colours = [ "black", 0x000000; "red", 0xC00000; "green", 0x007000; "blue", 0x0000C0;
                      "maroon", 0x800000; "navy", 0x000080; "purple", 0x800080; "teal", 0x008080;
                      "olive", 0x707000; "gray", 0x606060; "grey", 0x606060; "darkred", 0x8B0000;
                      "darkgreen", 0x006400; "darkblue", 0x00008B; "brown", 0x8B4513 ]

(* a colour, if it reads on white (not too light) *)
let readable_colour v =
  let v = String.trim (String.lowercase_ascii v) in
  let hex s = int_of_string_opt ("0x" ^ s) in
  let c = if String.length v = 7 && v.[0] = '#' then hex (String.sub v 1 6)
    else if String.length v = 4 && v.[0] = '#' then
      Option.map (fun x -> let r = (x lsr 8) land 15 and g = (x lsr 4) land 15 and b = x land 15 in
                   (r * 17) lsl 16 lor (g * 17) lsl 8 lor (b * 17)) (hex (String.sub v 1 3))
    else List.assoc_opt v named_colours in
  match c with
  | Some c ->
    let r = c lsr 16 and g = (c lsr 8) land 255 and b = c land 255 in
    if (299 * r + 587 * g + 114 * b) / 1000 < 150 then Some c else None
  | None -> None

let style_value attrs prop =
  match Html.attr "style" attrs with
  | None -> None
  | Some s ->
    List.find_map (fun d ->
        match String.index_opt d ':' with
        | Some i when String.trim (String.lowercase_ascii (String.sub d 0 i)) = prop ->
          Some (String.trim (String.sub d (i + 1) (String.length d - i - 1)))
        | _ -> None) (String.split_on_char ';' s)

(* ---- tables: the simple ones (no tables, no fields inside) as grids ---- *)

let table_end tokens =
  (* the tokens of a table (after its start), and the ones after its end *)
  let rec go depth acc = function
    | [] -> (List.rev acc, [])
    | (Html.End "table" as t) :: rest -> if depth = 0 then (List.rev acc, rest) else go (depth - 1) (t :: acc) rest
    | (Html.Start ("table", _) as t) :: rest -> go (depth + 1) (t :: acc) rest
    | t :: rest -> go depth (t :: acc) rest in
  go 0 [] tokens

let simple_table toks =
  not (List.exists (function
      | Html.Start (("table" | "input" | "select" | "textarea" | "button" | "form" | "pre"), _) -> true
      | _ -> false) toks)

(* rows of cells: (header, columns spanned, its tokens) *)
let table_rows toks =
  let rows = ref [] and row = ref None and cell = ref None in
  let close_cell () = match !cell, !row with
    | Some (h, span, ts), Some cells -> row := Some ((h, span, List.rev ts) :: cells); cell := None
    | Some _, None -> cell := None
    | None, _ -> () in
  let close_row () = close_cell (); (match !row with
      | Some cells when cells <> [] -> rows := List.rev cells :: !rows | _ -> ()); row := None in
  List.iter (function
      | Html.Start ("tr", _) -> close_row (); row := Some []
      | Html.End "tr" -> close_row ()
      | Html.Start (("td" | "th") as n, a) ->
        close_cell (); if !row = None then row := Some [];
        let span = match Html.attr "colspan" a with
          | Some s -> max 1 (min 12 (Option.value (int_of_string_opt (String.trim s)) ~default:1)) | None -> 1 in
        cell := Some (n = "th", span, [])
      | Html.End ("td" | "th") -> close_cell ()
      | Html.Start (("thead" | "tbody" | "tfoot" | "colgroup" | "col"), _)
      | Html.End ("thead" | "tbody" | "tfoot" | "colgroup") -> ()
      | Html.Start ("caption", _) -> close_row (); row := Some []; cell := Some (true, 12, [])
      | Html.End "caption" -> close_row ()
      | t -> (match !cell with Some (h, s, ts) -> cell := Some (h, s, t :: ts) | None -> ())) toks;
  close_row ();
  List.rev !rows

let rec layout ?(size = fun _ _ -> None) ?(pictures = true) ~width tokens =
  let width = max 20 width in
  let lines = ref [] and anchors = ref [] and title = ref "" and base = ref None in
  let cur = ref [] and col = ref 0 in           (* the line being made: spans, reversed *)
  let indent = ref 0 and bars = ref 0 in
  let pending_space = ref false in
  let blank_wanted = ref 0 in                   (* empty lines due before the next text *)
  let line_count () = List.length !lines in
  let push_line ?(rule = false) () =
    lines := { spans = List.rev !cur; rule; bar = !bars; picture = None } :: !lines;
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
        cur := { col = !col; text = w; style; widget = None } :: !cur; col := !col + cells w
      end else begin
        let a, b = split_cells w room in
        cur := { col = !col; text = a; style; widget = None } :: !cur;
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
  (* the forms, as they come: (action, method, fields reversed), reversed *)
  let forms = ref [] and form = ref (-1) in
  let add_field f =
    if !form < 0 then begin forms := ("", "get", ref []) :: !forms; form := List.length !forms - 1 end;
    let _, _, fl = List.nth !forms (List.length !forms - 1 - !form) in
    fl := f :: !fl;
    (!form, List.length !fl - 1) in
  let add_widget w cells =
    let cells = max 1 (min cells (width - !indent)) in
    if !cur <> [] && !col + 1 + cells > width then push_line ();
    start_text ();
    if !pending_space && !col > !indent then incr col;
    pending_space := false;
    cur := { col = !col; text = String.make cells ' '; style = plain; widget = Some w } :: !cur;
    col := !col + cells;
    pending_space := true in
  let field ?(value = "") ?(checked = false) ?(options = []) ?(label = "") ~cells name kind =
    { fname = name; kind; value; checked; options; label; cells } in
  (* a textarea's text, a select's options, a button's words: gathered *)
  let in_textarea : (string * int * Buffer.t) option ref = ref None in
  let in_select : (string * (string * string * bool) list ref) option ref = ref None in
  let option : (string option * bool * Buffer.t) option ref = ref None in
  let in_button : (string * string * string * Buffer.t) option ref = ref None in
  let end_option () =
    match !in_select, !option with
    | Some (_, opts), Some (v, sel, b) ->
      let words = String.trim (Buffer.contents b) in
      opts := (Option.value v ~default:words, words, sel) :: !opts; option := None
    | _ -> option := None in
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
            cur := { col = !col; text = p; style = style (); widget = None } :: !cur;
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
  let css = Buffer.create 256 and in_style = ref false in
  let rules = ref [] in
  let handle = (function
      | Html.Text s when !in_style -> Buffer.add_string css s
      | Html.Start ("style", _) -> in_style := true; incr skip
      | Html.End "style" ->
        in_style := false; if !skip > 0 then decr skip;
        rules := hiding_rules ~px:(width * 8) (Buffer.contents css)
      | Html.Text s ->
        (match !in_textarea, !in_select, !in_button with
         | Some (_, _, b), _, _ -> Buffer.add_string b s
         | _, Some _, _ -> (match !option with Some (_, _, b) -> Buffer.add_string b s | None -> ())
         | _, _, Some (_, _, _, b) -> Buffer.add_string b s
         | None, None, None -> text s)
      | Html.Start (name, attrs) when !in_select <> None && name = "option" ->
        end_option ();
        option := Some (Html.attr "value" attrs, List.mem_assoc "selected" attrs, Buffer.create 16)
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
            cur := { col = c; text = mark; style = { st with colour = muted }; widget = None } :: !cur;
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
            let alt = match Html.attr "alt" attrs with Some a -> String.trim a | None -> "" in
            let num a = match Html.attr a attrs with
              | Some v -> int_of_string_opt (String.trim (List.hd (String.split_on_char 'p' v)))
              | None -> None in
            let src = Option.value (Html.attr "src" attrs) ~default:"" in
            let small = match num "width", num "height" with
              | Some w, Some h -> w <= 32 && h <= 32 | Some w, None -> w <= 32
              | None, Some h -> h <= 32 | None, None -> false in
            if src = "" || small || not pictures then begin
              (* an icon, a spacer: its words, if it has some *)
              if alt <> "" then
                add_word { st with colour = (if st.link <> None then link_colour else muted) } ("[" ^ alt ^ "]")
            end else begin
              let attr_size = match num "width", num "height" with
                | Some w, Some h when w > 0 && h > 0 -> Some (w, h) | _ -> None in
              let max_w = width * 8 - 8 * !indent in
              match (match size src attr_size with Some s -> Some s | None -> attr_size) with
              | Some (w, h) when w > 0 && h > 0 ->
                let pw = min w max_w in
                let ph = h * pw / w in
                new_line ();
                lines := { spans = []; rule = false; bar = !bars;
                           picture = Some { src; alt; plink = st.link; pw; ph } } :: !lines;
                for _ = 2 to (ph + line_h - 1) / line_h do push_line () done;
                blank_wanted := 0
              | _ ->
                (* its size not known yet: a line, which the picture
                   takes once fetched *)
                new_line ();
                lines := { spans = []; rule = false; bar = !bars;
                           picture = Some { src; alt; plink = st.link; pw = 0; ph = line_h } } :: !lines
            end
          | "form" ->
            new_line ();
            forms := (Option.value (Html.attr "action" attrs) ~default:"",
                      String.lowercase_ascii (Option.value (Html.attr "method" attrs) ~default:"get"),
                      ref []) :: !forms;
            form := List.length !forms - 1
          | "input" ->
            let name = Option.value (Html.attr "name" attrs) ~default:"" in
            let value = Option.value (Html.attr "value" attrs) ~default:"" in
            let size = match Html.attr "size" attrs with
              | Some s -> Option.value (int_of_string_opt (String.trim s)) ~default:20 | None -> 20 in
            (match String.lowercase_ascii (Option.value (Html.attr "type" attrs) ~default:"text") with
             | "hidden" -> ignore (add_field (field ~value ~cells:0 name Hidden))
             | "submit" | "image" ->
               let label = if value = "" then "Submit" else value in
               let cells = cells label + 4 in
               add_widget (add_field (field ~value ~label ~cells name Submit)) cells
             | "button" | "reset" | "file" -> ()
             | "checkbox" | "radio" as k ->
               let value = if value = "" then "on" else value in
               add_widget (add_field (field ~value ~checked:(List.mem_assoc "checked" attrs) ~cells:3 name
                                        (if k = "radio" then Radio else Checkbox))) 3
             | k ->
               let cells = max 6 (min 40 size) + 2 in
               add_widget (add_field (field ~value ~cells name (if k = "password" then Password else Text))) cells)
          | "textarea" ->
            let cols = match Html.attr "cols" attrs with
              | Some s -> Option.value (int_of_string_opt (String.trim s)) ~default:40 | None -> 40 in
            in_textarea := Some (Option.value (Html.attr "name" attrs) ~default:"", max 10 (min 60 cols) + 2,
                                 Buffer.create 64)
          | "select" -> in_select := Some (Option.value (Html.attr "name" attrs) ~default:"", ref [])
          | "span" | "font" ->
            let c = match style_value attrs "color" with
              | Some v -> readable_colour v
              | None -> Option.bind (Html.attr "color" attrs) readable_colour in
            push name (match c with Some c when st.link = None -> { st with colour = c } | _ -> st)
          | "button" ->
            in_button := Some (Option.value (Html.attr "name" attrs) ~default:"",
                               Option.value (Html.attr "value" attrs) ~default:"",
                               String.lowercase_ascii (Option.value (Html.attr "type" attrs) ~default:"submit"),
                               Buffer.create 16)
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
        else if name = "textarea" then
          (match !in_textarea with
           | Some (n, cells, b) ->
             in_textarea := None;
             if !skip = 0 then add_widget (add_field (field ~value:(Buffer.contents b) ~cells n Textarea)) cells
           | None -> ())
        else if name = "option" && !in_select <> None then end_option ()
        else if name = "select" then
          (match !in_select with
           | Some (n, opts) ->
             end_option ();
             in_select := None;
             let opts = List.rev !opts in
             let chosen = match List.find_opt (fun (_, _, s) -> s) opts with
               | Some (v, _, _) -> v | None -> (match opts with (v, _, _) :: _ -> v | [] -> "") in
             let options = List.map (fun (v, w, _) -> (v, w)) opts in
             let cells = 4 + List.fold_left (fun a (_, w) -> max a (cells w)) 4 options in
             if !skip = 0 then add_widget (add_field (field ~value:chosen ~options ~cells:(min 30 cells) n Select)) (min 30 cells)
           | None -> ())
        else if name = "button" then
          (match !in_button with
           | Some (n, v, t, b) ->
             in_button := None;
             let label = String.trim (Buffer.contents b) in
             let label = if label = "" then "Submit" else label in
             if t = "submit" && !skip = 0 then begin
               let cells = cells label + 4 in
               add_widget (add_field (field ~value:v ~label ~cells n Submit)) cells
             end
           | None -> ())
        else if name = "form" then begin new_line (); form := -1 end
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
        end) in
  (* is an element hidden (the hidden attribute, its style, a rule)? *)
  let hidden name attrs =
    List.mem_assoc "hidden" attrs
    || (match Html.attr "style" attrs with Some s -> hides s | None -> false)
    || (!rules <> []
        (* its own style showing it wins over a rule (style="display:block") *)
        && not (match Html.attr "style" attrs with
            | Some st -> Html.contains (String.concat "" (String.split_on_char ' ' (String.lowercase_ascii st))) "display:"
            | None -> false) &&
        let classes = match Html.attr "class" attrs with
          | Some c -> String.split_on_char ' ' c | None -> [] in
        let id = Option.value (Html.attr "id" attrs) ~default:"" in
        List.exists (fun (t, c, i) ->
            (t = "" || t = name) && (c = "" || List.mem c classes) && (i = "" || i = id)
            && (t <> "" || c <> "" || i <> "")) !rules) in
  (* a simple table, as a grid: its columns as wide as their words need,
     narrowed to fit *)
  let grid toks =
    let rows = table_rows toks in
    let ncols = List.fold_left (fun a r -> max a (List.fold_left (fun a (_, s, _) -> a + s) 0 r)) 0 rows in
    if ncols = 0 then ()
    else begin
      let gap = 2 in
      let avail = max ncols (width - !indent - gap * (ncols - 1)) in
      let natural ts =
        let p = layout ~pictures:false ~width:1000 ts in
        Array.fold_left (fun a (l : line) ->
            max a (List.fold_left (fun a s -> max a (s.col + cells s.text)) 0 l.spans)) 0 p.lines in
      let longest_word ts =
        List.fold_left (fun a t -> match t with
            | Html.Text s ->
              List.fold_left (fun a w -> max a (cells w)) a
                (String.split_on_char ' ' (String.map (fun c -> if c = '\n' || c = '\t' then ' ' else c) s))
            | _ -> a) 1 ts in
      let col_max = Array.make ncols 1 and col_min = Array.make ncols 1 in
      List.iter (fun r ->
          ignore (List.fold_left (fun j (_, s, ts) ->
              if s = 1 && j < ncols then begin
                col_max.(j) <- max col_max.(j) (natural ts);
                col_min.(j) <- max col_min.(j) (min 20 (longest_word ts))
              end;
              j + s) 0 r)) rows;
      let sum a = Array.fold_left ( + ) 0 a in
      let widths =
        if sum col_max <= avail then Array.copy col_max
        else if sum col_min >= avail then
          Array.map (fun m -> max 3 (m * avail / max 1 (sum col_min))) col_min
        else
          Array.mapi (fun j m ->
              m + (col_max.(j) - m) * (avail - sum col_min) / max 1 (sum col_max - sum col_min)) col_min in
      new_line ();
      List.iter (fun r ->
          (* each cell laid out at its width; the row as tall as its tallest *)
          let _, cells_laid = List.fold_left (fun (j, acc) (h, s, ts) ->
              let j1 = min ncols (j + s) in
              let w = ref 0 in
              for k = j to j1 - 1 do w := !w + widths.(k) done;
              let w = !w + gap * (max 0 (j1 - j - 1)) in
              let x = ref !indent in
              for k = 0 to j - 1 do x := !x + widths.(k) + gap done;
              let ts = if h then (Html.Start ("b", []) :: ts) @ [ Html.End "b" ] else ts in
              let p = layout ~pictures:false ~width:(max 1 w) ts in
              (* the blank lines it starts or ends with: not in a cell *)
              let ls = List.filter (fun (l : line) -> l.spans <> []) (Array.to_list p.lines) in
              (j1, (!x, ls) :: acc)) (0, []) r in
          let height = List.fold_left (fun a (_, ls) -> max a (List.length ls)) 1 cells_laid in
          for i = 0 to height - 1 do
            let spans = List.concat_map (fun (x, ls) ->
                match List.nth_opt ls i with
                | Some (l : line) -> List.map (fun s -> { s with col = s.col + x }) l.spans
                | None -> []) (List.rev cells_laid) in
            lines := { spans; rule = false; bar = !bars; picture = None } :: !lines
          done) rows;
      blank_wanted := max !blank_wanted 1
    end in
  let hiding = ref None in                       (* (element, depth) being skipped *)
  let rec run = function
    | [] -> ()
    | t :: rest ->
      match !hiding, t with
      | Some (n, d), Html.Start (m, _) when m = n -> hiding := Some (n, d + 1); run rest
      | Some (n, d), Html.End m when m = n -> hiding := (if d <= 1 then None else Some (n, d - 1)); run rest
      | Some _, _ -> run rest
      | None, Html.Start (name, attrs) when !skip = 0 && !in_select = None && hidden name attrs ->
        if not (List.mem name void) then hiding := Some (name, 1);
        run rest
      | None, Html.Start ("table", _) when !skip = 0 && !in_select = None && !in_textarea = None ->
        let toks, after = table_end rest in
        if simple_table toks then begin grid toks; run after end
        else begin handle t; run rest end
      | None, t -> handle t; run rest in
  run tokens;
  new_line ();
  let title = String.trim (String.concat " " (List.filter (( <> ) "")
                                                (String.split_on_char ' ' (String.map (fun c -> if c = '\n' then ' ' else c) !title)))) in
  let forms = Array.of_list (List.rev_map (fun (action, meth, fl) ->
      { action; meth; fields = Array.of_list (List.rev !fl) }) !forms) in
  { title; lines = Array.of_list (List.rev !lines); anchors = List.rev !anchors; base = !base; forms }

(* a field as text: what --dump shows *)
let field_text f value checked =
  match f.kind with
  | Text | Textarea -> "[" ^ value ^ String.make (max 0 (f.cells - 2 - cells value)) '_' ^ "]"
  | Password -> "[" ^ String.make (cells value) '*' ^ String.make (max 0 (f.cells - 2 - cells value)) '_' ^ "]"
  | Hidden -> ""
  | Submit -> "[ " ^ f.label ^ " ]"
  | Checkbox -> if checked then "[x]" else "[ ]"
  | Radio -> if checked then "(*)" else "( )"
  | Select ->
    "[" ^ (match List.assoc_opt value f.options with Some w -> w | None -> value) ^ " v]"

(* the text, as --dump prints it *)
let to_text page =
  let b = Buffer.create 4096 in
  Array.iter (fun l ->
      (match l.picture with
       | Some p -> Buffer.add_string b ("[picture" ^ (if p.alt <> "" then ": " ^ p.alt else "") ^ "]")
       | None -> ());
      if l.rule then Buffer.add_string b "----------------------------------------"
      else begin
        let col = ref 0 in
        List.iter (fun s ->
            if s.col > !col then Buffer.add_string b (String.make (s.col - !col) ' ');
            let t = match s.widget with
              | Some (fi, k) ->
                let f = page.forms.(fi).fields.(k) in field_text f f.value f.checked
              | None -> s.text in
            Buffer.add_string b t; col := max !col s.col + cells t) l.spans
      end;
      Buffer.add_char b '\n') page.lines;
  Buffer.contents b
