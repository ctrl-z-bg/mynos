(* snake: a snake that grows with each apple it eats, and must not bite
   itself or the walls. The arrows turn it; P pauses, N starts again, Q
   quits. It goes faster as it grows. *)

let cols = 28 and rows = 20 and cell = 20
let width = cols * cell + 32 and height = rows * cell + 70
let ox = 16 and oy = 54

type dir = Up | Down | Left | Right

type game = {
  mutable body : (int * int) list;          (* the head first *)
  mutable dir : dir;
  mutable turns : dir list;                 (* typed, one taken a step *)
  mutable apple : int * int;
  mutable grow : int;
  mutable score : int;
  mutable best : int;
  mutable step_at : float;
  mutable over : bool;
  mutable paused : bool;
  mutable started : bool;                   (* at the first arrow *)
}

let rec place_apple g =
  let a = (Random.int cols, Random.int rows) in
  if List.mem a g.body then place_apple g else g.apple <- a

let fresh best =
  let g = { body = [ (8, 10); (7, 10); (6, 10) ]; dir = Right; turns = []; apple = (0, 0);
            grow = 0; score = 0; best; step_at = Mynos.uptime (); over = false; paused = false;
            started = false } in
  place_apple g; g

let interval g = max 0.06 (0.16 -. 0.004 *. float (List.length g.body))

let opposite = function Up -> Down | Down -> Up | Left -> Right | Right -> Left

let step g =
  (match g.turns with
   | d :: rest -> g.turns <- rest; if d <> opposite g.dir then g.dir <- d
   | [] -> ());
  let (x, y) = List.hd g.body in
  let head = match g.dir with
    | Up -> (x, y - 1) | Down -> (x, y + 1) | Left -> (x - 1, y) | Right -> (x + 1, y) in
  let (hx, hy) = head in
  (* the tail moves away in this step, unless the snake grows *)
  let body = if g.grow > 0 then g.body else List.filteri (fun i _ -> i < List.length g.body - 1) g.body in
  if hx < 0 || hy < 0 || hx >= cols || hy >= rows || List.mem head body then begin
    g.over <- true; g.best <- max g.best g.score
  end else begin
    g.body <- head :: body;
    if g.grow > 0 then g.grow <- g.grow - 1;
    if head = g.apple then begin
      g.score <- g.score + 10; g.grow <- g.grow + 3; place_apple g
    end
  end

let draw ui g =
  let gx = ui.Gui.g in
  Gfx.fill gx 0 0 width height 0x1E2A22;
  Gfx.fill gx (ox - 2) (oy - 2) (cols * cell + 4) (rows * cell + 4) 0x4E6B55;
  for r = 0 to rows - 1 do
    for c = 0 to cols - 1 do
      Gfx.fill gx (ox + c * cell) (oy + r * cell) cell cell
        (if (r + c) mod 2 = 0 then 0x2E4434 else 0x2A3F30)
    done
  done;
  let (ax, ay) = g.apple in
  Gfx.fill gx (ox + ax * cell + 4) (oy + ay * cell + 4) (cell - 8) (cell - 8) 0xE53935;
  Gfx.fill gx (ox + ax * cell + 9) (oy + ay * cell + 1) 2 5 0x6D4C41;
  let n = List.length g.body in
  List.iteri (fun i (x, y) ->
      let colour = Gfx.mix 0x9CCC65 0x33691E (float i /. float (max 1 n)) in
      Gfx.fill gx (ox + x * cell + 1) (oy + y * cell + 1) (cell - 2) (cell - 2) colour) g.body;
  (* the eyes *)
  let (hx, hy) = List.hd g.body in
  let ex, ey = ox + hx * cell, oy + hy * cell in
  let eyes = match g.dir with
    | Right -> [ (13, 5); (13, 12) ] | Left -> [ (4, 5); (4, 12) ]
    | Up -> [ (5, 4); (12, 4) ] | Down -> [ (5, 13); (12, 13) ] in
  List.iter (fun (dx, dy) -> Gfx.fill gx (ex + dx) (ey + dy) 3 3 0x102010) eyes;
  let t s x = ignore (Gfx.text ~bold:true gx x 18 s 0xE8F5E9) in
  t (Printf.sprintf "Score %d" g.score) ox;
  t (Printf.sprintf "Best %d" g.best) (ox + 140);
  ignore (Gfx.text gx (ox + 270) 18 "Arrows  P pause  N new  Q quit" 0x9EB8A3);
  let banner s sub =
    let bw = 300 in
    let bx = ox + (cols * cell - bw) / 2 and by = oy + rows * cell / 2 - 30 in
    Gfx.fill gx bx by bw 60 0x16201A;
    ignore (Gfx.text ~bold:true gx (bx + (bw - Gfx.char_w * String.length s) / 2) (by + 12) s 0xFFFFFF);
    ignore (Gfx.text gx (bx + (bw - Gfx.char_w * String.length sub) / 2) (by + 34) sub 0xA5D6A7) in
  if g.over then banner "Game over" "N starts again"
  else if g.paused then banner "Paused" "P goes on"
  else if not g.started then banner "Snake" "An arrow starts"

let () =
  Random.self_init ();
  Gui.run ~title:"Snake" ~tick:0.02 width height (fresh 0) (fun ui g ->
      let g = ref g in
      List.iter (fun k ->
          let turn d =
            if not !g.started then begin
              !g.started <- true; !g.step_at <- Mynos.uptime ()
            end;
            if List.length !g.turns < 3 then !g.turns <- !g.turns @ [ d ] in
          match k with
          | "q" | "Q" -> raise Gui.Quit
          | "n" | "N" -> g := fresh !g.best
          | "p" | "P" -> !g.paused <- not !g.paused
          | "\027[A" -> turn Up | "\027[B" -> turn Down
          | "\027[C" -> turn Right | "\027[D" -> turn Left
          | _ -> ()) ui.Gui.keys;
      let g = !g in
      if g.started && not g.over && not g.paused && Mynos.uptime () >= g.step_at then begin
        step g; g.step_at <- Mynos.uptime () +. interval g
      end;
      draw ui g;
      g)
