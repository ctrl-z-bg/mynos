(* The Graphics module's test (mynos-0rn): draws in a window and reads the
   pixels back with point_color; the result goes to the log ("graphics: all
   checks passed"). With an argument, it then waits for a key or a click,
   so that the window can be looked at. *)

open Graphics

let fails = ref []
let check what ok = if not ok then fails := what :: !fails

let () =
  open_graph " 320x240";
  set_window_title "Graphics test";
  check "size" (size_x () = 320 && size_y () = 240);
  check "white at first" (point_color 10 10 = white);
  (* the origin is the bottom left corner *)
  set_color red;
  plot 0 0;
  check "plot at the origin" (point_color 0 0 = red);
  check "plot: one pixel" (point_color 1 0 = white && point_color 0 1 = white);
  (* fill_rect covers w+1 x h+1 pixels, as draw_rect does (X11) *)
  set_color blue;
  fill_rect 20 20 40 30;
  check "fill_rect inside" (point_color 20 20 = blue && point_color 60 50 = blue);
  check "fill_rect outside" (point_color 61 50 = white && point_color 60 51 = white);
  set_color black;
  draw_rect 100 20 40 30;
  check "draw_rect: its outline" (point_color 100 20 = black && point_color 140 50 = black);
  check "draw_rect: not inside" (point_color 120 35 = white);
  (* lines and the current point *)
  moveto 10 100; lineto 110 100;
  check "lineto" (point_color 10 100 = black && point_color 60 100 = black
                  && point_color 110 100 = black);
  check "current point" (current_point () = (110, 100));
  set_line_width 5;
  set_color green;
  moveto 10 120; lineto 110 120;
  check "a thick line" (point_color 60 118 = green && point_color 60 122 = green);
  set_line_width 1;
  (* circles *)
  set_color magenta;
  fill_circle 200 120 20;
  check "fill_circle" (point_color 200 120 = magenta && point_color 219 120 = magenta
                       && point_color 200 141 = white && point_color 215 135 <> magenta);
  set_color cyan;
  draw_circle 270 120 20;
  check "draw_circle" (point_color 290 120 = cyan && point_color 270 140 = cyan
                       && point_color 270 120 = white);
  (* polygons *)
  set_color yellow;
  fill_poly [| (200, 20); (260, 20); (230, 70) |];
  check "fill_poly" (point_color 230 40 = yellow && point_color 205 60 = white);
  set_color (rgb 0x80 0x40 0x20);
  fill_arc 290 40 20 20 0 90;
  check "fill_arc: a quarter" (point_color 295 45 = rgb 0x80 0x40 0x20
                               && point_color 285 35 = white);
  (* text: its bottom left at the current point *)
  set_color black;
  moveto 10 200;
  let w, h = text_size "MyNOS" in
  check "text_size" (w = 40 && h = 16);
  draw_string "MyNOS";
  check "draw_string moves the point" (current_x () = 50);
  let ink = ref false in
  for x = 10 to 49 do for y = 200 to 215 do
      if point_color x y = black then ink := true done done;
  check "draw_string: ink above the point" !ink;
  (* images *)
  let img = make_image [| [| red; green |]; [| transp; blue |] |] in
  check "dump_image" (dump_image img = [| [| red; green |]; [| transp; blue |] |]);
  set_color white;
  fill_rect 150 150 10 10;
  draw_image img 150 150;
  (* the image's first row is its top: at y = 151 *)
  check "draw_image" (point_color 150 151 = red && point_color 151 151 = green
                      && point_color 151 150 = blue);
  check "draw_image: transparent pixel" (point_color 150 150 = white);
  let g = get_image 20 20 2 2 in
  check "get_image" (dump_image g = [| [| blue; blue |]; [| blue; blue |] |]);
  (* double buffering: nothing on the screen until synchronize *)
  auto_synchronize false;
  set_color red;
  fill_rect 0 220 319 19;
  check "drawn in the buffer" (point_color 5 225 = red);
  synchronize ();
  auto_synchronize true;
  (* the input, without waiting *)
  ignore (key_pressed ());
  ignore (mouse_pos ());
  let st = wait_next_event [ Poll ] in
  check "Poll: no key waiting" (not st.keypressed);
  let result =
    if !fails = [] then "graphics: all checks passed"
    else "graphics: FAIL " ^ String.concat ", " (List.rev !fails) in
  Mynos.log result;
  print_endline result;
  if Array.length Sys.argv > 1 then ignore (wait_next_event [ Key_pressed; Button_down ]);
  close_graph ()
