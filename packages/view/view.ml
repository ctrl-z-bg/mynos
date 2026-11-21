(* view: an image viewer, for PNG, BMP and Netpbm's formats (PPM, PGM,
   PBM: the screen dumps and MyNOS's own pictures).

     view [FILE]       FILE, or a file picker

   The image fits the window; + and - zoom, 1 shows it at its own size,
   the arrows (or the mouse, dragged) move it when it is larger; Page Up
   and Page Down (or N and P) go to the next or previous image of its
   folder; O opens another, Q quits. *)

let width = 800 and height = 600
let bar = 34

type state = {
  mutable path : string option;
  mutable img : Image.t option;
  mutable error : string;
  mutable zoom : float;                     (* 0.: fit *)
  mutable ox : int;                         (* the view's top left, in the image *)
  mutable oy : int;
  mutable drag_from : (int * int * int * int) option;
  mutable picker_asked : bool;
  mutable cache : (Gfx.t * (Image.t * float * int * int)) option;
    (* the view, scaled: made again only when the image, the scale or
       the place change (a loop over pixels in OCaml is slow) *)
}

let images_of dir =
  Gui.entries dir
  |> List.filter (fun e ->
      not e.Gui.is_dir
      && List.exists (Filename.check_suffix (String.lowercase_ascii e.Gui.name))
        [ ".png"; ".ppm"; ".pgm"; ".pbm"; ".pnm"; ".bmp" ])
  |> List.map (fun e -> Gui.join dir e.Gui.name)

let load st path =
  st.path <- Some path; st.zoom <- 0.; st.ox <- 0; st.oy <- 0;
  match Pnm.read_any (In_channel.with_open_bin path In_channel.input_all) with
  | img -> st.img <- Some img; st.error <- ""
  | exception Image.Bad m -> st.img <- None; st.error <- Filename.basename path ^ ": " ^ m
  | exception Sys_error m -> st.img <- None; st.error <- m

let scale_of st (img : Image.t) =
  if st.zoom > 0. then st.zoom
  else min 1. (min (float width /. float img.width) (float (height - bar) /. float img.height))

(* the image, scaled, into the window: each pixel of the window takes
   the image's pixel under it *)
let draw ui st (img : Image.t) =
  let g = ui.Gui.g in
  let s = scale_of st img in
  let vw = min width (int_of_float (float img.width *. s))
  and vh = min (height - bar) (int_of_float (float img.height *. s)) in
  let x0 = (width - vw) / 2 and y0 = bar + (height - bar - vh) / 2 in
  let maxox = max 0 (int_of_float (float img.width *. s) - vw)
  and maxoy = max 0 (int_of_float (float img.height *. s) - vh) in
  st.ox <- max 0 (min st.ox maxox); st.oy <- max 0 (min st.oy maxoy);
  let key = (img, s, st.ox, st.oy) in
  let view = match st.cache with
    | Some (v, (i, s', ox, oy)) when i == img && s' = s && ox = st.ox && oy = st.oy -> v
    | _ ->
      let v = Gfx.create (max 1 vw) (max 1 vh) in
      let px = v.Gfx.pixels in
      let xs = Array.init vw (fun x -> min (img.width - 1) (int_of_float (float (x + st.ox) /. s))) in
      for y = 0 to vh - 1 do
        let iy = min (img.height - 1) (int_of_float (float (y + st.oy) /. s)) in
        let row = iy * img.width and o = y * vw in
        for x = 0 to vw - 1 do
          Bigarray.Array1.unsafe_set px (o + x) (Int32.of_int (img.pixels.(row + Array.unsafe_get xs x)))
        done
      done;
      st.cache <- Some (v, key);
      v in
  Gfx.blit view 0 0 g x0 y0 vw vh;
  s

let () =
  let st = { path = None; img = None; error = ""; zoom = 0.; ox = 0; oy = 0; drag_from = None;
             picker_asked = false; cache = None } in
  (match List.tl (Array.to_list Sys.argv) with
   | f :: _ -> load st f
   | [] -> ());
  Gui.run ~title:"View" width height st (fun ui st ->
      let g = ui.Gui.g in
      Gfx.fill g 0 bar width (height - bar) 0x2B2F33;
      let open_picker () =
        Gui.open_file_picker ~title:"An image"
          ?dir:(match st.path with Some p -> Some p | None -> Some "/disk")
          ~filter:(fun n -> List.exists (Filename.check_suffix (String.lowercase_ascii n))
                      [ ".png"; ".ppm"; ".pgm"; ".pbm"; ".pnm"; ".bmp" ]) 1 in
      if st.path = None && not st.picker_asked then begin st.picker_asked <- true; open_picker () end;
      let scale = match st.img with Some img -> draw ui st img | None -> 1. in
      (* the bar *)
      Gfx.fill g 0 0 width bar Gui.panel_colour;
      if Gui.button ui 6 4 70 "Open" then open_picker ();
      let neighbour d =
        match st.path with
        | Some p ->
          let all = images_of (Filename.dirname p) in
          let n = List.length all in
          (match List.find_index (( = ) p) all with
           | Some i when n > 1 -> load st (List.nth all ((i + d + n) mod n))
           | _ -> ())
        | None -> () in
      if Gui.button ui 82 4 40 "<" then neighbour (-1);
      if Gui.button ui 126 4 40 ">" then neighbour 1;
      if Gui.button ui 172 4 40 "-" then st.zoom <- max 0.05 (scale /. 1.5);
      if Gui.button ui 216 4 40 "+" then st.zoom <- min 16. (scale *. 1.5);
      if Gui.button ui 260 4 54 "Fit" then begin st.zoom <- 0.; st.ox <- 0; st.oy <- 0 end;
      if Gui.button ui 318 4 54 "1:1" then st.zoom <- 1.;
      let info = match st.img, st.path with
        | Some img, Some p ->
          Printf.sprintf "%s  %dx%d  %d%%" (Filename.basename p) img.Image.width img.Image.height
            (int_of_float (scale *. 100. +. 0.5))
        | _ -> st.error in
      ignore (Gfx.text ~max:((width - 386) / Gfx.char_w) g 382 9 info
                (if st.img = None then 0xC62828 else Gui.foreground));
      (* dragging moves a large image *)
      if ui.Gui.buttons land 1 <> 0 && Gui.hovered ui 0 bar width (height - bar) then begin
        match st.drag_from with
        | None -> st.drag_from <- Some (ui.Gui.mx, ui.Gui.my, st.ox, st.oy)
        | Some (mx, my, ox, oy) -> st.ox <- ox - (ui.Gui.mx - mx); st.oy <- oy - (ui.Gui.my - my)
      end else st.drag_from <- None;
      List.iter (function
          | "q" | "Q" -> raise Gui.Quit
          | "o" | "O" -> open_picker ()
          | "+" | "=" -> st.zoom <- min 16. (scale *. 1.5)
          | "-" -> st.zoom <- max 0.05 (scale /. 1.5)
          | "1" -> st.zoom <- 1.
          | "0" | "f" -> st.zoom <- 0.; st.ox <- 0; st.oy <- 0
          | "\027[D" -> st.ox <- st.ox - 64 | "\027[C" -> st.ox <- st.ox + 64
          | "\027[A" -> st.oy <- st.oy - 64 | "\027[B" -> st.oy <- st.oy + 64
          | "\027[6~" | "n" | " " -> neighbour 1
          | "\027[5~" | "p" -> neighbour (-1)
          | _ -> ()) ui.Gui.keys;
      if ui.Gui.wheel <> 0 then st.oy <- st.oy + 48 * ui.Gui.wheel;
      (match Gui.file_picker ui 1 with
       | Some (Gui.Picked p) -> load st p
       | Some Gui.Cancelled | None -> ());
      st)
