(* Layout: CSS's visual formatting model, as far as M5 goes.

   - Block boxes: widths (auto, lengths, shrink-to-fit), auto margins,
     borders, padding, heights; margins collapsing between siblings and
     through a parent's top and bottom.
   - Inline formatting: lines broken at spaces, white-space, text-align,
     text-indent, line-height, vertical-align (sub, super, middle),
     inline-blocks as boxes in the line.
   - Floats (left, right) in their block formatting context: lines and
     new formatting contexts are shortened beside them; clear.
   - Positioning: relative offsets; absolute and fixed boxes, placed in
     their containing block once it is laid out.
   - overflow: hidden clips; flexbox; grid (template areas, tracks in px,
     fr, minmax, repeat, auto; line numbers; auto-placement); tables
     (automatic layout, colspan, rowspan).

   The result is a display list in page coordinates, and the links'
   rectangles. Boxes are measured by laying them out "dry" (nothing
   emitted), the results cached by element and width, so that flexbox,
   grid and tables can size their children before placing them. Until M2
   text is measured in the window's font, Terminus, 8 x 16 pixels
   (Metrics); until M4 an image is its alt text or a frame.

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

(* a float's margin box, in page coordinates *)
type flt = { left : bool; fx : int; fy : int; fw : int; fh : int }

(* a block formatting context: its floats *)
type bfc = { mutable floats : flt list }

(* an absolutely positioned box waiting for its containing block, with its
   static position *)
type pending = { pn : Dom.node; pst : Style.t; sx : int; sy : int }

type out = {
  items_ : item Dynarray.t;
  links_ : link Dynarray.t;
  mutable anchors_ : (string * int) list;
  styles : Style.styles;
  vw : int;
  vh : int;
  mutable dry : int;                                  (* > 0: measuring, nothing emitted *)
  mutable clip : (int * int * int * int) option;      (* x0, y0, x1, y1 *)
  measures : (int * int, int * int) Hashtbl.t;         (* element, width -> border box w, h *)
  intrinsics : (int, int * int) Hashtbl.t;             (* element -> min-, max-content widths *)
  mutable abs : pending list ref list;                (* per containing block, innermost first *)
}

let rgb c = c land 0xFFFFFF
let visible_color c = c lsr 24 <> 0

let px (l : length) ~of_ = match l with
  | Auto -> 0
  | Len (p, pct) -> int_of_float (Float.round (p +. pct *. float of_ /. 100.))

let is_auto = function Auto -> true | _ -> false
let zero_margins = [| Len (0., 0.); Len (0., 0.); Len (0., 0.); Len (0., 0.) |]

let max_depth = 150

let emit o it =
  if o.dry = 0 then
    match o.clip with
    | None -> Dynarray.add_last o.items_ it
    | Some (x0, y0, x1, y1) ->
      (match it with
       | Fill f ->
         let x = max f.x x0 and y = max f.y y0 and x2 = min (f.x + f.w) x1 and y2 = min (f.y + f.h) y1 in
         if x2 > x && y2 > y then Dynarray.add_last o.items_ (Fill { f with x; y; w = x2 - x; h = y2 - y })
       | Text t ->
         let w = Metrics.cells t.s * Metrics.char_w in
         if t.y + Metrics.glyph_h > y0 && t.y < y1 && t.x < x1 && t.x + w > x0 then Dynarray.add_last o.items_ it)

let add_link o l =
  if o.dry = 0 then
    match o.clip with
    | Some (x0, y0, x1, y1) when l.lx >= x1 || l.lx + l.lw <= x0 || l.ly >= y1 || l.ly + l.lh <= y0 -> ()
    | _ -> Dynarray.add_last o.links_ l

let add_anchor o id y = if o.dry = 0 then o.anchors_ <- (id, y) :: o.anchors_

(* what was emitted since a mark, moved by (dx, dy) *)
type mark = { mi : int; ml : int; ma : int }
let mark o = { mi = Dynarray.length o.items_; ml = Dynarray.length o.links_; ma = List.length o.anchors_ }

let translate o m dx dy =
  if (dx <> 0 || dy <> 0) && o.dry = 0 then begin
    for i = m.mi to Dynarray.length o.items_ - 1 do
      Dynarray.set o.items_ i (match Dynarray.get o.items_ i with
          | Fill f -> Fill { f with x = f.x + dx; y = f.y + dy }
          | Text t -> Text { t with x = t.x + dx; y = t.y + dy })
    done;
    for i = m.ml to Dynarray.length o.links_ - 1 do
      let l = Dynarray.get o.links_ i in
      Dynarray.set o.links_ i { l with lx = l.lx + dx; ly = l.ly + dy }
    done;
    let added = List.length o.anchors_ - m.ma in
    o.anchors_ <- List.mapi (fun i (id, y) -> if i < added then (id, y + dy) else (id, y)) o.anchors_
  end

(* ---- floats ---- *)

let overlaps f y h = f.fy < y + h && f.fy + f.fh > y

let left_edge bfc y h x0 =
  List.fold_left (fun e f -> if f.left && overlaps f y h then max e (f.fx + f.fw) else e) x0 bfc.floats

let right_edge bfc y h x1 =
  List.fold_left (fun e f -> if (not f.left) && overlaps f y h then min e f.fx else e) x1 bfc.floats

let clear_y bfc which y =
  List.fold_left (fun m f ->
      if which = "both" || ((which = "left" || which = "inline-start") && f.left)
         || ((which = "right" || which = "inline-end") && not f.left)
      then max m (f.fy + f.fh) else m) y bfc.floats

(* the nearest float bottom below y: where to try again *)
let next_bottom bfc y =
  List.fold_left (fun m f ->
      if f.fy + f.fh > y then Some (match m with None -> f.fy + f.fh | Some b -> min b (f.fy + f.fh)) else m)
    None bfc.floats

(* where a float of outer size w x h goes, from y down *)
let place_float bfc ~left ~w ~h ~x0 ~x1 ~y =
  let rec go y n =
    let l = left_edge bfc y h x0 and r = right_edge bfc y h x1 in
    if r - l >= w || n > 50 then ((if left then l else r - w), y)
    else match next_bottom bfc y with
      | Some b -> go b (n + 1)
      | None -> ((if left then l else r - w), y) in
  go y 0

(* ---- the pieces of a block container's content ---- *)

type atom_kind =
  | Word of string
  | Space
  | Break
  | Box of { w : int; h : int; label : string; frame : bool }
  | Ibox of { node : Dom.node; bw : int; bh : int; ml : int; mr : int }   (* an inline-block *)
  | Float of Dom.node                                                    (* a float met in a line *)
  | Abs of Dom.node                                                      (* where its static position is *)

type atom = { kind : atom_kind; st : Style.t; link : string option; bg : int }

type piece =
  | P_block of Dom.node * Style.t
  | P_float of Dom.node * Style.t
  | P_abs of Dom.node * Style.t
  | P_atom of atom
  | P_text of string * Style.t * string option * int
  | P_space of int * Style.t

let block_level = function
  | Block | List_item | Table | Table_row | Table_group | Table_caption | Flex | Grid | Table_cell -> true
  | _ -> false

let inline_box = function Inline_block | Inline_flex | Inline_grid -> true | _ -> false
let positioned (st : Style.t) = st.position = Absolute || st.position = Fixed

let transform st w =
  match st.Style.transform with
  | No_transform -> w
  | Upper -> String.uppercase_ascii w
  | Lower -> String.lowercase_ascii w
  | Capitalize -> String.capitalize_ascii w

let is_atomic n = List.mem (Dom.name n) [ "img"; "input"; "button"; "select"; "textarea"; "iframe"; "video";
                                          "canvas"; "embed"; "object"; "audio"; "svg" ]

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

(* the pieces of a container's content: its inline descendants flattened
   (a loop: Dom.walk), its block-level, floating and positioned ones as
   boxes to lay out *)
let pieces o (container : Dom.node) ~cw ~depth =
  let out = ref [] in
  let links = ref [] and bgs = ref [] in
  let add p = out := p :: !out in
  let top_link () = match !links with l :: _ -> l | [] -> None in
  let flows_inline (n : Dom.node) (st : Style.t) =
    not (st.display = None_ || st.clipped || positioned st || st.float_ <> "none"
         || Dom.is_html n "br" || (block_level st.display && depth < max_depth)
         || is_atomic n || (inline_box st.display && depth < max_depth) || st.display = Table_column) in
  let enter (n : Dom.node) =
    if n == container then true
    else match n.kind with
      | Text { data } ->
        (match Option.bind n.parent (fun p -> Style.get o.styles p) with
         | Some st when st.display <> None_ ->
           add (P_text (data, st, top_link (), (match !bgs with b :: _ -> b | [] -> 0)))
         | _ -> ());
        false
      | Element _ ->
        (match Style.get o.styles n with
         | None -> false
         | Some st ->
           if st.display = None_ || st.clipped || st.display = Table_column then false
           else if positioned st then (add (P_abs (n, st)); false)
           else if st.float_ <> "none" then (add (P_float (n, st)); false)
           else if Dom.is_html n "br" then (add (P_atom { kind = Break; st; link = None; bg = 0 }); false)
           else if block_level st.display && depth < max_depth then (add (P_block (n, st)); false)
           else if is_atomic n then begin
             (match atomic n st ~cw with
              | Some kind -> add (P_atom { kind; st; link = top_link (); bg = 0 })
              | None -> ());
             false
           end else if inline_box st.display && depth < max_depth then begin
             add (P_atom { kind = Ibox { node = n; bw = 0; bh = 0; ml = 0; mr = 0 }; st; link = top_link (); bg = 0 });
             false
           end else begin
             let href = if Dom.is_html n "a" then Dom.attr n "href" else None in
             links := (match href with Some h -> Some h | None -> top_link ()) :: !links;
             bgs := (if visible_color st.background then st.background else (match !bgs with b :: _ -> b | [] -> 0)) :: !bgs;
             if st.display <> Contents then begin
               let left = px st.margin.(3) ~of_:cw + int_of_float (border st 3) + px st.padding.(3) ~of_:cw in
               if left > 0 then add (P_space (left, st))
             end;
             true
           end)
      | _ -> false in
  let leave (n : Dom.node) =
    if n != container then
      match n.kind, Style.get o.styles n with
      | Element _, Some st when flows_inline n st ->
        links := (match !links with _ :: r -> r | [] -> []);
        bgs := (match !bgs with _ :: r -> r | [] -> []);
        if st.display <> Contents then begin
          let right = px st.margin.(1) ~of_:cw + int_of_float (border st 1) + px st.padding.(1) ~of_:cw in
          if right > 0 then add (P_space (right, st))
        end
      | _ -> () in
  Dom.walk ~enter ~leave container;
  List.rev !out

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012'

(* text pieces to words and spaces, white-space applied *)
let atoms_of pieces =
  let out = ref [] in
  let prev_space = ref true in
  let add a = out := a :: !out in
  List.iter (function
      | P_atom a -> add a; prev_space := (a.kind = Break)
      | P_space (w, st) -> add { kind = Box { w; h = 0; label = ""; frame = false }; st; link = None; bg = 0 }
      | P_float (n, st) -> add { kind = Float n; st; link = None; bg = 0 }
      | P_abs (n, st) -> add { kind = Abs n; st; link = None; bg = 0 }
      | P_block _ -> ()
      | P_text (data, st, link, bg) ->
        let mk kind = { kind; st; link; bg } in
        (match st.white_space with
         | Pre | Pre_wrap ->
           let lines = String.split_on_char '\n' data in
           List.iteri (fun i line ->
               if i > 0 then add (mk Break);
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
  | Break | Float _ | Abs _ -> 0
  | Box { w; _ } -> w
  | Ibox { bw; ml; mr; _ } -> ml + bw + mr

let cut_word a avail =
  match a.kind with
  | Word w when atom_width a > avail && avail >= Metrics.char_w ->
    let per = max 1 (avail / Metrics.char_w) in
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

let list_marker (n : Dom.node) (st : Style.t) =
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

(* two margins collapsed *)
let collapse a b =
  if a >= 0 && b >= 0 then max a b else if a < 0 && b < 0 then min a b else a + b

(* the horizontal frame: (margins), borders, padding, in px *)
let hframe (st : Style.t) ~cw ~margins =
  (if margins then px st.margin.(3) ~of_:cw + px st.margin.(1) ~of_:cw else 0)
  + int_of_float (border st 1 +. border st 3) + px st.padding.(1) ~of_:cw + px st.padding.(3) ~of_:cw

(* what [block] gives back *)
type result = {
  h : int;            (* the border box's height *)
  w : int;            (* the border box's width *)
  mt : int;           (* the top margin, with what collapsed in through it *)
  mb : int;
}

let establishes_bfc (st : Style.t) =
  st.overflow_bfc || st.float_ <> "none" || positioned st
  || (match st.display with Inline_block | Inline_flex | Inline_grid | Flex | Grid | Table | Table_cell
                          | Table_caption -> true | _ -> false)

let ctx_of o (st : Style.t) = { vw = float o.vw; vh = float o.vh; root_fs = 16.; fs = st.font_size;
                                 parent_fs = st.font_size }

(* a flex or grid item: an element, or a run of text *)
type fitem = Item of Dom.node * Style.t | Txt of string * Style.t

(* ---- the layout itself ---- *)

(* a box's border-box size, laid out dry [bw] wide (forced) *)
let rec measure_forced o (node : Dom.node) st ~bw =
  match Hashtbl.find_opt o.measures (node.id, bw) with
  | Some r -> r
  | None ->
    o.dry <- o.dry + 1;
    let r = block o ~force_w:bw ~bfc:{ floats = [] } node st ~x:0 ~y:0 ~cw:bw ~depth:0 in
    o.dry <- o.dry - 1;
    let res = (r.w, r.h) in
    Hashtbl.replace o.measures (node.id, bw) res;
    res

(* min-content and max-content widths of the border box *)
and intrinsic o (n : Dom.node) (st : Style.t) =
  match Hashtbl.find_opt o.intrinsics n.id with
  | Some r -> r
  | None ->
    let frame = hframe st ~cw:0 ~margins:false in
    let r =
      match st.width with
      | Len (p, 0.) ->
        let w = int_of_float p in
        let w = if st.border_box then w else w + frame in
        (w, w)
      | _ ->
        let mn, mx =
          match st.display with
          | Flex | Inline_flex ->
            let sizes = List.map (item_intrinsic o) (flex_items o n) in
            let gap = px st.column_gap ~of_:0 in
            if st.flex_direction = "column" || st.flex_direction = "column-reverse" then
              (List.fold_left (fun m (a, _) -> max m a) 0 sizes, List.fold_left (fun m (_, b) -> max m b) 0 sizes)
            else
              let total_gap = gap * max 0 (List.length sizes - 1) in
              ((if st.flex_wrap then List.fold_left (fun m (a, _) -> max m a) 0 sizes
                else List.fold_left (fun s (a, _) -> s + a) 0 sizes + total_gap),
               List.fold_left (fun s (_, b) -> s + b) 0 sizes + total_gap)
          | Table ->
            let t = table_grid o n in
            let mins, maxs = table_columns o t ~avail:None in
            let sp = table_spacing st * (Array.length mins + 1) in
            (Array.fold_left ( + ) 0 mins + sp, Array.fold_left ( + ) 0 maxs + sp)
          | _ ->
            let ps = pieces o n ~cw:0 ~depth:0 in
            let blocks = List.filter_map (function
                | P_block (c, cst) | P_float (c, cst) ->
                  let a, b = intrinsic o c cst in
                  let m = hframe cst ~cw:0 ~margins:true - hframe cst ~cw:0 ~margins:false in
                  Some (a + m, b + m)
                | _ -> None) ps in
            let atoms = List.map (fun a -> resolve_atom o a ~cw:0) (atoms_of ps) in
            (* the longest unbreakable run, the longest line *)
            let mn = ref 0 and mx = ref 0 and run = ref 0 and line = ref 0 in
            List.iter (fun a ->
                match a.kind with
                | Break -> mx := max !mx !line; line := 0; mn := max !mn !run; run := 0
                | Space when a.st.white_space <> Nowrap ->
                  line := !line + atom_width a; mn := max !mn !run; run := 0
                | Ibox { node; ml; mr; _ } ->
                  let bmin, _ = intrinsic o node a.st in
                  line := !line + atom_width a; mn := max !mn (!run + ml + bmin + mr); run := 0
                | _ -> let w = atom_width a in line := !line + w; run := !run + w) atoms;
            mx := max !mx !line; mn := max !mn !run;
            List.fold_left (fun (a, b) (c, d) -> (max a c, max b d)) (!mn, !mx) blocks in
        (mn + frame, mx + frame) in
    let r = match st.max_width with
      | Len (p, 0.) -> let m = int_of_float p + (if st.border_box then 0 else frame) in (min (fst r) m, min (snd r) m)
      | _ -> r in
    Hashtbl.replace o.intrinsics n.id r;
    r

and shrink_to_fit o n st ~avail =
  let mn, mx = intrinsic o n st in
  min (max mn avail) mx

(* an inline-block's size, once the line's width is known *)
and resolve_atom o a ~cw =
  match a.kind with
  | Ibox { node; _ } ->
    let st = a.st in
    let ml = px st.margin.(3) ~of_:cw and mr = px st.margin.(1) ~of_:cw in
    let bw = match st.width with
      | Auto -> shrink_to_fit o node st ~avail:(max 0 (cw - ml - mr))
      | l -> let v = px l ~of_:cw in if st.border_box then v else v + hframe st ~cw ~margins:false in
    let _, bh = measure_forced o node st ~bw in
    { a with kind = Ibox { node; bw; bh; ml; mr } }
  | _ -> a

(* an absolutely positioned box, to lay out with its containing block *)
and register_abs o (n : Dom.node) (st : Style.t) ~x ~y =
  if o.dry = 0 then begin
    let p = { pn = n; pst = st; sx = x; sy = y } in
    match st.position, o.abs with
    | Fixed, l ->
      (match List.rev l with root :: _ -> root := p :: !root | [] -> ())
    | _, l :: _ -> l := p :: !l
    | _, [] -> ()
  end

and layout_abs o (cbx, cby, cbw, cbh) (p : pending) ~depth =
  let st = p.pst in
  let ins i = match st.inset.(i) with Auto -> None | l -> Some (px l ~of_:(if i = 0 || i = 2 then cbh else cbw)) in
  let ml = px st.margin.(3) ~of_:cbw and mr = px st.margin.(1) ~of_:cbw in
  let mt = px st.margin.(0) ~of_:cbw in
  let bw = match st.width, ins 3, ins 1 with
    | Auto, Some l, Some r -> max 0 (cbw - l - r - ml - mr)
    | Auto, _, _ -> shrink_to_fit o p.pn st ~avail:(max 0 (cbw - ml - mr))
    | w, _, _ -> let v = px w ~of_:cbw in if st.border_box then v else v + hframe st ~cw:cbw ~margins:false in
  let _, bh = measure_forced o p.pn st ~bw in
  let x = match ins 3, ins 1 with
    | Some l, _ -> cbx + l + ml
    | None, Some r -> cbx + cbw - r - mr - bw
    | None, None -> p.sx + ml in
  let y = match ins 0, ins 2 with
    | Some t, _ -> cby + t + mt
    | None, Some b -> cby + cbh - b - bh
    | None, None -> p.sy + mt in
  (* laid out where it goes, as a positioned (relative, not moved) box *)
  ignore (block o ~force_w:bw ~bfc:{ floats = [] } p.pn
            { st with position = Relative; inset = Array.make 4 Auto; margin = zero_margins }
            ~x ~y ~cw:bw ~depth)

(* a block box at (x, y) in a containing block [cw] wide *)
and block o ?force_w ?force_h ?(valign = 0) ~bfc (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth =
  let m i = match st.margin.(i) with Auto -> None | l -> Some (px l ~of_:cw) in
  let b i = int_of_float (border st i) in
  let p i = px st.padding.(i) ~of_:cw in
  let frame_w = b 1 + b 3 + p 1 + p 3 in
  let shrink = st.float_ <> "none" || inline_box st.display || st.display = Table || positioned st in
  (* the border box's width, and the horizontal margins *)
  let bw, ml =
    match force_w with
    | Some w -> (w, Option.value (m 3) ~default:0)
    | None ->
      let given = match st.width with
        | Auto -> None
        | l -> Some (let v = px l ~of_:cw in if st.border_box then v else v + frame_w) in
      let clamp w =
        let w = match st.max_width with Auto -> w | l ->
          let v = px l ~of_:cw in min w (if st.border_box then v else v + frame_w) in
        let lo = px st.min_width ~of_:cw in
        max w (if st.border_box then lo else lo + frame_w) in
      let ml0 = Option.value (m 3) ~default:0 and mr0 = Option.value (m 1) ~default:0 in
      let w = match given with
        | Some w -> clamp w
        | None ->
          if shrink then clamp (shrink_to_fit o n st ~avail:(max 0 (cw - ml0 - mr0)))
          else clamp (max 0 (cw - ml0 - mr0)) in
      let free = cw - w - ml0 - mr0 in
      (match m 3, m 1 with
       | None, None when free > 0 && not shrink -> (w, free / 2)
       | None, Some _ when free > 0 && not shrink -> (w, free)
       | _ -> (w, ml0)) in
  let bw = max bw frame_w in
  let content_w = bw - frame_w in
  let bx = x + ml in
  let cx = bx + b 3 + p 3 and cy = y + b 0 + p 0 + valign in
  (match Dom.attr n "id" with Some id -> add_anchor o id y | None -> ());
  let start = mark o in
  (* the background first: its height is known after the content *)
  let has_bg = visible_color st.background && st.visible && not st.masked && not st.transparent && o.dry = 0 in
  let bg_slot = Dynarray.length o.items_ in
  if has_bg then Dynarray.add_last o.items_ (Fill { x = 0; y = 0; w = 0; h = 0; color = 0 });
  let first_item = Dynarray.length o.items_ in
  let own_bfc = establishes_bfc st in
  let bfc' = if own_bfc then { floats = [] } else bfc in
  (* a positioned box is the containing block of its absolute descendants *)
  let is_cb = st.position <> Static && o.dry = 0 in
  if is_cb then o.abs <- ref [] :: o.abs;
  let definite_h = match force_h, st.height with
    | Some h, _ -> Some (max 0 (h - b 0 - b 2 - p 0 - p 2 - valign))
    | None, Len (hp, 0.) ->
      let h = int_of_float hp in Some (if st.border_box then max 0 (h - b 0 - b 2 - p 0 - p 2) else h)
    | _ -> None in
  (* overflow: hidden: what is drawn outside the padding box is cut *)
  let saved_clip = o.clip in
  if st.overflow_clip && o.dry = 0 then begin
    let x0 = bx + b 3 and x1 = bx + bw - b 1 in
    let y0, y1 = match definite_h with
      | Some h -> (y + b 0, y + b 0 + p 0 + valign + h + p 2)
      | None -> (min_int / 2, max_int / 2) in
    o.clip <- Some (match saved_clip with
        | Some (a, bb, c, d) -> (max a x0, max bb y0, min c x1, min d y1)
        | None -> (x0, y0, x1, y1))
  end;
  let collapse_top = not own_bfc && b 0 = 0 && p 0 = 0 && valign = 0 && force_h = None in
  let collapse_bottom = not own_bfc && b 2 = 0 && p 2 = 0 && definite_h = None in
  let content_h, esc_top, esc_bottom =
    match st.display with
    | Flex | Inline_flex -> (flex o n st ~x:cx ~y:cy ~cw:content_w ~ch:definite_h ~depth, 0, 0)
    | Grid | Inline_grid -> (grid o n st ~x:cx ~y:cy ~cw:content_w ~depth, 0, 0)
    | Table -> (table o n st ~x:cx ~y:cy ~cw:content_w ~depth, 0, 0)
    | _ -> flow o ~bfc:bfc' n st ~x:cx ~y:cy ~cw:content_w ~depth ~collapse_top ~collapse_bottom in
  (* a formatting context's height holds its floats *)
  let content_h =
    if own_bfc then List.fold_left (fun h f -> max h (f.fy + f.fh - cy)) content_h bfc'.floats
    else content_h in
  let vframe = b 0 + b 2 + p 0 + p 2 in
  let content_h = match definite_h with Some h -> h | None -> content_h in
  let content_h = max content_h (match st.min_height with
      | Len (hp, 0.) -> int_of_float hp - (if st.border_box then vframe else 0) | _ -> 0) in
  let content_h = match st.max_height, force_h with
    | Len (hp, 0.), None -> min content_h (int_of_float hp - (if st.border_box then vframe else 0))
    | _ -> content_h in
  let h = vframe + valign + content_h in
  o.clip <- saved_clip;
  if has_bg then Dynarray.set o.items_ bg_slot (Fill { x = bx; y; w = bw; h; color = rgb st.background });
  if st.visible && not st.transparent && o.dry = 0 then begin
    (* a border's colour: currentcolor (-1), or 0xAARRGGBB; transparent ones are not drawn *)
    let c i = if st.border_color.(i) < 0 then st.color else rgb st.border_color.(i) in
    let shown i = b i > 0 && (st.border_color.(i) < 0 || visible_color st.border_color.(i)) in
    if shown 0 then emit o (Fill { x = bx; y; w = bw; h = b 0; color = c 0 });
    if shown 2 then emit o (Fill { x = bx; y = y + h - b 2; w = bw; h = b 2; color = c 2 });
    if shown 3 then emit o (Fill { x = bx; y; w = b 3; h; color = c 3 });
    if shown 1 then emit o (Fill { x = bx + bw - b 1; y; w = b 1; h; color = c 1 })
  end;
  if st.display = List_item && st.visible && not st.transparent && o.dry = 0 then begin
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
  (* the absolutely positioned descendants, now that this box's size is known *)
  if is_cb then begin
    let pend = match o.abs with l :: rest -> o.abs <- rest; List.rev !l | [] -> [] in
    List.iter (layout_abs o (bx + b 3, y + b 0, bw - b 3 - b 1, h - b 0 - b 2) ~depth:(depth + 1)) pend
  end;
  (* relative positioning: moved, without moving anything else *)
  if st.position = Relative then begin
    let ins i = match st.inset.(i) with Auto -> None | l -> Some (px l ~of_:cw) in
    let dx = match ins 3, ins 1 with Some l, _ -> l | None, Some r -> - r | _ -> 0 in
    let dy = match ins 0, ins 2 with Some t, _ -> t | None, Some bo -> - bo | _ -> 0 in
    translate o start dx dy
  end;
  let mt = Option.value (m 0) ~default:0 and mb = Option.value (m 2) ~default:0 in
  { h; w = bw;
    mt = (if collapse_top && esc_top <> 0 then collapse mt esc_top else mt);
    mb = (if collapse_bottom && esc_bottom <> 0 then collapse mb esc_bottom else mb) }

(* a block container's content: blocks, floats, and the inline runs
   between them; its height, and the margins that collapsed out through
   its top and its bottom *)
and flow o ~bfc (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth ~collapse_top ~collapse_bottom =
  let ps = pieces o n ~cw ~depth in
  let cur_y = ref y in
  let prev_margin = ref 0 in
  let started = ref false in
  let esc_top = ref 0 in
  let last_block = ref false in
  let pending = ref [] in
  let flush_inline () =
    if !pending <> [] then begin
      let atoms = atoms_of (List.rev !pending) in
      pending := [];
      let content = List.exists (fun a -> match a.kind with
          | Word _ | Box _ | Break | Ibox _ -> true | _ -> false) atoms in
      let others = List.exists (fun a -> match a.kind with Float _ | Abs _ -> true | _ -> false) atoms in
      if content then begin
        cur_y := !cur_y + !prev_margin; prev_margin := 0; started := true; last_block := false
      end;
      if content || others then cur_y := inline_layout o ~bfc st atoms ~x ~y:!cur_y ~w:cw ~depth
    end in
  List.iter (function
      | P_block (child, cst) ->
        flush_inline ();
        let own = establishes_bfc cst in
        let mt = match cst.margin.(0) with Auto -> 0 | l -> px l ~of_:cw in
        let first = not !started && collapse_top in
        let collapsed = if first then 0 else collapse mt !prev_margin in
        let top0 = !cur_y + collapsed in
        let top0 = if cst.clear <> "none" then max top0 (clear_y bfc cst.clear !cur_y) else top0 in
        (* a new formatting context goes beside the floats *)
        let cx, ccw =
          if own && bfc.floats <> [] then
            let l = left_edge bfc top0 1 x and r = right_edge bfc top0 1 (x + cw) in
            (l, max 0 (r - l))
          else (x, cw) in
        let m0 = mark o in
        let r = block o ~bfc child cst ~x:cx ~y:top0 ~cw:ccw ~depth:(depth + 1) in
        (* a margin that collapsed in through the child's top moves it down *)
        let top =
          if r.mt <> mt && not first then begin
            let d = collapse r.mt !prev_margin - collapsed in
            translate o m0 0 d; top0 + d
          end else top0 in
        if first then esc_top := r.mt;
        if r.h = 0 && not own then prev_margin := (if first then r.mb else collapse collapsed r.mb)
        else begin cur_y := top + r.h; prev_margin := r.mb; started := true end;
        last_block := true
      | P_float (child, cst) ->
        flush_inline ();
        place_one_float o ~bfc child cst ~x ~y:(!cur_y + !prev_margin) ~cw ~depth
      | P_abs (child, cst) ->
        flush_inline ();
        register_abs o child cst ~x ~y:(!cur_y + !prev_margin)
      | p -> pending := p :: !pending) ps;
  flush_inline ();
  if collapse_bottom && !last_block then (!cur_y - y, !esc_top, !prev_margin)
  else (!cur_y + !prev_margin - y, !esc_top, 0)

and place_one_float o ~bfc child cst ~x ~y ~cw ~depth =
  let left = cst.float_ = "left" || cst.float_ = "inline-start" in
  let ml = px cst.margin.(3) ~of_:cw and mr = px cst.margin.(1) ~of_:cw in
  let mt = px cst.margin.(0) ~of_:cw and mb = px cst.margin.(2) ~of_:cw in
  let to_border l = let v = px l ~of_:cw in if cst.border_box then v else v + hframe cst ~cw ~margins:false in
  let bw = match cst.width with
    | Auto -> shrink_to_fit o child cst ~avail:(max 0 (cw - ml - mr))
    | l -> to_border l in
  let bw = match cst.max_width with Auto -> bw | l -> min bw (to_border l) in
  let _, bh = measure_forced o child cst ~bw in
  let ow = ml + bw + mr and oh = mt + bh + mb in
  let y = if cst.clear <> "none" then clear_y bfc cst.clear y else y in
  let fx, fy = place_float bfc ~left ~w:ow ~h:oh ~x0:x ~x1:(x + cw) ~y in
  ignore (block o ~force_w:bw ~bfc:{ floats = [] } child { cst with margin = zero_margins }
            ~x:(fx + ml) ~y:(fy + mt) ~cw:bw ~depth:(depth + 1));
  bfc.floats <- { left; fx; fy; fw = ow; fh = oh } :: bfc.floats

(* lines from [y], in [x, x + w) less the floats; the y after them *)
and inline_layout o ~bfc (container : Style.t) atoms ~x ~y ~w ~depth =
  let atoms = List.map (fun a -> resolve_atom o a ~cw:w) atoms in
  let strut = Metrics.line_height container in
  let y = ref y in
  let first_line = ref true in
  let edges () = (left_edge bfc !y strut x, right_edge bfc !y strut (x + w)) in
  let emit_line (line : atom list) =
    let rec drop_trailing = function
      | a :: r when a.kind = Space -> drop_trailing r
      | l -> l in
    let line = List.rev (drop_trailing (List.rev line)) in
    let l, r = edges () in
    let lw = r - l in
    let width = List.fold_left (fun acc a -> acc + atom_width a) 0 line in
    let indent = if !first_line then px container.text_indent ~of_:w else 0 in
    let lh = List.fold_left (fun m a ->
        match a.kind with
        | Box { h; _ } -> max m h
        | Ibox { bh; _ } -> max m bh
        | Word _ | Space -> max m (Metrics.line_height a.st)
        | _ -> m) strut line in
    let shift = match container.text_align with
      | Center -> max 0 ((lw - indent - width) / 2)
      | Right -> max 0 (lw - indent - width)
      | Left | Justify -> 0 in
    let cx = ref (l + indent + shift) in
    let line_y = !y in
    let text_y = line_y + (lh - Metrics.glyph_h) / 2 in
    List.iter (fun a ->
        let aw = atom_width a in
        let st = a.st in
        let ty = match st.vertical_align with
          | "super" -> text_y - 5 | "sub" -> text_y + 4 | _ -> text_y in
        if st.visible && not st.transparent then begin
          if a.bg <> 0 && aw > 0 then
            emit o (Fill { x = !cx; y = ty - 1; w = aw; h = Metrics.glyph_h + 2; color = rgb a.bg });
          (match a.kind with
           | Word s ->
             emit o (Text { x = !cx; y = ty; s; color = st.color; bold = st.font_weight >= 600; italic = st.italic })
           | Box { w = bw; h = bh; label; frame } ->
             let by = if bh >= lh then line_y else line_y + lh - bh - (lh - Metrics.glyph_h) / 2 in
             let by = max line_y (min by (line_y + lh - bh)) in
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
                   let b = Buffer.create room and k = ref 0 in
                   String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr k;
                                 if !k <= room then Buffer.add_char b c) label;
                   Buffer.contents b
                 else label in
               emit o (Text { x = !cx + 4; y = by + max 0 ((bh - Metrics.glyph_h) / 2); s = shown;
                              color = 0x50585F; bold = false; italic = false })
             end
           | Ibox { node; bw; bh; ml; _ } ->
             let by = match st.vertical_align with
               | "middle" -> line_y + (lh - bh) / 2
               | "top" | "text-top" -> line_y
               | _ -> line_y + lh - bh - max 0 ((lh - Metrics.glyph_h) / 2 - 2) in
             let by = max line_y (min by (line_y + lh - bh)) in
             ignore (block o ~force_w:bw ~bfc:{ floats = [] } node { st with margin = zero_margins }
                       ~x:(!cx + ml) ~y:by ~cw:bw ~depth:(depth + 1))
           | Abs node -> register_abs o node st ~x:!cx ~y:line_y
           | Float _ | Space | Break -> ());
          (match a.kind with
           | Word _ | Space when aw > 0 ->
             if st.underline then emit o (Fill { x = !cx; y = ty + 14; w = aw; h = 1; color = st.color });
             if st.line_through then emit o (Fill { x = !cx; y = ty + 8; w = aw; h = 1; color = st.color });
             if st.overline then emit o (Fill { x = !cx; y = ty; w = aw; h = 1; color = st.color })
           | _ -> ())
        end;
        (match a.link with
         | Some href when aw > 0 -> add_link o { lx = !cx; ly = line_y; lw = aw; lh = lh; href }
         | _ -> ());
        cx := !cx + aw) line;
    y := !y + lh;
    first_line := false in
  let line = ref [] and lx = ref 0 in
  let avail () = let l, r = edges () in r - l - (if !first_line then px container.text_indent ~of_:w else 0) in
  let breakable a = a.kind = Space && a.st.white_space <> Nowrap in
  let flush () = if !line <> [] then emit_line (List.rev !line); line := []; lx := 0 in
  let rec place_all atoms =
    match atoms with
    | [] -> flush ()
    | a :: rest ->
      (match a.kind with
       | Break -> if !line = [] then emit_line [] else flush (); place_all rest
       | Space when !line = [] -> place_all rest
       | Float node ->
         (* at this line's top: the lines after it go beside it *)
         place_one_float o ~bfc node a.st ~x ~y:!y ~cw:w ~depth;
         place_all rest
       | Abs _ -> line := a :: !line; place_all rest
       | _ ->
         let aw = atom_width a in
         let av = avail () in
         if !line = [] && aw > av && av < w && bfc.floats <> [] then begin
           (* too narrow beside the floats: below the nearest one *)
           (match next_bottom bfc !y with Some b -> y := b; place_all atoms
                                        | None -> line := [ a ]; lx := aw; place_all rest)
         end else if !line <> [] && !lx + aw > av && a.kind <> Space then begin
           (* back to the last place the line may break *)
           let rec split_at acc = function
             | [] -> None
             | x :: r when breakable x -> Some (List.rev r, acc)
             | e :: r -> split_at (e :: acc) r in
           (match split_at [] !line with
            | Some (before, after) when before <> [] ->
              line := List.rev before; flush ();
              place_all (after @ (a :: rest))
            | _ ->
              (match !line with
               | last :: _ when (match last.kind with Box _ | Ibox _ -> true | _ -> false) ->
                 flush (); place_all (a :: rest)
               | _ -> line := a :: !line; lx := !lx + aw; place_all rest))
         end else if !line = [] && aw > av && (match a.kind with Word _ -> true | _ -> false) then begin
           match cut_word a av with
           | first :: (_ :: _ as more) -> line := [ first ]; lx := atom_width first; flush (); place_all (more @ rest)
           | _ -> line := [ a ]; lx := aw; place_all rest
         end else begin
           line := a :: !line; lx := !lx + aw; place_all rest
         end) in
  place_all atoms;
  !y

(* ---- flexbox ---- *)

(* the items of a flex or grid container, by order (stably) *)
and flex_items o (n : Dom.node) =
  let items = ref [] in
  let rec add (c : Dom.node) =
    match c.kind with
    | Element _ ->
      (match Style.get o.styles c with
       | Some cst when cst.display <> None_ && not cst.clipped && not (positioned cst) ->
         if cst.display = Contents then List.iter add (Dom.children c)
         else items := Item (c, cst) :: !items
       | _ -> ())
    | Text { data } when String.exists (fun ch -> not (is_ws ch)) data ->
      (match Option.bind c.parent (Style.get o.styles) with
       | Some st -> items := Txt (data, st) :: !items
       | None -> ())
    | _ -> () in
  List.iter add (Dom.children n);
  let items = List.rev !items in
  let keyed = List.mapi (fun i it -> ((match it with Item (_, s) -> s.order | Txt _ -> 0), i, it)) items in
  List.map (fun (_, _, it) -> it) (List.stable_sort (fun (a, i, _) (b, j, _) -> compare (a, i) (b, j)) keyed)

and item_intrinsic o it =
  match it with
  | Item (c, cst) ->
    let a, b = intrinsic o c cst in
    let m = hframe cst ~cw:0 ~margins:true - hframe cst ~cw:0 ~margins:false in
    (a + m, b + m)
  | Txt (data, st) ->
    let atoms = atoms_of [ P_text (data, st, None, 0) ] in
    (List.fold_left (fun m a -> max m (atom_width a)) 0 atoms,
     List.fold_left (fun s a -> s + atom_width a) 0 atoms)

and abs_children o (n : Dom.node) ~x ~y =
  List.iter (fun (c : Dom.node) -> match Style.get o.styles c with
      | Some cst when positioned cst && cst.display <> None_ && not cst.clipped -> register_abs o c cst ~x ~y
      | _ -> ()) (Dom.children n)

(* an item laid out at (ix, iy), its border box bw wide (and bh high) *)
and lay_item o it ~ix ~iy ~bw ?bh ~depth () =
  match it with
  | Item (c, cst) ->
    ignore (block o ~force_w:bw ?force_h:bh ~bfc:{ floats = [] } c { cst with margin = zero_margins }
              ~x:ix ~y:iy ~cw:bw ~depth:(depth + 1))
  | Txt (data, tst) ->
    ignore (inline_layout o ~bfc:{ floats = [] } tst (atoms_of [ P_text (data, tst, None, 0) ]) ~x:ix ~y:iy ~w:bw ~depth)

and item_height o it ~bw ~depth =
  match it with
  | Item (c, cst) -> snd (measure_forced o c { cst with margin = zero_margins } ~bw)
  | Txt (data, tst) ->
    o.dry <- o.dry + 1;
    let y' = inline_layout o ~bfc:{ floats = [] } tst (atoms_of [ P_text (data, tst, None, 0) ]) ~x:0 ~y:0 ~w:bw ~depth in
    o.dry <- o.dry - 1;
    y'

and flex o (n : Dom.node) (st : Style.t) ~x ~y ~cw ~ch ~depth =
  abs_children o n ~x ~y;
  let items = flex_items o n in
  let column = st.flex_direction = "column" || st.flex_direction = "column-reverse" in
  let reverse = st.flex_direction = "row-reverse" || st.flex_direction = "column-reverse" in
  let items = if reverse then List.rev items else items in
  let gap_main = px (if column then st.row_gap else st.column_gap) ~of_:cw in
  let gap_cross = px (if column then st.column_gap else st.row_gap) ~of_:cw in
  let style_of = function Item (_, s) -> s | Txt (_, s) -> s in
  let align it =
    let s = style_of it in
    let a = match it with Item _ when s.align_self <> "auto" -> s.align_self | _ -> st.align_items in
    if a = "normal" then "stretch" else a in
  let margin it i = match it with Item (_, s) -> s.margin.(i) | Txt _ -> Len (0., 0.) in
  if not column then begin
    (* ---- in a row ---- *)
    let info = List.map (fun it ->
        let mlp = px (margin it 3) ~of_:cw and mrp = px (margin it 1) ~of_:cw in
        let mn, mx = item_intrinsic o it in
        let mn = max 0 (mn - mlp - mrp) and mx = max 0 (mx - mlp - mrp) in
        match it with
        | Item (_, cst) ->
          let frame = hframe cst ~cw ~margins:false in
          let to_border l = let v = px l ~of_:cw in if cst.border_box then v else v + frame in
          let basis = match cst.flex_basis, cst.width with
            | Auto, Auto -> mx
            | Auto, w -> to_border w
            | b, _ -> to_border b in
          (* min-width: auto is the content's minimum, unless it scrolls *)
          let minw = match cst.min_width with
            | Len (0., 0.) -> if cst.overflow_bfc then 0 else min mn basis
            | l -> to_border l in
          let maxw = match cst.max_width with Auto -> max_int | l -> to_border l in
          (it, mlp, mrp, cst.flex_grow, cst.flex_shrink, basis, minw, maxw)
        | Txt _ -> (it, 0, 0, 0., 1., mx, mn, max_int)) items in
    let hyp (_, _, _, _, _, basis, minw, maxw) = max minw (min maxw basis) in
    let lines =
      if not st.flex_wrap then [ info ]
      else begin
        let out = ref [] and cur = ref [] and used = ref 0 in
        List.iter (fun ((_, ml, mr, _, _, _, _, _) as i) ->
            let h = hyp i + ml + mr in
            if !cur <> [] && !used + gap_main + h > cw then (out := List.rev !cur :: !out; cur := [ i ]; used := h)
            else (used := !used + (if !cur = [] then 0 else gap_main) + h; cur := i :: !cur)) info;
        if !cur <> [] then out := List.rev !cur :: !out;
        List.rev !out
      end in
    let cur_y = ref y in
    List.iteri (fun li line ->
        if li > 0 then cur_y := !cur_y + gap_cross;
        let n = List.length line in
        let gaps = gap_main * max 0 (n - 1) in
        let hyps = List.map hyp line in
        let outer = List.fold_left2 (fun s (_, ml, mr, _, _, _, _, _) h -> s + h + ml + mr) 0 line hyps in
        let free = cw - outer - gaps in
        let sizes =
          if free > 0 then
            let total = List.fold_left (fun s (_, _, _, g, _, _, _, _) -> s +. g) 0. line in
            if total > 0. then
              List.map2 (fun (_, _, _, g, _, _, _, maxw) h ->
                  min maxw (h + int_of_float (float free *. g /. total))) line hyps
            else hyps
          else if free < 0 then
            let total = List.fold_left2 (fun s (_, _, _, _, sh, _, _, _) h -> s +. sh *. float h) 0. line hyps in
            if total > 0. then
              List.map2 (fun (_, _, _, _, sh, _, minw, _) h ->
                  max minw (h + int_of_float (float free *. sh *. float h /. total))) line hyps
            else hyps
          else hyps in
        let used = List.fold_left2 (fun s (_, ml, mr, _, _, _, _, _) w -> s + w + ml + mr) 0 line sizes + gaps in
        let remaining = max 0 (cw - used) in
        (* auto margins take the free space first *)
        let autos = List.fold_left (fun k (it, _, _, _, _, _, _, _) ->
            k + (if is_auto (margin it 3) then 1 else 0) + (if is_auto (margin it 1) then 1 else 0)) 0 line in
        let start, between =
          if autos > 0 then (0, 0)
          else match st.justify with
            | "flex-end" | "end" | "right" -> (remaining, 0)
            | "center" -> (remaining / 2, 0)
            | "space-between" -> (0, if n > 1 then remaining / (n - 1) else 0)
            | "space-around" -> ((if n > 0 then remaining / (2 * n) else 0), if n > 0 then remaining / n else 0)
            | "space-evenly" -> (remaining / (n + 1), remaining / (n + 1))
            | _ -> ((if reverse then remaining else 0), 0) in
        let heights = List.map2 (fun (it, _, _, _, _, _, _, _) w -> item_height o it ~bw:w ~depth) line sizes in
        let cross = List.fold_left max 0 (List.map2 (fun (it, _, _, _, _, _, _, _) h ->
            h + px (margin it 0) ~of_:cw + px (margin it 2) ~of_:cw) line heights) in
        let cross = match ch with Some h when not st.flex_wrap -> max cross h | _ -> cross in
        let cx = ref (x + start) in
        let share = if autos > 0 then remaining / autos else 0 in
        List.iter2 (fun ((it, ml, mr, _, _, _, _, _), w) h ->
            let ml = if is_auto (margin it 3) then share else ml
            and mr = if is_auto (margin it 1) then share else mr in
            let mt = px (margin it 0) ~of_:cw and mb = px (margin it 2) ~of_:cw in
            let a = align it in
            let stretch = a = "stretch" && (match it with Item (_, s) -> is_auto s.height | Txt _ -> true) in
            let iy = match a with
              | "flex-end" | "end" | "self-end" -> !cur_y + cross - h - mb
              | "center" -> !cur_y + (cross - h - mt - mb) / 2 + mt
              | _ -> !cur_y + mt in
            let bh = if stretch then Some (max h (cross - mt - mb)) else None in
            lay_item o it ~ix:(!cx + ml) ~iy ~bw:w ?bh ~depth ();
            cx := !cx + ml + w + mr + gap_main + between) (List.combine line sizes) heights;
        cur_y := !cur_y + cross) lines;
    (match ch with Some h -> max h (!cur_y - y) | None -> !cur_y - y)
  end else begin
    (* ---- in a column ---- *)
    let placed = List.map (fun it ->
        let ml = px (margin it 3) ~of_:cw and mr = px (margin it 1) ~of_:cw in
        let a = align it in
        let bw = match it with
          | Item (c, cst) ->
            (match cst.width with
             | Auto -> if a = "stretch" then max 0 (cw - ml - mr)
               else shrink_to_fit o c cst ~avail:(max 0 (cw - ml - mr))
             | l -> let v = px l ~of_:cw in if cst.border_box then v else v + hframe cst ~cw ~margins:false)
          | Txt _ -> cw in
        let h = item_height o it ~bw ~depth in
        (it, bw, h, ml, mr, px (margin it 0) ~of_:cw, px (margin it 2) ~of_:cw, a)) items in
    let n = List.length placed in
    let total = List.fold_left (fun s (_, _, h, _, _, mt, mb, _) -> s + h + mt + mb) 0 placed + gap_main * max 0 (n - 1) in
    let free = match ch with Some h -> max 0 (h - total) | None -> 0 in
    let grow it = match it with Item (_, c) -> c.flex_grow | Txt _ -> 0. in
    let grow_total = List.fold_left (fun s (it, _, _, _, _, _, _, _) -> s +. grow it) 0. placed in
    let start = if grow_total > 0. then 0 else match st.justify with
        | "flex-end" | "end" -> free | "center" -> free / 2 | _ -> 0 in
    let cur_y = ref (y + start) in
    List.iteri (fun i (it, bw, h, ml, mr, mt, mb, a) ->
        if i > 0 then cur_y := !cur_y + gap_main;
        let extra = if grow_total > 0. then int_of_float (float free *. grow it /. grow_total) else 0 in
        let ix = match a with
          | "flex-end" | "end" | "self-end" -> x + cw - mr - bw
          | "center" -> x + (cw - bw) / 2
          | _ -> x + ml in
        let bh = h + extra in
        lay_item o it ~ix ~iy:(!cur_y + mt) ~bw ?bh:(if extra > 0 then Some bh else None) ~depth ();
        cur_y := !cur_y + mt + bh + mb) placed;
    (match ch with Some h -> max h (!cur_y - y) | None -> !cur_y - y)
  end

(* ---- grid ---- *)

and grid o (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth =
  abs_children o n ~x ~y;
  let items = List.filter_map (function Item (c, s) -> Some (c, s) | Txt _ -> None) (flex_items o n) in
  let ctx = ctx_of o st in
  let col_gap = px st.column_gap ~of_:cw and row_gap = px st.row_gap ~of_:cw in
  let open Css in
  (* the column tracks *)
  let rec track (v : cv) =
    match v with
    | Tok (Dimension (f, "fr")) -> Some (`Fr f)
    | Tok (Ident i) -> (match String.lowercase_ascii i with
        | "auto" -> Some `Auto | "min-content" -> Some `Min | "max-content" -> Some `Max | _ -> None)
    | Func ("minmax", args) ->
      (match Style.split_commas args with
       | [ a; b ] ->
         (match List.filter_map track (Css.trim a), List.filter_map track (Css.trim b) with
          | [ lo ], [ hi ] -> Some (`Minmax (lo, hi))
          | _ -> None)
       | _ -> None)
    | Func ("fit-content", args) ->
      (match Style.length ctx args with Some (Len _ as l) -> Some (`Fit (px l ~of_:cw)) | _ -> Some `Auto)
    | v -> (match Style.length ctx [ v ] with Some (Len _ as l) -> Some (`Px (px l ~of_:cw)) | _ -> None) in
  let fixed_size = function `Px p -> p | `Minmax (`Px p, _) -> p | `Fit p -> p | _ -> 0 in
  let rec tracks (vs : cv list) =
    List.concat_map (fun v ->
        match v with
        | Tok Whitespace | Css.Block ('[', _) -> []
        | Func ("repeat", args) ->
          (match Style.split_commas args with
           | count :: rest ->
             let inner = tracks (List.concat (List.mapi (fun i r -> if i > 0 then Tok Comma :: r else r) rest)) in
             let k = match Css.trim count with
               | [ Tok (Number (k, _)) ] -> int_of_float k
               | [ Tok (Ident ("auto-fill" | "auto-fit")) ] ->
                 let unit = List.fold_left (fun s t -> s + max 1 (fixed_size t)) 0 inner in
                 max 1 ((cw + col_gap) / max 1 (unit + col_gap * List.length inner))
               | _ -> 1 in
             List.concat (List.init (max 0 k) (fun _ -> inner))
           | [] -> [])
        | v -> Option.to_list (track v)) vs in
  let col_tracks = tracks st.grid_columns in
  let areas = st.grid_areas in
  let ncols = max (max 1 (List.length col_tracks)) (List.fold_left (fun m r -> max m (List.length r)) 0 areas) in
  let cols = Array.init ncols (fun i -> match List.nth_opt col_tracks i with Some t -> t | None -> `Auto) in
  (* where each item goes: row, column, spans (0-based) *)
  let area_rect name =
    let r0 = ref max_int and r1 = ref (-1) and c0 = ref max_int and c1 = ref (-1) in
    List.iteri (fun ri row -> List.iteri (fun ci a ->
        if a = name then (r0 := min !r0 ri; r1 := max !r1 ri; c0 := min !c0 ci; c1 := max !c1 ci)) row) areas;
    if !r1 < 0 then None else Some (!r0, !c0, !r1 - !r0 + 1, !c1 - !c0 + 1) in
  (* "a / b", "a / span n", "span n", "n": a start line (0-based, -1: auto) and a span *)
  let lines (v : cv list) total =
    let parts = Style.split_commas (List.map (function Tok (Delim "/") -> Tok Comma | t -> t) v) in
    let one p = match List.filter (fun t -> t <> Tok Whitespace) p with
      | [ Tok (Number (k, _)) ] -> `Line (int_of_float k)
      | [ Tok (Ident s); Tok (Number (k, _)) ] when String.lowercase_ascii s = "span" -> `Span (int_of_float k)
      | [ Tok (Number (k, _)); Tok (Ident s) ] when String.lowercase_ascii s = "span" -> `Span (int_of_float k)
      | _ -> `Auto in
    let line k = if k < 0 then total + 1 + k else k - 1 in
    match List.map one parts with
    | [ `Line a ] -> Some (line a, 1)
    | [ `Line a; `Line b ] -> let a = line a and b = line b in Some (min a b, max 1 (abs (b - a)))
    | [ `Line a; `Span s ] | [ `Line a; `Auto; `Span s ] -> Some (line a, max 1 s)
    | [ `Span s ] | [ `Span s; _ ] | [ `Auto; `Span s ] -> Some (-1, max 1 s)
    | _ -> None in
  let wanted = List.map (fun (c, cst) ->
      match (match List.filter (fun t -> t <> Tok Whitespace) cst.grid_area with
          | [ Tok (Ident name) ] -> area_rect name | _ -> None) with
      | Some r -> (c, cst, `At r)
      | None ->
        (match lines cst.grid_column ncols, lines cst.grid_row 1000 with
         | Some (c0, cs), Some (r0, rs) when c0 >= 0 && r0 >= 0 -> (c, cst, `At (r0, c0, rs, cs))
         | Some (c0, cs), _ when c0 >= 0 -> (c, cst, `Col (c0, cs))
         | Some (_, cs), _ -> (c, cst, `Span cs)
         | None, _ -> (c, cst, `Span 1))) items in
  let taken = Hashtbl.create 64 in
  let free r c rs cs =
    c >= 0 && c + cs <= ncols
    && (let ok = ref true in
        for i = r to r + rs - 1 do for j = c to c + cs - 1 do if Hashtbl.mem taken (i, j) then ok := false done done;
        !ok) in
  let take r c rs cs = for i = r to r + rs - 1 do for j = c to c + cs - 1 do Hashtbl.replace taken (i, j) () done done in
  List.iter (function (_, _, `At (r, c, rs, cs)) -> take r c rs (min cs (max 1 (ncols - c))) | _ -> ()) wanted;
  let cursor = ref (0, 0) in
  let placed = List.map (fun (c, cst, w) ->
      match w with
      | `At (r, col, rs, cs) -> (c, cst, (r, min col (ncols - 1), rs, max 1 (min cs (ncols - min col (ncols - 1)))))
      | `Col (col, cs) ->
        let col = min col (ncols - 1) in
        let cs = max 1 (min cs (ncols - col)) in
        let r = ref 0 in
        while not (free !r col 1 cs) do incr r done;
        take !r col 1 cs; (c, cst, (!r, col, 1, cs))
      | `Span cs ->
        let cs = max 1 (min cs ncols) in
        let r = ref (fst !cursor) and col = ref (snd !cursor) in
        while not (free !r !col 1 cs) do
          incr col; if !col + cs > ncols then (col := 0; incr r)
        done;
        take !r !col 1 cs;
        cursor := (!r, !col + cs);
        (c, cst, (!r, !col, 1, cs))) wanted in
  let nrows = List.fold_left (fun m (_, _, (r, _, rs, _)) -> max m (r + rs)) (List.length areas) placed in
  (* column widths *)
  let widths = Array.map fixed_size cols in
  let single = List.filter (fun (_, _, (_, _, _, cs)) -> cs = 1) placed in
  let content i f = List.fold_left (fun m (c, cst, (_, col, _, _)) ->
      if col = i then max m (f (intrinsic o c cst) + hframe cst ~cw ~margins:true - hframe cst ~cw ~margins:false)
      else m) 0 single in
  Array.iteri (fun i t ->
      match t with
      | `Auto | `Max | `Minmax (_, (`Auto | `Max)) -> widths.(i) <- max widths.(i) (content i snd)
      | `Min | `Minmax (`Min, _) -> widths.(i) <- max widths.(i) (content i fst)
      | `Fit limit -> widths.(i) <- min limit (content i snd)
      | _ -> ()) cols;
  let gaps = col_gap * (ncols - 1) in
  let flexible t = match t with `Fr _ | `Minmax (_, `Fr _) -> true | _ -> false in
  let fr_total = Array.fold_left (fun s t -> match t with `Fr f | `Minmax (_, `Fr f) -> s +. f | _ -> s) 0. cols in
  let fixed = Array.fold_left ( + ) 0 (Array.mapi (fun i t -> if flexible t then 0 else widths.(i)) cols) in
  let leftover = cw - gaps - fixed in
  if fr_total > 0. then
    Array.iteri (fun i t -> match t with
        | `Fr f | `Minmax (_, `Fr f) -> widths.(i) <- max widths.(i) (int_of_float (float (max 0 leftover) *. f /. fr_total))
        | _ -> ()) cols
  else if leftover > 0 then begin
    let autos = Array.fold_left (fun k t -> if t = `Auto then k + 1 else k) 0 cols in
    if autos > 0 then Array.iteri (fun i t -> if t = `Auto then widths.(i) <- widths.(i) + leftover / autos) cols
  end else if leftover < 0 then
    Array.iteri (fun i t -> if t = `Auto then
                    widths.(i) <- max (content i fst) (widths.(i) + leftover / ncols)) cols;
  let col_x = Array.make (ncols + 1) 0 in
  for i = 1 to ncols do col_x.(i) <- col_x.(i - 1) + widths.(i - 1) + col_gap done;
  let span_w col cs = col_x.(col + cs) - col_x.(col) - col_gap in
  (* row heights: the items' heights at their widths *)
  let nr = max 1 nrows in
  let heights = Array.make nr 0 in
  let measured = List.map (fun (c, cst, (r, col, rs, cs)) ->
      let w = span_w col cs in
      let ml = px cst.margin.(3) ~of_:cw and mr = px cst.margin.(1) ~of_:cw in
      let mt = px cst.margin.(0) ~of_:cw and mb = px cst.margin.(2) ~of_:cw in
      let bw = max 0 (w - ml - mr) in
      let _, h = measure_forced o c { cst with margin = zero_margins } ~bw in
      let oh = h + mt + mb in
      if rs = 1 then heights.(r) <- max heights.(r) oh;
      (c, cst, (r, col, rs, cs), bw, h, ml, mt, mb)) placed in
  List.iter (fun (_, _, (r, _, rs, _), _, h, _, mt, mb) ->
      if rs > 1 then begin
        let last = min (nr - 1) (r + rs - 1) in
        let have = ref (row_gap * (last - r)) in
        for i = r to last do have := !have + heights.(i) done;
        if h + mt + mb > !have then heights.(last) <- heights.(last) + h + mt + mb - !have
      end) measured;
  (* empty rows take no gap *)
  let row_y = Array.make (nr + 1) 0 in
  for i = 1 to nr do
    row_y.(i) <- row_y.(i - 1) + heights.(i - 1) + (if heights.(i - 1) > 0 then row_gap else 0)
  done;
  List.iter (fun (c, cst, (r, col, rs, _), bw, h, ml, mt, mb) ->
      let last = min nr (r + rs) in
      let rh = row_y.(last) - row_y.(r) - (if heights.(last - 1) > 0 then row_gap else 0) in
      let a = if cst.align_self <> "auto" then cst.align_self else st.align_items in
      let stretch = (a = "normal" || a = "stretch") && is_auto cst.height in
      let bh = if stretch then Some (max h (rh - mt - mb)) else None in
      let iy = y + row_y.(r) + mt in
      let iy = match a with "center" -> iy + (rh - h - mt - mb) / 2 | "end" | "flex-end" -> iy + rh - h - mt - mb | _ -> iy in
      lay_item o (Item (c, cst)) ~ix:(x + col_x.(col) + ml) ~iy ~bw ?bh ~depth ()) measured;
  max 0 (row_y.(nr) - (if heights.(nr - 1) > 0 then row_gap else 0))

(* ---- tables ---- *)

and table_spacing (st : Style.t) = if st.border_collapse then 0 else int_of_float st.border_spacing

(* the table's cells: (cell, style, row, column, colspan, rowspan), its row
   elements (thead's first, tfoot's last), the columns, the captions *)
and table_grid o (n : Dom.node) =
  let captions = ref [] in
  let heads = ref [] and bodies = ref [] and feet = ref [] in
  let span c a = max 1 (min 1000 (Option.value (Option.bind (Dom.attr c a) (fun v -> int_of_string_opt (String.trim v))) ~default:1)) in
  let cells_of (tr : Dom.node) =
    List.filter_map (fun (c : Dom.node) ->
        match c.kind, Style.get o.styles c with
        | Element _, Some cst when cst.display <> None_ && not (positioned cst) ->
          Some (c, cst, span c "colspan", span c "rowspan")
        | _ -> None) (Dom.children tr) in
  let add_rows target (g : Dom.node) =
    List.iter (fun (r : Dom.node) -> match r.kind, Style.get o.styles r with
        | Element _, Some rst when rst.display <> None_ -> target := (Some (r, rst), cells_of r) :: !target
        | _ -> ()) (Dom.children g) in
  let loose = ref [] in
  let flush_loose () = if !loose <> [] then (bodies := (None, List.rev !loose) :: !bodies; loose := []) in
  List.iter (fun (c : Dom.node) ->
      match c.kind, Style.get o.styles c with
      | Element _, Some cst when cst.display <> None_ && not (positioned cst) ->
        (match cst.display with
         | Table_caption -> flush_loose (); captions := (c, cst) :: !captions
         | Table_group ->
           flush_loose ();
           if Dom.is_html c "thead" then add_rows heads c
           else if Dom.is_html c "tfoot" then add_rows feet c
           else add_rows bodies c
         | Table_row -> flush_loose (); bodies := (Some (c, cst), cells_of c) :: !bodies
         | Table_column -> ()
         | _ -> loose := (c, cst, span c "colspan", span c "rowspan") :: !loose)
      | _ -> ()) (Dom.children n);
  flush_loose ();
  let rows = List.rev !heads @ List.rev !bodies @ List.rev !feet in
  let taken = Hashtbl.create 64 in
  let placed = ref [] and ncols = ref 0 in
  List.iteri (fun ri (_, cells) ->
      let col = ref 0 in
      List.iter (fun (c, cst, cs, rs) ->
          while Hashtbl.mem taken (ri, !col) do incr col done;
          for i = ri to ri + rs - 1 do for j = !col to !col + cs - 1 do Hashtbl.replace taken (i, j) () done done;
          placed := (c, cst, ri, !col, cs, rs) :: !placed;
          col := !col + cs;
          ncols := max !ncols !col) cells) rows;
  (List.rev !placed, Array.of_list (List.map fst rows), !ncols, List.rev !captions)

(* the columns' minimum and maximum widths *)
and table_columns o (cells, _, ncols, _) ~avail =
  let mins = Array.make (max 1 ncols) 0 and maxs = Array.make (max 1 ncols) 0 in
  let sizes = List.map (fun (c, cst, _, col, cs, _) ->
      let mn, mx = intrinsic o c cst in
      let given = match cst.width, avail with
        | Len (p, 0.), _ -> Some (int_of_float p + (if cst.border_box then 0 else hframe cst ~cw:0 ~margins:false))
        | Len (0., pct), Some a -> Some (int_of_float (pct *. float a /. 100.))
        | _ -> None in
      let mx = match given with Some g -> max mn g | None -> mx in
      (col, cs, mn, mx)) cells in
  List.iter (fun (col, cs, mn, mx) ->
      if cs = 1 && col < ncols then (mins.(col) <- max mins.(col) mn; maxs.(col) <- max maxs.(col) mx)) sizes;
  List.iter (fun (col, cs, mn, mx) ->
      if cs > 1 then begin
        let span = List.filter (fun k -> k < ncols) (List.init cs (fun k -> col + k)) in
        let have_min = List.fold_left (fun s k -> s + mins.(k)) 0 span in
        let have_max = List.fold_left (fun s k -> s + maxs.(k)) 0 span in
        let k = List.length span in
        if k > 0 && mn > have_min then List.iter (fun j -> mins.(j) <- mins.(j) + (mn - have_min) / k) span;
        if k > 0 && mx > have_max then List.iter (fun j -> maxs.(j) <- maxs.(j) + (mx - have_max) / k) span
      end) sizes;
  Array.iteri (fun i m -> if maxs.(i) < m then maxs.(i) <- m) mins;
  (mins, maxs)

and table o (n : Dom.node) (st : Style.t) ~x ~y ~cw ~depth =
  let ((cells, row_nodes, ncols, captions) as t) = table_grid o n in
  let sp = table_spacing st in
  let cur_y = ref y in
  List.iter (fun (c, cst) ->
      let r = block o ~bfc:{ floats = [] } c cst ~x ~y:!cur_y ~cw ~depth:(depth + 1) in
      cur_y := !cur_y + r.mt + r.h + r.mb) captions;
  if ncols = 0 then !cur_y - y
  else begin
    let mins, maxs = table_columns o t ~avail:(Some cw) in
    let avail = cw - sp * (ncols + 1) in
    let sum a = Array.fold_left ( + ) 0 a in
    let widths =
      if sum maxs <= avail then
        (* a table wider than its content: the rest to the columns, in proportion *)
        let extra = avail - sum maxs and total = max 1 (sum maxs) in
        Array.map (fun m -> m + extra * m / total) maxs
      else if sum mins >= avail then mins
      else
        let f = float (avail - sum mins) /. float (max 1 (sum maxs - sum mins)) in
        Array.mapi (fun i mn -> mn + int_of_float (f *. float (maxs.(i) - mn))) mins in
    let col_x = Array.make (ncols + 1) (x + sp) in
    for i = 1 to ncols do col_x.(i) <- col_x.(i - 1) + widths.(i - 1) + sp done;
    let span_w col cs = col_x.(min ncols (col + cs)) - col_x.(col) - sp in
    let nrows = max 1 (Array.length row_nodes) in
    let heights = Array.make nrows 0 in
    let measured = List.map (fun (c, cst, r, col, cs, rs) ->
        let w = span_w col cs in
        let _, h = measure_forced o c cst ~bw:w in
        if rs = 1 && r < nrows then heights.(r) <- max heights.(r) h;
        (c, cst, r, col, rs, w, h)) cells in
    List.iter (fun (_, _, r, _, rs, _, h) ->
        if rs > 1 && r < nrows then begin
          let last = min (nrows - 1) (r + rs - 1) in
          let have = ref (sp * (last - r)) in
          for i = r to last do have := !have + heights.(i) done;
          if h > !have then heights.(last) <- heights.(last) + h - !have
        end) measured;
    let row_y = Array.make (nrows + 1) (!cur_y + sp) in
    for i = 1 to nrows do row_y.(i) <- row_y.(i - 1) + heights.(i - 1) + sp done;
    (* the rows' backgrounds, under the cells *)
    Array.iteri (fun i r -> match r with
        | Some (_, (rst : Style.t)) when visible_color rst.background && rst.visible && not rst.transparent ->
          emit o (Fill { x = x + sp; y = row_y.(i); w = col_x.(ncols) - x - 2 * sp; h = heights.(i);
                         color = rgb rst.background })
        | _ -> ()) row_nodes;
    List.iter (fun (c, cst, r, col, rs, w, h) ->
        if r < nrows then begin
          let last = min nrows (r + rs) in
          let rh = row_y.(last) - row_y.(r) - sp in
          let valign = match cst.vertical_align with
            | "middle" -> max 0 ((rh - h) / 2)
            | "bottom" -> max 0 (rh - h)
            | _ -> 0 in
          ignore (block o ~force_w:w ~force_h:rh ~valign ~bfc:{ floats = [] } c cst ~x:col_x.(col) ~y:row_y.(r)
                    ~cw:w ~depth:(depth + 1))
        end) measured;
    row_y.(nrows) - y
  end

(* ---- the page ---- *)

let layout ~width ~height (styles : Style.styles) (doc : Dom.node) =
  let o = { items_ = Dynarray.create (); links_ = Dynarray.create (); anchors_ = []; styles;
            vw = width; vh = height; dry = 0; clip = None; measures = Hashtbl.create 1024;
            intrinsics = Hashtbl.create 1024; abs = [ ref [] ] } in
  let root = Dom.find (fun n -> Dom.is_html n "html") doc in
  let total =
    match root with
    | Some html ->
      (match Style.get styles html with
       | Some st when st.display <> None_ ->
         let m0 = mark o in
         let r = block o ~bfc:{ floats = [] } html st ~x:0 ~y:0 ~cw:width ~depth:0 in
         (* the margins that collapsed out through the root: from the canvas's top *)
         translate o m0 0 (max 0 r.mt);
         max 0 r.mt + r.h + max 0 r.mb
       | _ -> 0)
    | None -> 0 in
  (* the initial containing block's absolutely positioned boxes *)
  (match o.abs with
   | l :: _ -> List.iter (layout_abs o (0, 0, width, max height total) ~depth:1) (List.rev !l)
   | [] -> ());
  let bg_of n = match Option.bind n (Style.get styles) with
    | Some st when visible_color st.background -> Some (rgb st.background) | _ -> None in
  let background =
    match bg_of root with
    | Some c -> c
    | None -> (match bg_of (Dom.find (fun n -> Dom.is_html n "body") doc) with Some c -> c | None -> 0xFFFFFF) in
  (* positioned boxes may reach below the flow *)
  let bottom = Dynarray.fold_left (fun m it -> match it with
      | Fill f -> max m (f.y + f.h) | Text t -> max m (t.y + Metrics.glyph_h)) total o.items_ in
  { items = Dynarray.to_array o.items_; links = Dynarray.to_array o.links_; height = max total bottom; background;
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
