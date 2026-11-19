(* Life: Conway's Game of Life in a window. *)

let cols = 80 and rows = 50          (* the board, in cells *)
let cell = 8                         (* a cell, in pixels *)
let top = 40                         (* the bar of buttons *)
let w = cols * cell
let h = top + rows * cell

type state = {
  mutable grid : bool array;         (* cols * rows, row by row *)
  mutable running : bool;
  mutable gen : int;
}

(* the board is a torus: the edges wrap around *)
let idx x y = ((y + rows) mod rows) * cols + ((x + cols) mod cols)

let step g =
  Array.init (cols * rows) (fun i ->
      let x = i mod cols and y = i / cols in
      let n = ref 0 in
      for dy = -1 to 1 do
        for dx = -1 to 1 do
          if (dx <> 0 || dy <> 0) && g.(idx (x + dx) (y + dy)) then incr n
        done
      done;
      if g.(i) then !n = 2 || !n = 3 else !n = 3)

let random_grid () = Array.init (cols * rows) (fun _ -> Random.int 100 < 25)
let empty () = Array.make (cols * rows) false

(* Gosper's glider gun *)
let glider_gun () =
  let g = empty () in
  List.iter (fun (x, y) -> g.(idx (x + 2) (y + 2)) <- true)
    [ (1,5); (1,6); (2,5); (2,6); (11,5); (11,6); (11,7); (12,4); (12,8);
      (13,3); (13,9); (14,3); (14,9); (15,6); (16,4); (16,8); (17,5);
      (17,6); (17,7); (18,6); (21,3); (21,4); (21,5); (22,3); (22,4);
      (22,5); (23,2); (23,6); (25,1); (25,2); (25,6); (25,7); (35,3);
      (35,4); (36,3); (36,4) ];
  g

let frame ui st =
  let g = ui.Gui.g in
  (* the board's background, and the bar *)
  Gfx.fill g 0 0 w h 0x101018;
  Gfx.fill g 0 0 w top Gui.panel_colour;
  (* the buttons: drawn, and answered, in the same call *)
  if Gui.button ui 8 8 90 (if st.running then "Pause" else "Run") then
    st.running <- not st.running;
  if Gui.button ui 106 8 70 "Step" then begin
    st.grid <- step st.grid; st.gen <- st.gen + 1 end;
  if Gui.button ui 184 8 90 "Random" then begin
    st.grid <- random_grid (); st.gen <- 0 end;
  if Gui.button ui 282 8 90 "Gun" then begin
    st.grid <- glider_gun (); st.gen <- 0 end;
  if Gui.button ui 380 8 80 "Clear" then begin
    st.grid <- empty (); st.gen <- 0; st.running <- false end;
  (* the keys typed since the last frame *)
  List.iter (function
      | " " -> st.running <- not st.running
      | "s" -> st.grid <- step st.grid; st.gen <- st.gen + 1
      | "r" -> st.grid <- random_grid (); st.gen <- 0
      | "c" -> st.grid <- empty (); st.gen <- 0
      | "q" -> raise Gui.Quit
      | _ -> ()) ui.Gui.keys;
  (* a click on the board turns a cell on or off *)
  if ui.Gui.clicked && ui.Gui.my >= top && ui.Gui.my < h
     && ui.Gui.mx >= 0 && ui.Gui.mx < w then begin
    let i = idx (ui.Gui.mx / cell) ((ui.Gui.my - top) / cell) in
    st.grid.(i) <- not st.grid.(i)
  end;
  (* the timer: one generation *)
  if ui.Gui.tick && st.running then begin
    st.grid <- step st.grid; st.gen <- st.gen + 1 end;
  (* the cells *)
  let alive = ref 0 in
  Array.iteri (fun i a ->
      if a then begin
        incr alive;
        let x = i mod cols and y = i / cols in
        Gfx.fill g (x * cell) (top + y * cell) (cell - 1) (cell - 1) 0x40E070
      end) st.grid;
  ignore (Gfx.text g 470 14
            (Printf.sprintf "gen %d  alive %d" st.gen !alive) Gui.foreground);
  st

let () =
  Random.self_init ();
  Gui.run ~title:"Life" ~tick:0.1 w h
    { grid = random_grid (); running = true; gen = 0 } frame
