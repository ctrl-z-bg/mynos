(* OCaml's Graphics on MyNOS (mynos-0rn): the interface of the graphics
   package, on Display and Gfx (see graphics.mli).

   Everything is drawn in a buffer of our own, [back] (X11's backing
   store, "remember mode"); what changed is copied to the window's pixels
   and shown ("display mode") in batches: the rectangle that holds all the
   changes since the last time, at most every 20 ms while drawing, and
   whenever the program reads the mouse or the keys. With remember mode
   off, drawing goes to the window's pixels directly. Gfx's coordinates
   have y downwards: [gy] turns Graphics' into them. *)

exception Graphic_failure of string

type color = int

let rgb r g b = (r lsl 16) lor (g lsl 8) lor b
let black = 0x000000 and white = 0xFFFFFF and red = 0xFF0000
and green = 0x00FF00 and blue = 0x0000FF and yellow = 0xFFFF00
and cyan = 0x00FFFF and magenta = 0xFF00FF
let background = white and foreground = black
let transp = -1

type state = {
  mutable win : Display.window;
  mutable back : Gfx.t;
  mutable w : int;
  mutable h : int;
  mutable color : color;
  mutable cx : int;
  mutable cy : int;
  mutable lw : int;
  (* the changes not shown yet: a rectangle in Gfx's coordinates *)
  mutable dirty : bool;
  mutable x0 : int; mutable y0 : int; mutable x1 : int; mutable y1 : int;
  mutable shown : float;               (* when they were last shown *)
  (* the input: the mouse in Graphics' coordinates, keys typed *)
  mutable mx : int;
  mutable my : int;
  mutable buttons : int;
  keys : char Queue.t;
}

let state : state option ref = ref None
let display = ref true
let remember = ref true

let get () =
  match !state with
  | Some s -> s
  | None -> raise (Graphic_failure "graphic screen not opened")

let gy s y = s.h - 1 - y

(* ---- showing what was drawn ---- *)

let show s =
  if s.dirty then begin
    s.dirty <- false;
    let x = max 0 s.x0 and y = max 0 s.y0 in
    let w = min s.w s.x1 - x and h = min s.h s.y1 - y in
    if w > 0 && h > 0 then begin
      if !remember then Gfx.blit s.back x y s.win.Display.pixels x y w h;
      Display.damage ~x ~y ~w ~h s.win
    end
  end;
  s.shown <- Mynos.uptime ()

(* [draw x0 y0 x1 y1 f]: [f] draws in the buffer of the moment, within
   that rectangle (Gfx's coordinates, x1 and y1 excluded) *)
let draw s x0 y0 x1 y1 f =
  if !remember then f s.back
  else if !display then f s.win.Display.pixels;
  if !display then begin
    if s.dirty then begin
      s.x0 <- min s.x0 x0; s.y0 <- min s.y0 y0;
      s.x1 <- max s.x1 x1; s.y1 <- max s.y1 y1
    end else begin
      s.dirty <- true; s.x0 <- x0; s.y0 <- y0; s.x1 <- x1; s.y1 <- y1
    end;
    if Mynos.uptime () -. s.shown > 0.02 then show s
  end

let draw_all s f = draw s 0 0 s.w s.h f

let synchronize () =
  let s = get () in
  if !remember then Gfx.blit s.back 0 0 s.win.Display.pixels 0 0 s.w s.h;
  s.dirty <- false;
  Display.damage s.win;
  s.shown <- Mynos.uptime ()

let display_mode b = display := b
let remember_mode b = remember := b
let auto_synchronize b =
  display := b;
  if b && !state <> None then synchronize ()

(* ---- the window ---- *)

let program_name () =
  let n = Filename.basename Sys.executable_name in
  if Filename.check_suffix n ".byte" then Filename.chop_suffix n ".byte" else n

(* X11's geometry: " WxH", maybe followed by a position *)
let parse_geometry spec =
  let spec = String.trim spec in
  try Scanf.sscanf spec "%dx%d" (fun w h -> if w > 0 && h > 0 then (w, h) else (600, 450))
  with Scanf.Scan_failure _ | End_of_file | Failure _ -> (600, 450)

let make_window title w h =
  try Display.window ~title w h with
  | Ipc.Remote_error (_, msg) -> raise (Graphic_failure msg)
  | Failure msg | Sys_error msg -> raise (Graphic_failure msg)
  | Mynos.Error _ as e -> raise (Graphic_failure (Printexc.to_string e))

let at_exit_set = ref false

let close_graph () =
  match !state with
  | None -> ()
  | Some s ->
    (try show s with _ -> ());
    state := None;
    Display.destroy s.win

let open_graph spec =
  close_graph ();
  let w, h = parse_geometry spec in
  let win = make_window (program_name ()) w h in
  let back = Gfx.create w h in
  state := Some { win; back; w; h; color = black; cx = 0; cy = 0; lw = 1;
                  dirty = false; x0 = 0; y0 = 0; x1 = 0; y1 = 0;
                  shown = Mynos.uptime (); mx = 0; my = 0; buttons = 0;
                  keys = Queue.create () };
  display := true;
  remember := true;
  Display.damage win;
  if not !at_exit_set then begin
    at_exit_set := true;
    at_exit (fun () -> match !state with Some s -> (try show s with _ -> ()) | None -> ())
  end

let set_window_title t = Display.set_title (get ()).win t

let resize_window w h =
  let s = get () in
  if w <= 0 || h <= 0 then raise (Graphic_failure "resize_window: bad size");
  show s;
  let win = make_window (program_name ()) w h in
  let back = Gfx.create w h in
  (* the bottom left corner stays where it was *)
  Gfx.blit s.back 0 0 back 0 (h - s.h) s.w s.h;
  Display.destroy s.win;
  s.win <- win; s.back <- back; s.w <- w; s.h <- h;
  synchronize ()

let size_x () = (get ()).w
let size_y () = (get ()).h

let clear_graph () =
  let s = get () in
  draw_all s (fun g -> Gfx.fill g 0 0 s.w s.h background)

let set_color c = (get ()).color <- c
let set_line_width n = (get ()).lw <- max 1 n

(* ---- points and lines ---- *)

let plot x y =
  let s = get () in
  let y = gy s y in
  draw s x y (x + 1) (y + 1) (fun g -> Gfx.fill g x y 1 1 s.color)

let plots a = Array.iter (fun (x, y) -> plot x y) a

let point_color x y =
  let s = get () in
  if x < 0 || y < 0 || x >= s.w || y >= s.h then -1
  else Gfx.get (if !remember then s.back else s.win.Display.pixels) x (gy s y)

let moveto x y = let s = get () in s.cx <- x; s.cy <- y
let rmoveto dx dy = let s = get () in s.cx <- s.cx + dx; s.cy <- s.cy + dy
let current_x () = (get ()).cx
let current_y () = (get ()).cy
let current_point () = let s = get () in (s.cx, s.cy)

(* a polygon filled, its points in Gfx's coordinates (floats): every
   scan line through the centres of the pixels, even-odd rule *)
let fill_gfx_poly s g (pts : (float * float) array) =
  let n = Array.length pts in
  if n >= 3 then begin
    let ymin = Array.fold_left (fun m (_, y) -> min m y) infinity pts
    and ymax = Array.fold_left (fun m (_, y) -> max m y) neg_infinity pts in
    let ya = max 0 (int_of_float (Float.ceil (ymin -. 0.5)))
    and yb = min (s.h - 1) (int_of_float (Float.floor (ymax -. 0.5))) in
    let xs = Array.make n 0. in
    for yy = ya to yb do
      let yc = float yy +. 0.5 in
      let k = ref 0 in
      for i = 0 to n - 1 do
        let (xa, ya') = pts.(i) and (xb, yb') = pts.((i + 1) mod n) in
        if (ya' <= yc && yb' > yc) || (yb' <= yc && ya' > yc) then begin
          xs.(!k) <- xa +. (yc -. ya') /. (yb' -. ya') *. (xb -. xa);
          incr k
        end
      done;
      let c = Array.sub xs 0 !k in
      Array.sort compare c;
      let i = ref 0 in
      while !i + 1 < !k do
        let xl = int_of_float (Float.ceil (c.(!i) -. 0.5))
        and xr = int_of_float (Float.floor (c.(!i + 1) -. 0.5)) in
        if xr >= xl then Gfx.fill g xl yy (xr - xl + 1) 1 s.color;
        i := !i + 2
      done
    done
  end

(* a segment, in Graphics' coordinates, with the line width *)
let segment s xa ya xb yb =
  let lw = s.lw in
  let ya = gy s ya and yb = gy s yb in
  let m = lw / 2 + 1 in
  draw s (min xa xb - m) (min ya yb - m) (max xa xb + m + 1) (max ya yb + m + 1)
    (fun g ->
       if lw <= 1 then Gfx.line g xa ya xb yb s.color
       else begin
         let dx = float (xb - xa) and dy = float (yb - ya) in
         let len = Float.sqrt (dx *. dx +. dy *. dy) in
         let r = float lw /. 2. in
         let nx, ny = if len = 0. then (r, 0.) else (-. dy /. len *. r, dx /. len *. r) in
         let fx = float xa +. 0.5 and fy = float ya +. 0.5
         and tx = float xb +. 0.5 and ty = float yb +. 0.5 in
         let ex, ey = if len = 0. then (0., r) else (dx /. len *. r, dy /. len *. r) in
         (* a rectangle, a little longer than the segment: square ends *)
         fill_gfx_poly s g [| (fx +. nx -. ex, fy +. ny -. ey); (tx +. nx +. ex, ty +. ny +. ey);
                              (tx -. nx +. ex, ty -. ny +. ey); (fx -. nx -. ex, fy -. ny -. ey) |]
       end)

let lineto x y =
  let s = get () in
  segment s s.cx s.cy x y;
  s.cx <- x; s.cy <- y

let rlineto dx dy = let s = get () in lineto (s.cx + dx) (s.cy + dy)

let draw_poly_line a =
  let s = get () in
  let n = Array.length a in
  for i = 0 to n - 2 do
    let (xa, ya) = a.(i) and (xb, yb) = a.(i + 1) in segment s xa ya xb yb
  done;
  if n > 0 then (let (x, y) = a.(n - 1) in s.cx <- x; s.cy <- y)

let draw_poly a =
  let n = Array.length a in
  if n > 0 then draw_poly_line (Array.append a [| a.(0) |])

let draw_segments a =
  let s = get () in
  Array.iter (fun (xa, ya, xb, yb) -> segment s xa ya xb yb) a

let draw_rect x y w h =
  if w < 0 || h < 0 then raise (Invalid_argument "draw_rect");
  let s = get () in
  if s.lw <= 1 then begin
    let yt = gy s (y + h) in
    draw s x yt (x + w + 1) (yt + h + 1) (fun g -> Gfx.rect g x yt (w + 1) (h + 1) s.color)
  end else
    draw_poly [| (x, y); (x + w, y); (x + w, y + h); (x, y + h) |]

let bezier (x0, y0) (x1, y1) (x2, y2) (x3, y3) =
  let n = 32 in
  Array.init (n + 1) (fun i ->
      let t = float i /. float n in
      let u = 1. -. t in
      let f a b c d =
        int_of_float (Float.round (u *. u *. u *. float a +. 3. *. u *. u *. t *. float b
                                   +. 3. *. u *. t *. t *. float c +. t *. t *. t *. float d)) in
      (f x0 x1 x2 x3, f y0 y1 y2 y3))

let curveto b c d =
  let s = get () in
  draw_poly_line (bezier (s.cx, s.cy) b c d)

(* the points of an arc, in Graphics' coordinates *)
let arc_points x y rx ry a1 a2 =
  let r = max rx ry in
  let span = abs (a2 - a1) in
  let n = max 4 (int_of_float (Float.ceil (float r *. float span /. 180. *. Float.pi /. 3.))) in
  Array.init (n + 1) (fun i ->
      let a = (float a1 +. float (a2 - a1) *. float i /. float n) *. Float.pi /. 180. in
      (x + int_of_float (Float.round (float rx *. Float.cos a)),
       y + int_of_float (Float.round (float ry *. Float.sin a))))

let draw_arc x y rx ry a1 a2 =
  if rx < 0 || ry < 0 then raise (Invalid_argument "draw_arc/ellipse/circle");
  let s = get () in
  let cx = s.cx and cy = s.cy in
  draw_poly_line (arc_points x y rx ry a1 a2);
  s.cx <- cx; s.cy <- cy

let draw_ellipse x y rx ry = draw_arc x y rx ry 0 360
let draw_circle x y r = draw_arc x y r r 0 360

(* ---- text: one font, Terminus 8x16 ---- *)

let utf8_of_latin1 c =
  let n = Char.code c in
  if n < 0x80 then String.make 1 c
  else
    let b = Bytes.create 2 in
    Bytes.set b 0 (Char.chr (0xC0 lor (n lsr 6)));
    Bytes.set b 1 (Char.chr (0x80 lor (n land 0x3F)));
    Bytes.to_string b

let text_size str = (Gfx.cells str * Gfx.char_w, Gfx.char_h)

let draw_string str =
  let s = get () in
  let w, h = text_size str in
  let x = s.cx and yt = gy s s.cy - h + 1 in
  draw s x yt (x + w) (yt + h) (fun g -> ignore (Gfx.text g x yt str s.color));
  s.cx <- s.cx + w

let draw_char c = draw_string (utf8_of_latin1 c)
let set_font _ = ()
let set_text_size _ = ()

(* ---- filling ---- *)

let fill_rect x y w h =
  if w < 0 || h < 0 then raise (Invalid_argument "fill_rect");
  let s = get () in
  let yt = gy s (y + h) in
  draw s x yt (x + w + 1) (yt + h + 1) (fun g -> Gfx.fill g x yt (w + 1) (h + 1) s.color)

let fill_poly a =
  let s = get () in
  if Array.length a >= 3 then begin
    let pts = Array.map (fun (x, y) -> (float x +. 0.5, float (gy s y) +. 0.5)) a in
    let xs = Array.map fst a and ys = Array.map (fun (_, y) -> gy s y) a in
    let mn = Array.fold_left min max_int and mx = Array.fold_left max min_int in
    draw s (mn xs) (mn ys) (mx xs + 1) (mx ys + 1) (fun g -> fill_gfx_poly s g pts)
  end

let fill_ellipse x y rx ry =
  if rx < 0 || ry < 0 then raise (Invalid_argument "fill_ellipse/circle");
  let s = get () in
  let yc = gy s y in
  draw s (x - rx) (yc - ry) (x + rx + 1) (yc + ry + 1) (fun g ->
      for dy = - ry to ry do
        let half =
          if ry = 0 then rx
          else
            let t = float dy /. float ry in
            int_of_float (Float.round (float rx *. Float.sqrt (Float.max 0. (1. -. t *. t)))) in
        Gfx.fill g (x - half) (yc + dy) (2 * half + 1) 1 s.color
      done)

let fill_circle x y r = fill_ellipse x y r r

let fill_arc x y rx ry a1 a2 =
  if rx < 0 || ry < 0 then raise (Invalid_argument "fill_arc");
  if abs (a2 - a1) >= 360 then fill_ellipse x y rx ry
  else fill_poly (Array.append [| (x, y) |] (arc_points x y rx ry a1 a2))

(* ---- images: pixels of our own, and which of them are transparent ---- *)

type image = { iw : int; ih : int; px : Gfx.t; mutable mask : Bytes.t option }

let create_image w h =
  if w <= 0 || h <= 0 then raise (Graphic_failure "create_image: bad size");
  { iw = w; ih = h; px = Gfx.create w h; mask = None }

let make_image (rows : color array array) =
  let h = Array.length rows in
  let w = if h = 0 then 0 else Array.length rows.(0) in
  if h = 0 || w = 0 then raise (Graphic_failure "make_image: empty image");
  let img = create_image w h in
  let pixels = img.px.Gfx.pixels in
  let mask = Bytes.make (w * h) '\000' and any = ref false in
  Array.iteri (fun j row ->
      if Array.length row <> w then
        raise (Graphic_failure "make_image: non-rectangular matrix");
      Array.iteri (fun i c ->
          if c = transp then (Bytes.set mask (j * w + i) '\001'; any := true)
          else Bigarray.Array1.set pixels (j * w + i) (Int32.of_int (c land 0xFFFFFF)))
        row)
    rows;
  if !any then img.mask <- Some mask;
  img

let dump_image img =
  let pixels = img.px.Gfx.pixels in
  Array.init img.ih (fun j ->
      Array.init img.iw (fun i ->
          match img.mask with
          | Some m when Bytes.get m (j * img.iw + i) <> '\000' -> transp
          | _ -> Int32.to_int (Bigarray.Array1.get pixels (j * img.iw + i)) land 0xFFFFFF))

let draw_image img x y =
  let s = get () in
  let yt = gy s y - img.ih + 1 in
  draw s x yt (x + img.iw) (yt + img.ih) (fun g ->
      match img.mask with
      | None -> Gfx.blit img.px 0 0 g x yt img.iw img.ih
      | Some m ->
        (* the runs of pixels that are not transparent, row by row *)
        for j = 0 to img.ih - 1 do
          let i = ref 0 in
          while !i < img.iw do
            if Bytes.get m (j * img.iw + !i) <> '\000' then incr i
            else begin
              let a = !i in
              while !i < img.iw && Bytes.get m (j * img.iw + !i) = '\000' do incr i done;
              Gfx.blit img.px a j g (x + a) (yt + j) (!i - a) 1
            end
          done
        done)

let source s = if !remember then s.back else s.win.Display.pixels

let get_image x y w h =
  let s = get () in
  let img = create_image w h in
  Gfx.blit (source s) x (gy s y - h + 1) img.px 0 0 w h;
  img

let blit_image img x y =
  let s = get () in
  let yt = gy s y - img.ih + 1 in
  match img.mask with
  | None -> Gfx.blit (source s) x yt img.px 0 0 img.iw img.ih
  | Some m ->
    let copy = Gfx.create img.iw img.ih in
    Gfx.blit (source s) x yt copy 0 0 img.iw img.ih;
    let a = img.px.Gfx.pixels and b = copy.Gfx.pixels in
    for k = 0 to img.iw * img.ih - 1 do
      if Bytes.get m k = '\000' then Bigarray.Array1.set a k (Bigarray.Array1.get b k)
    done

(* ---- the mouse and the keys ---- *)

type status = {
  mouse_x : int;
  mouse_y : int;
  button : bool;
  keypressed : bool;
  key : char;
}

type event = Button_down | Button_up | Key_pressed | Mouse_motion | Poll

(* the characters of a key: Latin-1, as X11 gives them; sequences (the
   arrows, function keys) and characters beyond Latin-1 are not reported *)
let key_chars s k =
  let n = String.length k in
  if n > 1 && k.[0] = '\027' then ()
  else begin
    let d = String.get_utf_8_uchar in
    let i = ref 0 in
    while !i < n do
      let u = d k !i in
      let c = Uchar.to_int (Uchar.utf_decode_uchar u) in
      if Uchar.utf_decode_is_valid u && c < 256 then Queue.push (Char.chr c) s.keys;
      i := !i + Uchar.utf_decode_length u
    done
  end

let handle s = function
  | Display.Key k -> key_chars s k
  | Display.Mouse { x; y; buttons } ->
    s.mx <- x; s.my <- gy s y; s.buttons <- buttons
  | Display.Close -> close_graph (); exit 0
  | Display.Tick | Display.Focus _ | Display.Wheel _ -> ()

(* the events waiting, without waiting *)
let drain s =
  let rec loop () =
    match Display.poll s.win with
    | Display.Tick -> ()
    | e -> handle s e; if !state <> None then loop () in
  loop ()

let status s ~take =
  let keypressed = not (Queue.is_empty s.keys) in
  let key =
    if not keypressed then '\000' else if take then Queue.pop s.keys else Queue.peek s.keys in
  { mouse_x = s.mx; mouse_y = s.my; button = s.buttons <> 0; keypressed; key }

let wait_next_event evs =
  let s = get () in
  show s;
  if List.mem Poll evs then (drain s; status s ~take:false)
  else begin
    let rec loop () =
      if List.mem Key_pressed evs && not (Queue.is_empty s.keys) then status s ~take:true
      else begin
        let mx = s.mx and my = s.my and b = s.buttons in
        let e = Display.next_event s.win in
        handle s e;
        match e with
        | Display.Mouse _ when List.mem Button_down evs && b = 0 && s.buttons <> 0 ->
          status s ~take:false
        | Display.Mouse _ when List.mem Button_up evs && b <> 0 && s.buttons = 0 ->
          status s ~take:false
        | Display.Mouse _ when List.mem Mouse_motion evs && (mx, my) <> (s.mx, s.my) ->
          status s ~take:false
        | _ -> loop ()
      end in
    loop ()
  end

let loop_at_exit evs f =
  at_exit (fun () ->
      try while !state <> None do f (wait_next_event evs) done with Exit -> ())

let mouse_pos () =
  let s = wait_next_event [ Poll ] in (s.mouse_x, s.mouse_y)

let button_down () = (wait_next_event [ Poll ]).button
let key_pressed () = (wait_next_event [ Poll ]).keypressed
let read_key () = (wait_next_event [ Key_pressed ]).key

let sound _ _ = ()
