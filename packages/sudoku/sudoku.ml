(* sudoku: fill the grid so that each row, each column and each 3x3 box
   holds 1 to 9 once. The puzzles are made here, each with one solution.
   Click a square, type its digit (0, Backspace or Delete clears it; the
   arrows move); a digit that clashes with another is red. Hint fills one
   square; Solve shows the solution. *)

let cell = 44
let width = 9 * cell + 230 and height = 9 * cell + 40
let ox = 20 and oy = 20

(* {1 Solving} *)

(* the digits a square may take: bits 1 to 9 *)
let candidates g i =
  let r = i / 9 and c = i mod 9 in
  let used = ref 0 in
  for k = 0 to 8 do
    used := !used lor (1 lsl g.(r * 9 + k)) lor (1 lsl g.(k * 9 + c))
            lor (1 lsl g.((r / 3 * 3 + k / 3) * 9 + c / 3 * 3 + k mod 3))
  done;
  lnot !used land 0x3FE

let popcount n = let rec go n a = if n = 0 then a else go (n land (n - 1)) (a + 1) in go n 0

(* the solutions of [g], up to [limit]; [shuffle] tries the digits in a
   random order (to make grids). The empty square with the fewest
   candidates is filled first. *)
let solve ?(shuffle = false) ?(limit = 1) g =
  let found = ref [] in
  let rec go () =
    if List.length !found < limit then begin
      let best = ref (-1) and best_n = ref 10 in
      for i = 0 to 80 do
        if g.(i) = 0 then begin
          let n = popcount (candidates g i) in
          if n < !best_n then begin best := i; best_n := n end
        end
      done;
      if !best < 0 then found := Array.copy g :: !found
      else if !best_n > 0 then begin
        let cs = candidates g !best in
        let ds = List.filter (fun d -> cs land (1 lsl d) <> 0) [ 1; 2; 3; 4; 5; 6; 7; 8; 9 ] in
        let ds = if shuffle then List.sort (fun _ _ -> Random.int 3 - 1) ds else ds in
        List.iter (fun d ->
            if List.length !found < limit then begin
              g.(!best) <- d; go (); g.(!best) <- 0
            end) ds
      end
    end in
  go ();
  List.rev !found

(* a puzzle: a full grid, emptied square by square (in a random order)
   while the solution stays the only one, down to about [keep] clues *)
let make keep =
  let full = match solve ~shuffle:true (Array.make 81 0) with s :: _ -> s | [] -> assert false in
  let g = Array.copy full in
  let order = Array.init 81 Fun.id in
  for i = 80 downto 1 do
    let j = Random.int (i + 1) in let t = order.(i) in order.(i) <- order.(j); order.(j) <- t
  done;
  let clues = ref 81 in
  Array.iter (fun i ->
      if !clues > keep then begin
        let d = g.(i) in
        g.(i) <- 0;
        if List.length (solve ~limit:2 (Array.copy g)) = 1 then decr clues else g.(i) <- d
      end) order;
  g, full

(* {1 The game} *)

type state = {
  mutable given : bool array;
  mutable grid : int array;
  mutable solution : int array;
  mutable sel : int;
  mutable level : int;                     (* 0 easy, 1 medium, 2 hard *)
  mutable solved_shown : bool;
  mutable started : float;
  mutable finished : float option;
}

let clues = [| 38; 30; 24 |]
let names = [| "Easy"; "Medium"; "Hard" |]

let start st level =
  let g, s = make clues.(level) in
  st.grid <- g; st.solution <- s; st.given <- Array.map (( <> ) 0) g;
  st.sel <- 40; st.level <- level; st.solved_shown <- false;
  st.started <- Mynos.uptime (); st.finished <- None

let clashes g i =
  let d = g.(i) in
  d <> 0 && (g.(i) <- 0; let c = candidates g i land (1 lsl d) = 0 in g.(i) <- d; c)

let complete st = Array.for_all2 ( = ) st.grid st.solution

let draw ui st =
  let gx = ui.Gui.g in
  let sr = st.sel / 9 and sc = st.sel mod 9 in
  let seld = st.grid.(st.sel) in
  for i = 0 to 80 do
    let r = i / 9 and c = i mod 9 in
    let x = ox + c * cell and y = oy + r * cell in
    let bg =
      if i = st.sel then 0xFFE082
      else if seld <> 0 && st.grid.(i) = seld then 0xFFF3C4
      else if r = sr || c = sc || (r / 3 = sr / 3 && c / 3 = sc / 3) then 0xE8EEF4
      else 0xFFFFFF in
    Gfx.fill gx x y cell cell bg;
    if Gui.hovered ui x y cell cell && i <> st.sel then Gfx.rect gx (x + 1) (y + 1) (cell - 2) (cell - 2) 0x90A4AE;
    let d = st.grid.(i) in
    if d <> 0 then begin
      let colour = if clashes st.grid i then 0xD32F2F else if st.given.(i) then 0x263238 else 0x1565C0 in
      ignore (Gfx.text ~bold:st.given.(i) gx (x + cell / 2 - 4) (y + cell / 2 - 8) (string_of_int d) colour)
    end
  done;
  for k = 0 to 9 do
    let w = if k mod 3 = 0 then 2 else 1 and col = if k mod 3 = 0 then 0x37474F else 0xB0BEC5 in
    Gfx.fill gx (ox + k * cell - w / 2) oy w (9 * cell) col;
    Gfx.fill gx ox (oy + k * cell - w / 2) (9 * cell) w col
  done

let () =
  Random.self_init ();
  let st = { given = [||]; grid = [||]; solution = [||]; sel = 40; level = 0;
             solved_shown = false; started = 0.; finished = None } in
  start st 0;
  Gui.run ~title:"Sudoku" ~tick:1.0 width height st (fun ui st ->
      draw ui st;
      let sx = ox + 9 * cell + 24 in
      Gui.label ~bold:true ui sx 22 ("Sudoku, " ^ String.lowercase_ascii names.(st.level));
      let secs = match st.finished with
        | Some t -> int_of_float (t -. st.started)
        | None -> int_of_float (Mynos.uptime () -. st.started) in
      Gui.label ~colour:Gui.muted ui sx 44 (Printf.sprintf "Time %d:%02d" (secs / 60) (secs mod 60));
      Array.iteri (fun i n ->
          if Gui.button ui sx (80 + i * 38) 176 ("New: " ^ n) then start st i) names;
      if Gui.button ui sx 210 84 "Hint" && st.finished = None then begin
        (* a square left empty or wrong, filled *)
        let wrong = List.filter (fun i -> st.grid.(i) <> st.solution.(i)) (List.init 81 Fun.id) in
        match wrong with
        | [] -> ()
        | _ ->
          let i = if List.mem st.sel wrong then st.sel else List.nth wrong (Random.int (List.length wrong)) in
          st.grid.(i) <- st.solution.(i); st.sel <- i
      end;
      if Gui.button ui (sx + 92) 210 84 "Solve" && st.finished = None then begin
        st.grid <- Array.copy st.solution; st.solved_shown <- true;
        st.finished <- Some (Mynos.uptime ())
      end;
      (match st.finished with
       | Some _ when st.solved_shown -> Gui.label ~colour:Gui.muted ui sx 260 "The solution."
       | Some _ -> Gui.label ~bold:true ~colour:0x2E7D32 ui sx 260 "Solved!"
       | None -> ());
      ignore (Gui.paragraph ~colour:Gui.muted ui sx 300 180
                "Click a square, type a digit; 0 clears it. Arrows move. Q quits.");
      (* the pointer and the keys *)
      if ui.Gui.clicked then begin
        let c = (ui.Gui.mx - ox) / cell and r = (ui.Gui.my - oy) / cell in
        if ui.Gui.mx >= ox && ui.Gui.my >= oy && r < 9 && c < 9 then st.sel <- r * 9 + c
      end;
      List.iter (fun k ->
          let r = st.sel / 9 and c = st.sel mod 9 in
          match k with
          | "q" | "Q" -> raise Gui.Quit
          | "\027[A" -> st.sel <- (r + 8) mod 9 * 9 + c
          | "\027[B" -> st.sel <- (r + 1) mod 9 * 9 + c
          | "\027[D" -> st.sel <- r * 9 + (c + 8) mod 9
          | "\027[C" -> st.sel <- r * 9 + (c + 1) mod 9
          | _ when st.finished <> None || st.given.(st.sel) -> ()
          | "0" | "\127" | "\b" | "\027[3~" | " " -> st.grid.(st.sel) <- 0
          | k when String.length k = 1 && k.[0] >= '1' && k.[0] <= '9' ->
            st.grid.(st.sel) <- Char.code k.[0] - 48;
            if complete st then st.finished <- Some (Mynos.uptime ())
          | _ -> ()) ui.Gui.keys;
      st)
