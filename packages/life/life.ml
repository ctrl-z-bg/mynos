(* life: Conway's Game of Life, the manual's example of 20.5 grown up: a
   larger board, famous patterns to place, drawing with the mouse,
   patterns read from and written to files in the RLE format that Life's
   collections use (LifeWiki, Golly), and a choice of speed. *)

let cols = 128 and rows = 80 and cell = 6
let top = 76                                  (* the two bars of buttons *)
let width = cols * cell and height = top + rows * cell + 24

type state = {
  mutable grid : Bytes.t;                     (* cols * rows, '\001' alive *)
  mutable running : bool;
  mutable gen : int;
  mutable speed : int;                        (* 0 to 3 *)
  mutable next_at : float;
  mutable drawing : bool option;              (* dragging: what it draws *)
  mutable placing : (string * (int * int) list) option;  (* a pattern to drop *)
  mutable message : string;
}

let idx x y = ((y + rows) mod rows) * cols + ((x + cols) mod cols)
let alive g i = Bytes.unsafe_get g i <> '\000'

(* one generation; the board is a torus *)
let step g =
  let n = Bytes.make (cols * rows) '\000' in
  for y = 0 to rows - 1 do
    let up = ((y + rows - 1) mod rows) * cols and here = y * cols
    and down = ((y + 1) mod rows) * cols in
    for x = 0 to cols - 1 do
      let l = (x + cols - 1) mod cols and r = (x + 1) mod cols in
      let c = Char.code (Bytes.unsafe_get g (up + l)) + Char.code (Bytes.unsafe_get g (up + x))
              + Char.code (Bytes.unsafe_get g (up + r)) + Char.code (Bytes.unsafe_get g (here + l))
              + Char.code (Bytes.unsafe_get g (here + r)) + Char.code (Bytes.unsafe_get g (down + l))
              + Char.code (Bytes.unsafe_get g (down + x)) + Char.code (Bytes.unsafe_get g (down + r)) in
      if c = 3 || (c = 2 && alive g (here + x)) then Bytes.unsafe_set n (here + x) '\001'
    done
  done;
  n

(* {1 RLE} *)

(* the cells of a pattern in RLE: "x = 3, y = 3" then runs of b (dead), o
   (alive), $ (next line), ending with !; lines with # are comments *)
let of_rle text =
  let lines = String.split_on_char '\n' text in
  let body = List.filter (fun l ->
      let l = String.trim l in
      l <> "" && l.[0] <> '#' && not (String.length l > 1 && l.[0] = 'x' && (l.[1] = ' ' || l.[1] = '=')))
      lines in
  let cells = ref [] and x = ref 0 and y = ref 0 and n = ref 0 in
  (try
     String.iter (fun c ->
         let count () = let k = max 1 !n in n := 0; k in
         match c with
         | '0' .. '9' -> n := !n * 10 + Char.code c - 48
         | 'b' | '.' -> x := !x + count ()
         | 'o' | 'A' .. 'Z' ->
           for _ = 1 to count () do cells := (!x, !y) :: !cells; incr x done
         | '$' -> y := !y + count (); x := 0
         | '!' -> raise Exit
         | _ -> ()) (String.concat "" body)
   with Exit -> ());
  if !cells = [] then failwith "no live cell in it";
  List.rev !cells

let to_rle g =
  let cells = List.filter (alive g) (List.init (cols * rows) Fun.id)
              |> List.map (fun i -> (i mod cols, i / cols)) in
  match cells with
  | [] -> "x = 0, y = 0, rule = B3/S23\n!\n"
  | _ ->
    let x0 = List.fold_left (fun a (x, _) -> min a x) cols cells
    and y0 = List.fold_left (fun a (_, y) -> min a y) rows cells
    and x1 = List.fold_left (fun a (x, _) -> max a x) 0 cells
    and y1 = List.fold_left (fun a (_, y) -> max a y) 0 cells in
    let b = Buffer.create 1024 in
    let line = Buffer.create 80 in
    let emit s =
      if Buffer.length line + String.length s > 70 then begin
        Buffer.add_buffer b line; Buffer.add_char b '\n'; Buffer.clear line end;
      Buffer.add_string line s in
    let run k c = emit ((if k > 1 then string_of_int k else "") ^ String.make 1 c) in
    let blank = ref 0 in
    for y = y0 to y1 do
      let row = Array.init (x1 - x0 + 1) (fun i -> alive g (idx (x0 + i) y)) in
      let last = ref (-1) in
      Array.iteri (fun i a -> if a then last := i) row;
      if !last < 0 then incr blank
      else begin
        if y > y0 then run (!blank + 1) '$';
        blank := 0;
        let i = ref 0 in
        while !i <= !last do
          let a = row.(!i) in
          let j = ref !i in
          while !j <= !last && row.(!j) = a do incr j done;
          run (!j - !i) (if a then 'o' else 'b');
          i := !j
        done
      end
    done;
    emit "!";
    Buffer.add_buffer b line;
    Printf.sprintf "#C Made with MyNOS's life\nx = %d, y = %d, rule = B3/S23\n%s\n"
      (x1 - x0 + 1) (y1 - y0 + 1) (Buffer.contents b)

(* {1 Patterns} *)

let patterns = [
  "Glider", "bob$2bo$3o!";
  "Spaceship", "bo2bo$o4b$o3bo$4o!";
  "Pulsar", "2b3o3b3o2b2$o4bobo4bo$o4bobo4bo$o4bobo4bo$2b3o3b3o2b2$2b3o3b3o2b$o4bobo4bo$o4bobo4bo$o4bobo4bo2$2b3o3b3o!";
  "Pentadecathlon", "2bo4bo2b$2ob4ob2o$2bo4bo!";
  "Glider gun", "24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$10bo5bo7bo$11bo3bo$12b2o!";
  "R-pentomino", "b2o$2ob$bo!";
  "Acorn", "bo5b$3bo3b$2o2b3o!";
  "Diehard", "6bob$2o6b$bo3b3o!";
]

let empty () = Bytes.make (cols * rows) '\000'
let random_grid () = Bytes.init (cols * rows) (fun _ -> if Random.int 100 < 22 then '\001' else '\000')

let place g cells cx cy =
  let w = List.fold_left (fun a (x, _) -> max a x) 0 cells
  and h = List.fold_left (fun a (_, y) -> max a y) 0 cells in
  List.iter (fun (x, y) -> Bytes.set g (idx (cx + x - w / 2) (cy + y - h / 2)) '\001') cells

let speeds = [| "Slow", 0.5; "Normal", 0.12; "Fast", 0.03; "Fastest", 0. |]

let frame ui st =
  let g = ui.Gui.g in
  Gfx.fill g 0 0 width height 0x101018;
  Gfx.fill g 0 0 width top Gui.panel_colour;
  let b x w label = Gui.button ui x 8 w label in
  if b 8 76 (if st.running then "Pause" else "Run") then st.running <- not st.running;
  if b 90 60 "Step" then begin st.grid <- step st.grid; st.gen <- st.gen + 1 end;
  if b 156 76 "Random" then begin st.grid <- random_grid (); st.gen <- 0 end;
  if b 238 64 "Clear" then begin st.grid <- empty (); st.gen <- 0; st.running <- false end;
  if b 308 98 (fst speeds.(st.speed)) then st.speed <- (st.speed + 1) mod Array.length speeds;
  if b 412 70 "Open" then
    Gui.open_file_picker ~title:"A pattern (RLE)" ~dir:"/disk"
      ~filter:(fun n -> Filename.check_suffix (String.lowercase_ascii n) ".rle") 1;
  if b 488 70 "Save" then begin
    let rec free n =
      let f = Printf.sprintf "/disk/life-%d.rle" n in
      if Sys.file_exists f then free (n + 1) else f in
    let f = free 1 in
    match Out_channel.with_open_bin f (fun oc -> output_string oc (to_rle st.grid)) with
    | () -> st.message <- "saved as " ^ f
    | exception Sys_error m -> st.message <- m
  end;
  (* the second bar: patterns to place *)
  let x = ref 8 in
  List.iter (fun (name, rle) ->
      let w = Gfx.char_w * String.length name + 20 in
      if Gui.button ~h:24 ui !x 44 w name then begin
        st.placing <- Some (name, of_rle rle);
        st.message <- "click where the " ^ String.lowercase_ascii name ^ " goes (Escape: no)"
      end;
      x := !x + w + 6) patterns;
  List.iter (function
      | " " -> st.running <- not st.running
      | "s" -> st.grid <- step st.grid; st.gen <- st.gen + 1
      | "r" -> st.grid <- random_grid (); st.gen <- 0
      | "c" -> st.grid <- empty (); st.gen <- 0
      | "\027" -> st.placing <- None; st.message <- ""
      | "q" -> raise Gui.Quit
      | _ -> ()) ui.Gui.keys;
  (* the board: a click places the pattern chosen, or draws (not while
     the file picker is open, nor in the frame it closes: it is answered
     below, after the board) *)
  let on_board = Gui.hovered ui 0 top width (rows * cell) in
  let cx = ui.Gui.mx / cell and cy = (ui.Gui.my - top) / cell in
  (match st.placing with
   | Some (_, cells) when on_board && ui.Gui.clicked ->
     place st.grid cells cx cy; st.placing <- None; st.message <- ""
   | Some _ -> ()
   | None ->
     if on_board && ui.Gui.buttons land 1 <> 0 then begin
       let i = idx cx cy in
       let v = match st.drawing with
         | Some v -> v
         | None -> let v = not (alive st.grid i) in st.drawing <- Some v; v in
       Bytes.set st.grid i (if v then '\001' else '\000')
     end else if ui.Gui.buttons land 1 = 0 then st.drawing <- None);
  (* the time *)
  let now = Mynos.uptime () in
  if st.running && now >= st.next_at then begin
    st.grid <- step st.grid; st.gen <- st.gen + 1;
    st.next_at <- now +. snd speeds.(st.speed)
  end;
  let alive_n = ref 0 in
  for i = 0 to cols * rows - 1 do
    if alive st.grid i then begin
      incr alive_n;
      Gfx.fill g (i mod cols * cell) (top + i / cols * cell) (cell - 1) (cell - 1) 0x40E070
    end
  done;
  (match st.placing with
   | Some (_, cells) when on_board ->
     let w = List.fold_left (fun a (x, _) -> max a x) 0 cells
     and h = List.fold_left (fun a (_, y) -> max a y) 0 cells in
     List.iter (fun (x, y) ->
         let i = idx (cx + x - w / 2) (cy + y - h / 2) in
         Gfx.fill g (i mod cols * cell) (top + i / cols * cell) (cell - 1) (cell - 1) 0xFFD54F) cells
   | _ -> ());
  let sy = top + rows * cell + 4 in
  ignore (Gfx.text g 8 sy (Printf.sprintf "generation %d   alive %d" st.gen !alive_n) 0xB0BEC5);
  ignore (Gfx.text g 300 sy st.message 0xFFD54F);
  (match Gui.file_picker ui 1 with
   | Some (Gui.Picked path) ->
     (match of_rle (In_channel.with_open_bin path In_channel.input_all) with
      | cells -> st.placing <- Some (Filename.basename path, cells);
        st.message <- "click where it goes (Escape: no)"
      | exception (Failure m | Sys_error m) -> st.message <- Filename.basename path ^ ": " ^ m)
   | Some Gui.Cancelled | None -> ());
  st

let () =
  Random.self_init ();
  let grid = empty () in
  place grid (of_rle (List.assoc "Glider gun" patterns)) 24 14;
  Gui.run ~title:"Life" ~tick:0.03 width height
    { grid; running = true; gen = 0; speed = 1; next_at = 0.; drawing = None; placing = None;
      message = "" } frame
