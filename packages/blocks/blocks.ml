(* blocks: falling blocks. Pieces of four squares fall into a well; fill
   a row and it goes. Left and Right move the piece, Up turns it, Down
   drops it faster, Space drops it at once; P pauses, N starts again, Q
   quits. Ten rows make a level, and each level falls faster. *)

let cols = 10 and rows = 20 and cell = 22
let width = 420 and height = 486
let wx = 16 and wy = 16                      (* the well's top left *)

(* the seven pieces, as squares (col, row) in a 4x4 box, and colours *)
let shapes = [|
  [ 0, 1; 1, 1; 2, 1; 3, 1 ], 0x26C6DA;       (* I *)
  [ 1, 0; 2, 0; 1, 1; 2, 1 ], 0xFFCA28;       (* O *)
  [ 1, 0; 0, 1; 1, 1; 2, 1 ], 0xAB47BC;       (* T *)
  [ 1, 0; 2, 0; 0, 1; 1, 1 ], 0x66BB6A;       (* S *)
  [ 0, 0; 1, 0; 1, 1; 2, 1 ], 0xEF5350;       (* Z *)
  [ 0, 0; 0, 1; 1, 1; 2, 1 ], 0x42A5F5;       (* J *)
  [ 2, 0; 0, 1; 1, 1; 2, 1 ], 0xFFA726;       (* L *)
|]

type piece = { kind : int; squares : (int * int) list; x : int; y : int }

type game = {
  well : int array array;                    (* [row].(col): 0 empty, else a colour *)
  mutable piece : piece;
  mutable next : int;
  mutable bag : int list;
  mutable score : int;
  mutable lines : int;
  mutable fall_at : float;                   (* when the piece falls a row *)
  mutable over : bool;
  mutable paused : bool;
  mutable flash : (int list * float) option; (* rows just filled, until when *)
}

(* each of the seven in turn, in a random order: no long droughts *)
let rec draw_kind g =
  match g.bag with
  | k :: rest -> g.bag <- rest; k
  | [] ->
    let a = Array.init 7 Fun.id in
    for i = 6 downto 1 do
      let j = Random.int (i + 1) in let t = a.(i) in a.(i) <- a.(j); a.(j) <- t
    done;
    g.bag <- Array.to_list a; draw_kind g

let spawn kind = { kind; squares = fst shapes.(kind); x = 3; y = -1 }

let cells p = List.map (fun (c, r) -> (p.x + c, p.y + r)) p.squares

let fits g p =
  List.for_all (fun (c, r) ->
      c >= 0 && c < cols && r < rows && (r < 0 || g.well.(r).(c) = 0)) (cells p)

(* turned a quarter clockwise, within its box (the I and O in 4x4 and
   2x2, the others in 3x3) *)
let turn p =
  let n = match p.kind with 0 -> 4 | 1 -> 0 | _ -> 3 in
  if n = 0 then p
  else { p with squares = List.map (fun (c, r) -> (n - 1 - r, c)) p.squares }

let level g = g.lines / 10 + 1
let interval g = max 0.05 (0.8 *. (0.85 ** float (level g - 1)))

let fresh () =
  let g = { well = Array.make_matrix rows cols 0; piece = spawn 0; next = 0; bag = [];
            score = 0; lines = 0; fall_at = 0.; over = false; paused = false; flash = None } in
  g.piece <- spawn (draw_kind g);
  g.next <- draw_kind g;
  g.fall_at <- Mynos.uptime () +. interval g;
  g

(* the piece stays where it is: full rows go, the next piece comes *)
let settle g =
  List.iter (fun (c, r) ->
      if r >= 0 then g.well.(r).(c) <- snd shapes.(g.piece.kind)) (cells g.piece);
  if List.exists (fun (_, r) -> r < 0) (cells g.piece) then g.over <- true;
  let full = List.filter (fun r -> Array.for_all (( <> ) 0) g.well.(r)) (List.init rows Fun.id) in
  if full <> [] then begin
    g.flash <- Some (full, Mynos.uptime () +. 0.15);
    let kept = List.filter (fun r -> not (List.mem r full)) (List.init rows Fun.id) in
    let n = List.length full in
    let copy = Array.map Array.copy g.well in
    Array.iteri (fun i _ -> g.well.(i) <- Array.make cols 0) g.well;
    List.iteri (fun i r -> g.well.(i + n) <- copy.(r)) kept;
    g.score <- g.score + [| 0; 100; 300; 500; 800 |].(n) * level g;
    g.lines <- g.lines + n
  end;
  if not g.over then begin
    g.piece <- spawn g.next;
    g.next <- draw_kind g;
    if not (fits g g.piece) then g.over <- true
  end

let move g dx dy =
  let p = { g.piece with x = g.piece.x + dx; y = g.piece.y + dy } in
  if fits g p then (g.piece <- p; true) else false

let rotate g =
  let p = turn g.piece in
  (* against a wall or a block: tried one or two squares aside *)
  match List.find_opt (fun dx -> fits g { p with x = p.x + dx }) [ 0; -1; 1; -2; 2 ] with
  | Some dx -> g.piece <- { p with x = p.x + dx }
  | None -> ()

let drop g =
  let n = ref 0 in
  while move g 0 1 do incr n done;
  g.score <- g.score + 2 * !n;
  settle g;
  g.fall_at <- Mynos.uptime () +. interval g

(* {1 Drawing} *)

let square gx x y colour =
  Gfx.fill gx x y (cell - 1) (cell - 1) colour;
  Gfx.fill gx x y (cell - 1) 3 (Gfx.mix colour 0xFFFFFF 0.35);
  Gfx.fill gx x (y + cell - 4) (cell - 1) 3 (Gfx.mix colour 0x000000 0.25)

let draw ui g =
  let gx = ui.Gui.g in
  Gfx.fill gx 0 0 width height 0x1B2733;
  Gfx.fill gx (wx - 2) (wy - 2) (cols * cell + 4) (rows * cell + 4) 0x5C6F82;
  Gfx.fill gx wx wy (cols * cell) (rows * cell) 0x0F1720;
  let flashing = match g.flash with
    | Some (rs, until) when Mynos.uptime () < until -> rs
    | _ -> [] in
  Array.iteri (fun r row -> Array.iteri (fun c v ->
      if v <> 0 then square gx (wx + c * cell) (wy + r * cell) v) row) g.well;
  List.iter (fun r -> Gfx.fill gx wx (wy + r * cell) (cols * cell) cell 0xFFFFFF) flashing;
  if not g.over then begin
    (* where it would land *)
    let ghost = ref g.piece in
    while fits g { !ghost with y = !ghost.y + 1 } do ghost := { !ghost with y = !ghost.y + 1 } done;
    List.iter (fun (c, r) ->
        if r >= 0 then Gfx.rect gx (wx + c * cell) (wy + r * cell) (cell - 1) (cell - 1) 0x546E7A)
      (cells !ghost);
    List.iter (fun (c, r) ->
        if r >= 0 then square gx (wx + c * cell) (wy + r * cell) (snd shapes.(g.piece.kind)))
      (cells g.piece)
  end;
  (* the side: next, score *)
  let sx = wx + cols * cell + 24 in
  let text y s = ignore (Gfx.text gx sx y s 0xCFD8DC) in
  let bold y s = ignore (Gfx.text ~bold:true gx sx y s 0xFFFFFF) in
  bold 16 "Next";
  List.iter (fun (c, r) -> square gx (sx + c * cell) (40 + r * cell) (snd shapes.(g.next)))
    (fst shapes.(g.next));
  bold 110 "Score"; text 130 (string_of_int g.score);
  bold 160 "Lines"; text 180 (string_of_int g.lines);
  bold 210 "Level"; text 230 (string_of_int (level g));
  List.iteri (fun i s -> ignore (Gfx.text gx sx (300 + i * 18) s 0x90A4AE))
    [ "Left Right  move"; "Up          turn"; "Down        faster"; "Space       drop";
      "P pause  N new"; "Q quit" ];
  let banner s =
    Gfx.fill gx wx (wy + 190) (cols * cell) 60 0x263238;
    ignore (Gfx.text ~bold:true gx (wx + (cols * cell - Gfx.char_w * String.length s) / 2) (wy + 200) s 0xFFFFFF);
    let t = "N starts again" in
    if g.over then
      ignore (Gfx.text gx (wx + (cols * cell - Gfx.char_w * String.length t) / 2) (wy + 222) t 0xB0BEC5) in
  if g.over then banner "Game over" else if g.paused then banner "Paused"

let () =
  Random.self_init ();
  Gui.run ~title:"Blocks" ~tick:0.03 width height (fresh ()) (fun ui g ->
      let g = ref g in
      List.iter (fun k ->
          match k with
          | "q" | "Q" -> raise Gui.Quit
          | "n" | "N" -> g := fresh ()
          | "p" | "P" when not !g.over ->
            !g.paused <- not !g.paused;
            !g.fall_at <- Mynos.uptime () +. interval !g
          | _ when !g.over || !g.paused -> ()
          | "\027[D" -> ignore (move !g (-1) 0)
          | "\027[C" -> ignore (move !g 1 0)
          | "\027[A" -> rotate !g
          | "\027[B" ->
            if move !g 0 1 then begin
              !g.score <- !g.score + 1; !g.fall_at <- Mynos.uptime () +. interval !g
            end
          | " " -> drop !g
          | _ -> ()) ui.Gui.keys;
      let g = !g in
      if not g.over && not g.paused && Mynos.uptime () >= g.fall_at then begin
        if not (move g 0 1) then settle g;
        g.fall_at <- Mynos.uptime () +. interval g
      end;
      draw ui g;
      g)
