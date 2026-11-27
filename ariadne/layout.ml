(* Layout (CSS 2's visual formatting model, as far as M3 goes): block
   boxes with their widths, margins, borders and padding, sibling margins
   collapsing; inline formatting contexts, with lines broken at spaces,
   white-space, text-align, text-indent, line heights; list markers. The
   result is a display list (rectangles and text, in page coordinates) and
   the links' rectangles, which the window paints and hit-tests.

   Until M5: floats are laid out in the flow, positioned elements
   (absolute, fixed) are left out, flex and grid containers are blocks,
   table cells flow inline in their rows. Until M2: text is measured in
   the window's font, Terminus, 8 x 16 pixels (Metrics below). Until M4:
   an image is its alt text, or a frame of its size.

   Block boxes nest at most [max_depth] deep; deeper ones flow inline, so
   the recursion of layout is bounded however deep the page (the plan's
   rule 3). *)

open Style

(* ---- text metrics: the window's font until M2 ---- *)

module Metrics = struct
  let char_w = 8
  let glyph_h = 16
  let cells s =
    let n = ref 0 in
    String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
    !n
  let width (_ : Style.t) s = cells s * char_w
  let space (_ : Style.t) = char_w
  let line_height (s : Style.t) =
    let h = match s.line_height with
      | Lh_normal -> s.font_size *. 1.2
      | Lh_px p -> p
      | Lh_factor f -> f *. s.font_size in
    max glyph_h (int_of_float (Float.round h))
end

(* ---- the display list ---- *)

type item =
  | Fill of { x : int; y : int; w : int; h : int; color : int }
  | Text of { x : int; y : int; s : string; color : int; bold : bool; italic : bool }

type link = { lx : int; ly : int; lw : int; lh : int; href : string }

type page = {
  items : item array;
  links : link array;
  height : int;
  background : int;                  (* the canvas *)
  anchors : (string * int) list;     (* ids, and where they are *)
}

type out = {
  items_ : item Dynarray.t;
  links_ : link Dynarray.t;
  mutable anchors_ : (string * int) list;
  styles : Style.styles;
  viewport_h : int;
}

let emit o i = Dynarray.add_last o.items_ i

let rgb c = c land 0xFFFFFF
let visible_color c = c lsr 24 <> 0

let px (l : length) ~of_ = match l with
  | Auto -> 0
  | Len (p, pct) -> int_of_float (Float.round (p +. pct *. float of_ /. 100.))

let max_depth = 150

(* ---- the pieces of an inline formatting context ---- *)

type atom_kind =
  | Word of string
  | Space
  | Break
  | Box of { w : int; h : int; label : string; frame : bool }

type atom = {
  kind : atom_kind;
  st : Style.t;
  link : string option;
  bg : int;                       (* the inline element's background, 0 if none *)
}

type piece =
  | P_block of Dom.node * Style.t
  | P_atom of atom
  | P_text of string * Style.t * string option * int
  | P_space of int * Style.t      (* an inline element's margin, border and padding *)

let block_level = function
  | Block | List_item | Table | Table_row | Table_group | Table_caption | Flex | Grid -> true
  | _ -> false

let transform st w =
  match st.Style.transform with
  | No_transform -> w
  | Upper -> String.uppercase_ascii w
  | Lower -> String.lowercase_ascii w
  | Capitalize -> String.capitalize_ascii w

(* a replaced or form element, as a box in the line *)
let atomic (n : Dom.node) (st : Style.t) ~cw : atom_kind option =
  let a = Dom.attr n in
  let size default_w default_h =
    let w = match st.width with Auto -> default_w | l -> px l ~of_:cw in
    let h = match st.height with Auto -> default_h | l -> px l ~of_:cw in
    (w, h) in
  match Dom.name n with
  | "img" ->
    let alt = Option.value (a "alt") ~default:"" in
    (match st.width, st.height with
     | Auto, Auto -> if alt = "" then None else Some (Word ("[" ^ alt ^ "]"))
     | _ -> let w, h = size 0 Metrics.glyph_h in
       Some (Box { w; h; label = alt; frame = true }))
  | "input" ->
    (match String.lowercase_ascii (Option.value (a "type") ~default:"text") with
     | "hidden" -> None
     | "checkbox" | "radio" -> Some (Box { w = 13; h = 13; label = (if a "checked" <> None then "x" else ""); frame = true })
     | "submit" | "button" | "reset" ->
       let label = Option.value (a "value") ~default:(if a "type" = Some "reset" then "Reset" else "Submit") in
       let w, h = size (Metrics.cells label * Metrics.char_w + 16) 20 in
       Some (Box { w; h; label; frame = true })
     | _ ->
       let label = match a "value" with Some v -> v | None -> Option.value (a "placeholder") ~default:"" in
       let w, h = size 160 20 in
       Some (Box { w; h; label; frame = true }))
  | "button" ->
    let label = String.trim (Dom.text_content n) in
    let w, h = size (Metrics.cells label * Metrics.char_w + 16) 20 in
    Some (Box { w; h; label; frame = true })
  | "select" ->
    let first = Dom.find (fun o -> Dom.is_html o "option") n in
    let label = match first with Some o -> String.trim (Dom.text_content o) ^ " v" | None -> "v" in
    let w, h = size (Metrics.cells label * Metrics.char_w + 16) 20 in
    Some (Box { w; h; label; frame = true })
  | "textarea" ->
    let cols = Option.value (Option.bind (a "cols") int_of_string_opt) ~default:20 in
    let rows = Option.value (Option.bind (a "rows") int_of_string_opt) ~default:2 in
    let w, h = size (cols * Metrics.char_w + 8) (rows * Metrics.glyph_h + 4) in
    Some (Box { w; h; label = Dom.text_content n; frame = true })
  | "iframe" | "video" | "canvas" | "embed" | "object" | "audio" ->
    let w, h = size 300 150 in
    Some (Box { w; h; label = Dom.name n; frame = true })
  | "svg" ->
    (match st.width, st.height, a "width", a "height" with
     | Auto, Auto, None, None -> None
     | _ ->
       let aw = Option.bind (a "width") float_of_string_opt and ah = Option.bind (a "height") float_of_string_opt in
       let w, h = size (int_of_float (Option.value aw ~default:0.)) (int_of_float (Option.value ah ~default:0.)) in
       Some (Box { w; h; label = ""; frame = false }))
  | _ -> None

let is_atomic n = List.mem (Dom.name n) [ "img"; "input"; "button"; "select"; "textarea"; "iframe"; "video";
                                          "canvas"; "embed"; "object"; "audio"; "svg" ]

(* the pieces of a block container's content: its inline descendants
   flattened (a loop: Dom.walk), its block-level ones as blocks to lay out *)
let pieces o (container : Dom.node) ~cw ~depth =
  let out = ref [] in
  let links = ref [] in          (* the enclosing <a href>, innermost first *)
  let bgs = ref [] in            (* the enclosing inline backgrounds *)
  let add p = out := p :: !out in
  let enter (n : Dom.node) =
    if n == container then true
    else match n.kind with
      | Text { data } ->
        (match Option.bind n.parent (fun p -> Style.get o.styles p) with
         | Some st when st.display <> None_ ->
           add (P_text (data, st, (match !links with l :: _ -> l | [] -> None),
                        (match !bgs with b :: _ -> b | [] -> 0)))
         | _ -> ());
        false
      | Element _ ->
        (match Style.get o.styles n with
         | None -> false
         | Some st ->
           if st.display = None_ || st.position = Absolute || st.position = Fixed then false
           else if Dom.is_html n "br" then begin
             add (P_atom { kind = Break; st; link = None; bg = 0 }); false
           end else if block_level st.display && depth < max_depth then begin
             add (P_block (n, st)); false
           end else if is_atomic n then begin
             (match atomic n st ~cw with
              | Some kind -> add (P_atom { kind; st; link = (match !links with l :: _ -> l | [] -> None); bg = 0 })
              | None -> ());
             false
           end else if st.display = Table_column then false
           else begin
             (* an inline element (or a block too deep, flowed inline) *)
             let href = if Dom.is_html n "a" then Dom.attr n "href" else None in
             links := (match href with Some h -> Some h | None -> (match !links with l :: _ -> l | [] -> None)) :: !links;
             bgs := (if visible_color st.background then st.background else (match !bgs with b :: _ -> b | [] -> 0)) :: !bgs;
             let side i = px st.margin.(i) ~of_:cw + int_of_float (border st i) + px st.padding.(i) ~of_:cw in
             if st.display <> Contents then begin
               let left = side 3 in
               if left > 0 then add (P_space (left, st))
             end;
             true
           end)
      | _ -> false in
  let leave (n : Dom.node) =
    if n != container then
      match n.kind, Style.get o.styles n with
      | Element _, Some st when st.display <> None_ && not (block_level st.display && depth < max_depth)
                                && not (is_atomic n) && not (Dom.is_html n "br")
                                && st.position <> Absolute && st.position <> Fixed
                                && st.display <> Table_column ->
        links := (match !links with _ :: r -> r | [] -> []);
        bgs := (match !bgs with _ :: r -> r | [] -> []);
        if st.display = Table_cell then add (P_space (2 * Metrics.char_w, st))
        else if st.display <> Contents then begin
          let right = px st.margin.(1) ~of_:cw + int_of_float (border st 1) + px st.padding.(1) ~of_:cw in
          if right > 0 then add (P_space (right, st))
        end
      | _ -> () in
  Dom.walk ~enter ~leave container;
  List.rev !out

(* ---- inline layout ---- *)

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012'

(* text pieces to words and spaces, white-space applied; [prev_space]: the
   last atom was a collapsible space (spaces collapse across elements) *)
let atoms_of pieces =
  let out = ref [] in
  let prev_space = ref true in
  let add a = out := a :: !out in
  List.iter (function
      | P_atom a -> add a; prev_space := (a.kind = Break)
      | P_space (w, st) -> add { kind = Box { w; h = 0; label = ""; frame = false }; st; link = None; bg = 0 }
      | P_block _ -> ()
      | P_text (data, st, link, bg) ->
        let mk kind = { kind; st; link; bg } in
        (match st.white_space with
         | Pre | Pre_wrap ->
           (* every space kept; newlines are breaks *)
           let lines = String.split_on_char '\n' data in
           List.iteri (fun i line ->
               if i > 0 then add (mk Break);
               (* spaces kept, as words of spaces *)
               let b = Buffer.create 16 in
               let flush () = if Buffer.length b > 0 then (add (mk (Word (Buffer.contents b))); Buffer.clear b) in
               String.iter (fun c ->
                   if c = '\t' then Buffer.add_string b "        "
                   else if c = ' ' && st.white_space = Pre_wrap then (flush (); add (mk (Word " ")))
                   else Buffer.add_char b c) line;
               flush ()) lines;
           prev_space := false
         | Normal | Nowrap | Pre_line ->
           let n = String.length data in
           let i = ref 0 in
           while !i < n do
             if is_ws data.[!i] then begin
               if st.white_space = Pre_line && data.[!i] = '\n' then (add (mk Break); prev_space := true)
               else if not !prev_space then (add (mk Space); prev_space := true);
               incr i
             end else begin
               let j = ref !i in
               while !j < n && not (is_ws data.[!j]) do incr j done;
               add (mk (Word (transform st (String.sub data !i (!j - !i)))));
               prev_space := false;
               i := !j
             end
           done)) pieces;
  List.rev !out

let atom_width a =
  match a.kind with
  | Word w -> Metrics.width a.st w
  | Space -> Metrics.space a.st
  | Break -> 0
  | Box { w; _ } -> w

(* a word wider than the line, cut into pieces that fit *)
let cut_word a avail =
  match a.kind with
  | Word w when atom_width a > avail && avail >= Metrics.char_w ->
    let per = max 1 (avail / Metrics.char_w) in
    (* cut at character boundaries (UTF-8) *)
    let chars = ref [] in
    let n = String.length w in
    let i = ref 0 in
    while !i < n do
      let len = let b = Char.code w.[!i] in if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4 in
      let len = min len (n - !i) in
      chars := String.sub w !i len :: !chars; i := !i + len
    done;
    let chars = Array.of_list (List.rev !chars) in
    let parts = ref [] in
    let k = ref 0 in
    while !k < Array.length chars do
      let m = min per (Array.length chars - !k) in
      parts := { a with kind = Word (String.concat "" (Array.to_list (Array.sub chars !k m))) } :: !parts;
      k := !k + m
    done;
    List.rev !parts
  | _ -> [ a ]

(* lay out the atoms in lines from [y], in [x, x + w); the height used *)
let inline_layout o (container : Style.t) atoms ~x ~y ~w =
  let strut = Metrics.line_height container in
  let y = ref y in
  let first_line = ref true in
  let lines_done = ref 0 in
  let emit_line (line : (atom * int) list) =
    (* trailing spaces do not count *)
    let rec drop_trailing = function
      | (a, _) :: r when a.kind = Space -> drop_trailing r
      | l -> l in
    let line = List.rev (drop_trailing (List.rev line)) in
    let width = List.fold_left (fun acc (a, _) -> acc + atom_width a) 0 line in
    let indent = if !first_line then px container.text_indent ~of_:w else 0 in
    let lh = List.fold_left (fun m (a, _) ->
        match a.kind with
        | Box { h; _ } -> max m h
        | Word _ | Space -> max m (Metrics.line_height a.st)
        | Break -> m) strut line in
    let shift = match container.text_align with
      | Center -> max 0 ((w - indent - width) / 2)
      | Right -> max 0 (w - indent - width)
      | Left | Justify -> 0 in
    let cx = ref (x + indent + shift) in
    let text_y = !y + (lh - Metrics.glyph_h) / 2 in
    List.iter (fun (a, _) ->
        let aw = atom_width a in
        let st = a.st in
        if st.visible then begin
          if a.bg <> 0 && aw > 0 then
            emit o (Fill { x = !cx; y = text_y - 1; w = aw; h = Metrics.glyph_h + 2; color = rgb a.bg });
          (match a.kind with
           | Word s ->
             emit o (Text { x = !cx; y = text_y; s; color = st.color; bold = st.font_weight >= 600; italic = st.italic })
           | Box { w = bw; h = bh; label; frame } ->
             let by = !y + lh - bh - (lh - Metrics.glyph_h) / 2 + (if bh > Metrics.glyph_h then (lh - Metrics.glyph_h) / 2 else 0) in
             let by = max !y (min by (!y + lh - bh)) in
             if frame && bw > 0 && bh > 0 then begin
               let c = 0xA0A8B0 in
               emit o (Fill { x = !cx; y = by; w = bw; h = 1; color = c });
               emit o (Fill { x = !cx; y = by + bh - 1; w = bw; h = 1; color = c });
               emit o (Fill { x = !cx; y = by; w = 1; h = bh; color = c });
               emit o (Fill { x = !cx + bw - 1; y = by; w = 1; h = bh; color = c })
             end;
             if label <> "" && bw > 2 * Metrics.char_w then begin
               let room = (bw - 8) / Metrics.char_w in
               let shown = if Metrics.cells label > room then
                   (* the first characters that fit *)
                   let b = Buffer.create room and k = ref 0 in
                   String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr k;
                                 if !k <= room then Buffer.add_char b c) label;
                   Buffer.contents b
                 else label in
               emit o (Text { x = !cx + 4; y = by + max 0 ((bh - Metrics.glyph_h) / 2); s = shown;
                              color = 0x50585F; bold = false; italic = false })
             end
           | Space | Break -> ());
          (match a.kind with
           | Word _ | Space when aw > 0 ->
             if st.underline then emit o (Fill { x = !cx; y = text_y + 14; w = aw; h = 1; color = st.color });
             if st.line_through then emit o (Fill { x = !cx; y = text_y + 8; w = aw; h = 1; color = st.color });
             if st.overline then emit o (Fill { x = !cx; y = text_y; w = aw; h = 1; color = st.color })
           | _ -> ())
        end;
        (match a.link with
         | Some href when aw > 0 -> Dynarray.add_last o.links_ { lx = !cx; ly = !y; lw = aw; lh = lh; href }
         | _ -> ());
        cx := !cx + aw) line;
    y := !y + lh;
    first_line := false;
    incr lines_done in
  (* fill the lines *)
  let line = ref [] and lx = ref 0 in
  let avail () = w - (if !first_line then px container.text_indent ~of_:w else 0) in
  let breakable a = a.kind = Space && a.st.white_space <> Nowrap in
  let flush () = if !line <> [] then emit_line (List.rev !line); line := []; lx := 0 in
  (* breaking happens at the last breakable space: rebuild the line from it *)
  let rec place_all atoms =
    match atoms with
    | [] -> flush ()
    | a :: rest ->
      (match a.kind with
       | Break -> if !line = [] then emit_line [] else flush (); place_all rest
       | Space when !line = [] -> place_all rest
       | _ ->
         let aw = atom_width a in
         if !line <> [] && !lx + aw > avail () && a.kind <> Space then begin
           (* go back to the last breakable space in the line *)
           let rec split_at acc = function
             | [] -> None
             | (x, _) :: r when breakable x -> Some (List.rev r, acc)
             | e :: r -> split_at (e :: acc) r in
           (match split_at [] !line with
            | Some (before, after) when before <> [] ->
              (* [line] is newest first: before is the oldest part *)
              let keep = List.rev before and moved = List.map fst after in
              line := keep; flush ();
              place_all (moved @ (a :: rest))
            | _ ->
              (match !line with
               | (last, _) :: _ when (match last.kind with Box _ -> true | _ -> false) ->
                 flush (); place_all (a :: rest)
               | _ ->
                 (* nowhere to break: overflow, unless the word alone is too long *)
                 line := (a, 0) :: !line; lx := !lx + aw; place_all rest))
         end else if !line = [] && aw > avail () && (match a.kind with Word _ -> true | _ -> false) then begin
           match cut_word a (avail ()) with
           | first :: (_ :: _ as more) -> line := [ (first, 0) ]; lx := atom_width first; flush (); place_all (more @ rest)
           | _ -> line := [ (a, 0) ]; lx := aw; place_all rest
         end else begin
           line := (a, 0) :: !line; lx := !lx + aw; place_all rest
         end) in
  place_all atoms;
  !y

(* ---- block layout ---- *)

let list_marker (n : Dom.node) (st : Style.t) =
  (* its number among the list's items *)
  let ordinal () =
    let start = match n.parent with
      | Some p when Dom.is_html p "ol" -> Option.value (Option.bind (Dom.attr p "start") int_of_string_opt) ~default:1
      | _ -> 1 in
    let rec count (m : Dom.node option) k = match m with
      | Some s when Dom.is_html s "li" -> count s.prev (k + 1)
      | Some s -> count s.prev k
      | None -> k in
    match Option.bind (Dom.attr n "value") int_of_string_opt with
    | Some v -> v
    | None -> start + count n.prev 0 in
  let roman k =
    let table = [ 1000, "m"; 900, "cm"; 500, "d"; 400, "cd"; 100, "c"; 90, "xc"; 50, "l"; 40, "xl";
                  10, "x"; 9, "ix"; 5, "v"; 4, "iv"; 1, "i" ] in
    let b = Buffer.create 8 in
    let k = ref k in
    List.iter (fun (v, s) -> while !k >= v do Buffer.add_string b s; k := !k - v done) table;
    Buffer.contents b in
  match st.list_style with
  | "none" -> None
  | "disc" -> Some "\xe2\x80\xa2"
  | "circle" -> Some "\xe2\x97\xa6"
  | "square" -> Some "\xe2\x96\xaa"
  | "decimal" | "decimal-leading-zero" -> Some (string_of_int (ordinal ()) ^ ".")
  | "lower-alpha" | "lower-latin" -> Some (String.make 1 (Char.chr (96 + max 1 (min 26 (ordinal ())))) ^ ".")
  | "upper-alpha" | "upper-latin" -> Some (String.make 1 (Char.chr (64 + max 1 (min 26 (ordinal ())))) ^ ".")
  | "lower-roman" -> Some (roman (ordinal ()) ^ ".")
  | "upper-roman" -> Some (String.uppercase_ascii (roman (ordinal ())) ^ ".")
  | _ -> Some "\xe2\x80\xa2"

(* a block box at (x, y) in a containing block [cw] wide: its border box's
   height, and its vertical margins (for collapsing) *)
let rec block o (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth =
  let m i = match st.margin.(i) with Auto -> None | l -> Some (px l ~of_:cw) in
  let b i = int_of_float (border st i) in
  let p i = px st.padding.(i) ~of_:cw in
  let frame_h = b 1 + b 3 + p 1 + p 3 in
  (* the content width *)
  let content_w, ml, mr =
    let given = match st.width with
      | Auto -> None
      | l -> Some (let v = px l ~of_:cw in if st.border_box then max 0 (v - frame_h) else v) in
    let clamp w =
      let w = match st.max_width with Auto -> w | l ->
        let v = px l ~of_:cw in min w (if st.border_box then max 0 (v - frame_h) else v) in
      let lo = px st.min_width ~of_:cw in
      max w (if st.border_box then max 0 (lo - frame_h) else lo) in
    match given with
    | None ->
      let ml = Option.value (m 3) ~default:0 and mr = Option.value (m 1) ~default:0 in
      let w = clamp (max 0 (cw - ml - mr - frame_h)) in
      (* max-width narrowed it: auto margins center it *)
      let free = cw - w - frame_h - ml - mr in
      (match m 3, m 1 with
       | None, None when free > 0 -> (w, free / 2, free - free / 2)
       | None, Some _ when free > 0 -> (w, free, mr)
       | _ -> (w, ml, mr))
    | Some w ->
      let w = clamp w in
      let free = cw - w - frame_h in
      (match m 3, m 1 with
       | None, None -> (w, max 0 (free / 2), max 0 (free - free / 2))
       | None, Some mr -> (w, max 0 (free - mr), mr)
       | Some ml, None -> (w, ml, max 0 (free - ml))
       | Some ml, Some mr -> (w, ml, mr)) in
  let bx = x + ml in
  let cx = bx + b 3 + p 3 and cy = y + b 0 + p 0 in
  (match Dom.attr n "id" with Some id -> o.anchors_ <- (id, y) :: o.anchors_ | None -> ());
  (* the background first: its height is known after the children *)
  let bg_slot = Dynarray.length o.items_ in
  if visible_color st.background && st.visible then emit o (Fill { x = 0; y = 0; w = 0; h = 0; color = 0 });
  let first_item = Dynarray.length o.items_ in
  let content_h = flow o n st ~x:cx ~y:cy ~cw:content_w ~depth in
  let content_h = match st.height with
    | Len (hp, 0.) -> let h = int_of_float hp in if st.border_box then max 0 (h - b 0 - b 2 - p 0 - p 2) else h
    | _ -> content_h in
  let content_h = max content_h (match st.min_height with Len (hp, 0.) -> int_of_float hp | _ -> 0) in
  let content_h = match st.max_height with Len (hp, 0.) -> min content_h (int_of_float hp) | _ -> content_h in
  let h = b 0 + p 0 + content_h + p 2 + b 2 in
  let w = b 3 + p 3 + content_w + p 1 + b 1 in
  if visible_color st.background && st.visible then
    Dynarray.set o.items_ bg_slot (Fill { x = bx; y; w; h; color = rgb st.background });
  (* the borders *)
  if st.visible then begin
    let c i = if st.border_color.(i) < 0 then st.color else st.border_color.(i) in
    if b 0 > 0 then emit o (Fill { x = bx; y; w; h = b 0; color = c 0 });
    if b 2 > 0 then emit o (Fill { x = bx; y = y + h - b 2; w; h = b 2; color = c 2 });
    if b 3 > 0 then emit o (Fill { x = bx; y; w = b 3; h; color = c 3 });
    if b 1 > 0 then emit o (Fill { x = bx + w - b 1; y; w = b 1; h; color = c 1 })
  end;
  (* a list item's marker, before its first line *)
  if st.display = List_item && st.visible then begin
    match list_marker n st with
    | Some mk ->
      let lh = Metrics.line_height st in
      let first_text_y =
        let rec find i = if i >= Dynarray.length o.items_ then None
          else match Dynarray.get o.items_ i with Text t -> Some t.y | _ -> find (i + 1) in
        find first_item in
      let ty = Option.value first_text_y ~default:(cy + (lh - Metrics.glyph_h) / 2) in
      emit o (Text { x = cx - Metrics.width st mk - Metrics.char_w; y = ty; s = mk; color = st.color;
                     bold = false; italic = false })
    | None -> ()
  end;
  (h, Option.value (m 0) ~default:0, Option.value (m 2) ~default:0, ml + w + mr)

(* a block container's content: blocks, and the inline runs between them
   (anonymous blocks); the height used *)
and flow o (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth =
  let ps = pieces o n ~cw ~depth in
  let cur_y = ref y in
  let prev_margin = ref 0 in      (* the last block's bottom margin, not yet added *)
  let pending = ref [] in
  let flush_inline () =
    if !pending <> [] then begin
      let atoms = atoms_of (List.rev !pending) in
      pending := [];
      if List.exists (fun a -> match a.kind with Word _ | Box _ | Break -> true | Space -> false) atoms then begin
        cur_y := !cur_y + !prev_margin; prev_margin := 0;
        cur_y := inline_layout o st atoms ~x ~y:!cur_y ~w:cw
      end
    end in
  List.iter (function
      | P_block (child, cst) ->
        flush_inline ();
        (* the child's top margin collapses with the previous bottom margin *)
        let mt = match cst.margin.(0) with Auto -> 0 | l -> px l ~of_:cw in
        let collapsed =
          if mt >= 0 && !prev_margin >= 0 then max mt !prev_margin
          else if mt < 0 && !prev_margin < 0 then min mt !prev_margin
          else mt + !prev_margin in
        let top = !cur_y + collapsed in
        let h, _, mb, _ = block o child cst ~x ~y:top ~cw ~depth:(depth + 1) in
        (* an empty block's margins collapse through it *)
        if h = 0 then (prev_margin := max collapsed mb; cur_y := !cur_y)
        else (cur_y := top + h; prev_margin := mb)
      | p -> pending := p :: !pending) ps;
  flush_inline ();
  !cur_y + !prev_margin - y

(* ---- the page ---- *)

let layout ~width ~height (styles : Style.styles) (doc : Dom.node) =
  let o = { items_ = Dynarray.create (); links_ = Dynarray.create (); anchors_ = []; styles; viewport_h = height } in
  let root = Dom.find (fun n -> Dom.is_html n "html") doc in
  let total =
    match root with
    | Some html ->
      (match Style.get styles html with
       | Some st when st.display <> None_ ->
         let h, mt, mb, _ = block o html st ~x:0 ~y:0 ~cw:width ~depth:0 in
         mt + h + mb
       | _ -> 0)
    | None -> 0 in
  (* the canvas: the root's background, else the body's *)
  let bg_of n = match Option.bind n (Style.get styles) with
    | Some st when visible_color st.background -> Some (rgb st.background) | _ -> None in
  let background =
    match bg_of root with
    | Some c -> c
    | None -> (match bg_of (Dom.find (fun n -> Dom.is_html n "body") doc) with Some c -> c | None -> 0xFFFFFF) in
  { items = Dynarray.to_array o.items_; links = Dynarray.to_array o.links_; height = total; background;
    anchors = o.anchors_ }

(* ---- the display list as text, for the tests ---- *)

let dump p =
  let b = Buffer.create 4096 in
  Array.iter (function
      | Fill { x; y; w; h; color } -> Printf.bprintf b "fill %d,%d %dx%d #%06x\n" x y w h color
      | Text { x; y; s; color; bold; italic } ->
        Printf.bprintf b "text %d,%d%s%s #%06x %s\n" x y (if bold then " bold" else "")
          (if italic then " italic" else "") color s) p.items;
  Array.iter (fun l -> Printf.bprintf b "link %d,%d %dx%d %s\n" l.lx l.ly l.lw l.lh l.href) p.links;
  Printf.bprintf b "height %d\n" p.height;
  Buffer.contents b
