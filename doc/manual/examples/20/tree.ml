(* A tree in the wind: a fractal tree under a night sky, drawn with
   Graphics. The mouse sets the wind, leaves fall from the branches. *)

open Graphics

let w = 640 and h = 480
let pi = 4.0 *. atan 1.0

(* fixed stars: position and phase of their twinkle *)
let stars =
  Array.init 80 (fun _ ->
    (Random.int w, 150 + Random.int (h - 150), Random.int 100))

(* falling leaves *)
type leaf = { mutable x : float; mutable y : float;
              mutable vx : float; mutable vy : float; c : color }
let leaves : leaf list ref = ref []

let depth = ref 9            (* levels of branches *)
let spread = ref 0.45        (* angle between two branches, in radians *)
let t = ref 0.0              (* time, for the wind and the stars *)
let autumn = ref false

let leaf_colour lvl =
  if !autumn then rgb (200 + Random.int 55) (60 + Random.int 120) 20
  else rgb (30 + 10 * lvl) (140 + Random.int 100) (40 + Random.int 40)

(* a branch from (x, y), [len] long, at angle [ang]; at level 0, a leaf,
   which now and then comes off *)
let rec branch x y len ang lvl wind =
  if lvl = 0 then begin
    set_color (leaf_colour 0);
    fill_circle (int_of_float x) (int_of_float y) 3;
    if Random.int 600 = 0 && List.length !leaves < 120 then
      leaves := { x; y; vx = 0.; vy = 0.; c = leaf_colour 0 } :: !leaves
  end else begin
    (* the thinner the branch, the more the wind bends it *)
    let sway = wind *. float (!depth - lvl + 1) *. 0.04 in
    let a = ang +. sway in
    let x2 = x +. len *. cos a and y2 = y +. len *. sin a in
    let g = 60 + 15 * (!depth - lvl) in
    set_color (rgb (90 + (!depth - lvl) * 8) (min 255 g) 30);
    set_line_width (max 1 lvl);
    moveto (int_of_float x) (int_of_float y);
    lineto (int_of_float x2) (int_of_float y2);
    branch x2 y2 (len *. 0.72) (a +. !spread) (lvl - 1) wind;
    branch x2 y2 (len *. 0.72) (a -. !spread *. 0.85) (lvl - 1) wind
  end

let draw_scene () =
  (* the sky, in bands *)
  for i = 0 to 15 do
    let k = i * 255 / 15 in
    set_color (rgb (10 + k / 8) (10 + k / 6) (40 + k / 3));
    fill_rect 0 (h - (i + 1) * (h / 16)) w (h / 16 + 1)
  done;
  (* twinkling stars *)
  Array.iter (fun (x, y, p) ->
    let b = 150 + int_of_float (100. *. sin (!t *. 3. +. float p)) in
    let b = max 0 (min 255 b) in
    set_color (rgb b b b); plot x y) stars;
  (* the moon: a disc, and a dark one over it *)
  set_color (rgb 250 240 200); fill_circle 540 400 32;
  set_color (rgb 25 30 75); fill_circle 528 408 28;
  (* hills *)
  set_color (rgb 20 60 30);
  fill_poly (Array.init 33 (fun i ->
    if i = 32 then (0, 0) else if i = 31 then (w, 0)
    else let x = i * w / 30 in
      (x, 60 + int_of_float (15. *. sin (float x /. 60.)))));
  ()

(* move the leaves, draw them; keep those still above the ground *)
let update_leaves wind =
  leaves := List.filter (fun l ->
    l.vy <- l.vy -. 0.08;
    l.vx <- l.vx *. 0.95 +. wind *. 0.3
            +. 0.4 *. sin (!t *. 4. +. l.y /. 20.);
    l.x <- l.x +. l.vx; l.y <- l.y +. max l.vy (-2.0);
    set_color l.c;
    fill_ellipse (int_of_float l.x) (int_of_float l.y) 4 2;
    l.y > 50. && l.x > -10. && l.x < float w +. 10.) !leaves

let hud () =
  set_color white;
  moveto 10 (h - 20);
  draw_string
    (Printf.sprintf "Fractal tree - depth %d  spread %.2f  leaves %d"
       !depth !spread (List.length !leaves));
  moveto 10 (h - 36);
  draw_string "Mouse: wind   +/- depth   a/z spread   space: autumn   q: quit"

let () =
  Random.self_init ();
  open_graph (Printf.sprintf " %dx%d" w h);
  set_window_title "A tree in the wind";
  auto_synchronize false;          (* each frame drawn whole, then shown *)
  let running = ref true in
  while !running do
    t := !t +. 0.05;
    (* the wind: the mouse's distance from the middle, and two gusts *)
    let (mx, _) = mouse_pos () in
    let user_wind = (float mx -. float w /. 2.) /. float w in
    let wind = user_wind +. 0.15 *. sin !t +. 0.05 *. sin (!t *. 2.7) in
    draw_scene ();
    branch (float w /. 2.) 60. 95. (pi /. 2.) !depth wind;
    set_line_width 1;
    update_leaves wind;
    hud ();
    synchronize ();
    while key_pressed () do
      match read_key () with
      | 'q' | '\027' -> running := false
      | '+' | '=' -> depth := min 12 (!depth + 1)
      | '-' -> depth := max 1 (!depth - 1)
      | 'a' -> spread := min 1.5 (!spread +. 0.05)
      | 'z' -> spread := max 0.05 (!spread -. 0.05)
      | ' ' -> autumn := not !autumn
      | _ -> ()
    done;
    Mynos.sleep 0.03
  done;
  close_graph ()
