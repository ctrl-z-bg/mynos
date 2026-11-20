(* OCaml's Graphics on MyNOS (20.6): a circle where the mouse is
   clicked, q to quit. y grows upwards, from the bottom left corner. *)
open Graphics

let () =
  open_graph " 400x300";
  set_window_title "Circles";
  moveto 10 10;
  draw_string "click to draw, q to quit";
  let rec loop () =
    let s = wait_next_event [ Button_down; Key_pressed ] in
    if s.keypressed && s.key = 'q' then close_graph ()
    else begin
      if s.button then begin
        set_color (rgb (Random.int 256) (Random.int 256) (Random.int 256));
        fill_circle s.mouse_x s.mouse_y (10 + Random.int 30)
      end;
      loop ()
    end in
  loop ()
