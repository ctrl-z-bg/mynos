(* paint: drawing with the mouse. Tools: pencil, brush, line, rectangle,
   filled rectangle, ellipse, fill, eraser, and a picker of colours from
   the picture; sixteen colours, three sizes. Pictures are saved as PNG
   (readable anywhere) and opened from PNG, BMP, PPM or PGM.

     paint [FILE]

   Keys: Ctrl-Z (or U) undoes, P B L R F E K pick a tool, [ and ] the
   size, Q quits. *)

let width = 820 and height = 600
let side = 84                                  (* the tools, on the left *)
let bar = 36                                   (* the file bar, on top *)
let cw = width - side - 12 and ch = height - bar - 12
let cx = side + 6 and cy = bar + 6             (* the canvas, in the window *)

type tool = Pencil | Brush | Line | Rect | Filled | Ellipse | Fill | Eraser | Picker

let tools = [ Pencil, "Pencil", "p"; Brush, "Brush", "b"; Line, "Line", "l"; Rect, "Box", "r";
              Filled, "Block", "x"; Ellipse, "Oval", "o"; Fill, "Fill", "f";
              Eraser, "Eraser", "e"; Picker, "Pick", "k" ]

let palette = [| 0x000000; 0x555555; 0xAAAAAA; 0xFFFFFF; 0x8B0000; 0xE53935; 0xFF9800; 0xFFEB3B;
                 0x2E7D32; 0x8BC34A; 0x00838F; 0x29B6F6; 0x1A237E; 0x3F51B5; 0x6A1B9A; 0xEC407A |]

type state = {
  mutable canvas : Gfx.t;                      (* drawn in C, shown with Gfx.blit *)
  mutable tool : tool;
  mutable colour : int;
  mutable size : int;                          (* 1, 3, 8 *)
  mutable undo : Gfx.t list;
  mutable start : (int * int) option;          (* a shape's first corner *)
  mutable last : (int * int) option;           (* the pencil's last point *)
  mutable file : string;
  mutable message : string;
}

(* the drawing primitives draw on [g] with the canvas's (0, 0) at
   ([ox], [oy]): on the canvas, or on the window for a shape still being
   drawn, within the canvas's clip *)
let dot g ox oy x y size v =
  let r = size / 2 in
  if size < 3 then Gfx.fill g (ox + x - r) (oy + y - r) size size v
  else
    for dy = -r to size - 1 - r do
      let half = int_of_float (Float.sqrt (float (r * r + r - dy * dy))) in
      Gfx.fill g (ox + x - half) (oy + y + dy) (2 * half + 1) 1 v
    done

let line g ox oy x0 y0 x1 y1 size v =
  let dx = abs (x1 - x0) and dy = - abs (y1 - y0) in
  let sx = if x0 < x1 then 1 else -1 and sy = if y0 < y1 then 1 else -1 in
  let rec go x y err =
    dot g ox oy x y size v;
    if x <> x1 || y <> y1 then begin
      let e2 = 2 * err in
      let x, err = if e2 >= dy then x + sx, err + dy else x, err in
      let y, err = if e2 <= dx then y + sy, err + dx else y, err in
      go x y err
    end in
  go x0 y0 (dx + dy)

let shape g ox oy tool x0 y0 x1 y1 size v =
  let xa = min x0 x1 and xb = max x0 x1 and ya = min y0 y1 and yb = max y0 y1 in
  match tool with
  | Line -> line g ox oy x0 y0 x1 y1 size v
  | Rect ->
    line g ox oy xa ya xb ya size v; line g ox oy xb ya xb yb size v;
    line g ox oy xb yb xa yb size v; line g ox oy xa yb xa ya size v
  | Filled -> Gfx.fill g (ox + xa) (oy + ya) (xb - xa + 1) (yb - ya + 1) v
  | Ellipse ->
    let mx = float (x0 + x1) /. 2. and my = float (y0 + y1) /. 2. in
    let rx = float (xb - xa) /. 2. and ry = float (yb - ya) /. 2. in
    let steps = max 16 (int_of_float ((rx +. ry) *. 1.5)) in
    let pt i =
      let a = 2. *. Float.pi *. float i /. float steps in
      (int_of_float (mx +. rx *. cos a), int_of_float (my +. ry *. sin a)) in
    for i = 0 to steps - 1 do
      let (xa, ya) = pt i and (xb, yb) = pt (i + 1) in line g ox oy xa ya xb yb size v
    done
  | _ -> ()

let get (c : Gfx.t) x y = Int32.to_int (Bigarray.Array1.unsafe_get c.pixels (y * c.width + x)) land 0xFFFFFF

(* the area of one colour around (x, y), filled: a row at a time *)
let flood (c : Gfx.t) x y v =
  let target = get c x y in
  if target <> v then begin
    let stack = ref [ (x, y) ] in
    while !stack <> [] do
      let (x, y) = List.hd !stack in
      stack := List.tl !stack;
      if get c x y = target then begin
        let l = ref x and r = ref x in
        while !l > 0 && get c (!l - 1) y = target do decr l done;
        while !r < c.width - 1 && get c (!r + 1) y = target do incr r done;
        Gfx.fill c !l y (!r - !l + 1) 1 v;
        let seed yy =
          (* one seed for each run of the target colour *)
          let inside = ref false in
          for i = !l to !r do
            let t = get c i yy = target in
            if t && not !inside then stack := (i, yy) :: !stack;
            inside := t
          done in
        if y > 0 then seed (y - 1);
        if y < c.height - 1 then seed (y + 1)
      end
    done
  end

let copy (c : Gfx.t) =
  let d = Gfx.create c.width c.height in
  Gfx.blit c 0 0 d 0 0 c.width c.height; d

let remember st = st.undo <- copy st.canvas :: List.filteri (fun i _ -> i < 15) st.undo

let undo st =
  match st.undo with
  | c :: rest -> st.canvas <- c; st.undo <- rest
  | [] -> ()

let to_image (c : Gfx.t) =
  { Image.width = c.width; height = c.height;
    pixels = Array.init (c.width * c.height) (fun i ->
        Int32.to_int (Bigarray.Array1.unsafe_get c.pixels i) land 0xFFFFFF) }

let save st =
  let f = if Filename.check_suffix (String.lowercase_ascii st.file) ".png" then st.file
    else Filename.remove_extension st.file ^ ".png" in
  match Out_channel.with_open_bin f (fun oc -> output_string oc (Png.write (to_image st.canvas))) with
  | () -> st.file <- f; st.message <- "saved: " ^ f
  | exception Sys_error m -> st.message <- m

let load st f =
  match Pnm.read_any (In_channel.with_open_bin f In_channel.input_all) with
  | img ->
    (* into the canvas's size: cut, or on white *)
    let c = Gfx.create cw ch in
    Gfx.fill c 0 0 cw ch 0xFFFFFF;
    for y = 0 to min ch img.height - 1 do
      for x = 0 to min cw img.width - 1 do
        Bigarray.Array1.unsafe_set c.pixels (y * cw + x) (Int32.of_int img.pixels.(y * img.width + x))
      done
    done;
    remember st; st.canvas <- c; st.file <- f; st.message <- "opened: " ^ f
  | exception (Image.Bad m | Sys_error m) -> st.message <- Filename.basename f ^ ": " ^ m

let () =
  let canvas = Gfx.create cw ch in
  Gfx.fill canvas 0 0 cw ch 0xFFFFFF;
  let st = { canvas; tool = Pencil; colour = 0; size = 3; undo = []; start = None; last = None;
             file = "/disk/picture.png"; message = "" } in
  (match List.tl (Array.to_list Sys.argv) with f :: _ -> load st f; st.undo <- [] | [] -> ());
  Gui.run ~title:"Paint" width height st (fun ui st ->
      let g = ui.Gui.g in
      Gfx.fill g 0 0 width height 0xDDE3E8;
      (* the pointer on the canvas, in the canvas's pixels *)
      let px = ui.Gui.mx - cx and py = ui.Gui.my - cy in
      let on = Gui.hovered ui cx cy cw ch in
      let down = ui.Gui.buttons land 1 <> 0 in
      let clamp v hi = max 0 (min (hi - 1) v) in
      (match st.tool with
       | (Line | Rect | Filled | Ellipse) ->
         (match st.start with
          | Some (x0, y0) when not down ->
            remember st;
            shape st.canvas 0 0 st.tool x0 y0 (clamp px cw) (clamp py ch) st.size st.colour;
            st.start <- None
          | None when down && on -> st.start <- Some (px, py)
          | _ -> ())
       | (Pencil | Brush | Eraser) when down && on ->
         let v = if st.tool = Eraser then 0xFFFFFF else st.colour in
         let size = match st.tool with Pencil -> 1 | Brush -> st.size | _ -> st.size * 3 in
         (match st.last with
          | None -> remember st; dot st.canvas 0 0 px py size v
          | Some (lx, ly) -> line st.canvas 0 0 lx ly px py size v);
         st.last <- Some (px, py)
       | Fill when ui.Gui.clicked && on -> remember st; flood st.canvas px py st.colour
       | Picker when ui.Gui.clicked && on -> st.colour <- get st.canvas px py; st.tool <- Pencil
       | _ -> ());
      if not down then st.last <- None;
      Gfx.blit st.canvas 0 0 g cx cy cw ch;
      (* a shape being drawn: on the window only *)
      (match st.start with
       | Some (x0, y0) ->
         Gfx.with_clip cx cy cw ch (fun () ->
             shape g cx cy st.tool x0 y0 (clamp px cw) (clamp py ch) st.size st.colour)
       | None -> ());
      Gfx.rect g (cx - 1) (cy - 1) (cw + 2) (ch + 2) 0x90A4AE;
      (* the tools *)
      Gfx.fill g 0 bar side (height - bar) 0xCFD8DC;
      List.iteri (fun i (t, label, _) ->
          let y = bar + 6 + i * 30 in
          if Gui.button ~h:26 ui 6 y (side - 12) label then st.tool <- t;
          if st.tool = t then begin
            Gfx.rect g 4 (y - 2) (side - 8) 30 0x0D2E55; Gfx.rect g 5 (y - 1) (side - 10) 28 0xFFD54F
          end) tools;
      let y = bar + 6 + List.length tools * 30 + 6 in
      List.iteri (fun i s ->
          let x = 6 + i * 25 in
          if Gui.button ~h:22 ui x y 22 "" then st.size <- s;
          Gfx.fill g (x + 11 - s / 2) (y + 11 - s / 2) s s 0xFFFFFF;
          if st.size = s then Gfx.rect g (x - 1) (y - 1) 24 24 0xFFD54F) [ 1; 3; 8 ];
      let y = y + 32 in
      Array.iteri (fun i c ->
          let x = 6 + i mod 4 * 18 and yy = y + i / 4 * 18 in
          Gfx.fill g x yy 16 16 c; Gfx.rect g x yy 16 16 0x607D8B;
          if ui.Gui.clicked && Gui.hovered ui x yy 16 16 then st.colour <- c) palette;
      let y = y + 4 * 18 + 8 in
      Gfx.fill g 6 y 70 26 st.colour; Gfx.rect g 6 y 70 26 0x37474F;
      (* the file bar *)
      Gfx.fill g 0 0 width bar Gui.panel_colour;
      if Gui.button ui 6 5 60 "New" then begin
        remember st; st.canvas <- Gfx.create cw ch; Gfx.fill st.canvas 0 0 cw ch 0xFFFFFF;
        st.file <- "/disk/picture.png"; st.message <- ""
      end;
      if Gui.button ui 70 5 60 "Open" then
        Gui.open_file_picker ~title:"A picture" ~dir:"/disk"
          ~filter:(fun n -> List.exists (Filename.check_suffix (String.lowercase_ascii n))
                      [ ".png"; ".ppm"; ".pgm"; ".bmp" ]) 1;
      if Gui.button ui 134 5 60 "Save" then save st;
      if Gui.button ui 198 5 60 "Undo" then undo st;
      st.file <- Gui.text_field ui 1 266 6 300 st.file;
      ignore (Gfx.text ~max:((width - 580) / Gfx.char_w) g 576 10 st.message Gui.muted);
      if ui.Gui.field <> 1 then
        List.iter (fun k ->
            match List.find_opt (fun (_, _, key) -> key = k) tools with
            | Some (t, _, _) -> st.tool <- t
            | None ->
              match k with
              | "q" | "Q" -> raise Gui.Quit
              | "\026" | "u" | "U" -> undo st
              | "[" -> st.size <- (match st.size with 8 -> 3 | _ -> 1)
              | "]" -> st.size <- (match st.size with 1 -> 3 | _ -> 8)
              | _ -> ()) ui.Gui.keys;
      (match Gui.file_picker ui 1 with
       | Some (Gui.Picked f) -> load st f
       | Some Gui.Cancelled | None -> ());
      st)
