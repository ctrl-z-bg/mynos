(* mines: find the mines of a field without stepping on one. A click
   opens a square, which tells how many mines are around it; the right
   button marks a mine (or the left one, with Flags on: for a touchpad).
   A click on an open number whose mines are all marked opens the squares
   around it. The first square opened is never a mine. Keys: 1 2 3 the
   levels, N a new game, F flags, Q quits. *)

let cell = 24
let width = 744 and height = 476
let top = 64                                    (* the field's top *)

type level = { label : string; cols : int; rows : int; mines : int }
let levels = [| { label = "Easy"; cols = 9; rows = 9; mines = 10 };
                { label = "Medium"; cols = 16; rows = 16; mines = 40 };
                { label = "Hard"; cols = 30; rows = 16; mines = 99 } |]

type square = { mutable mine : bool; mutable opened : bool; mutable flag : bool; mutable around : int }
type phase = Ready | Playing | Won | Lost

type game = {
  level : level;
  field : square array array;          (* [row].(col) *)
  mutable phase : phase;
  mutable started : float;
  mutable ended : float;
  mutable flags_mode : bool;
  mutable prev_buttons : int;          (* to see the right button released *)
  mutable boom : int * int;
}

let make level =
  { level; field = Array.init level.rows (fun _ -> Array.init level.cols (fun _ ->
        { mine = false; opened = false; flag = false; around = 0 }));
    phase = Ready; started = 0.; ended = 0.; flags_mode = false; prev_buttons = 0;
    boom = (-1, -1) }

let neighbours g r c =
  List.filter (fun (r, c) -> r >= 0 && c >= 0 && r < g.level.rows && c < g.level.cols)
    (List.concat_map (fun dr -> List.filter_map (fun dc ->
         if dr = 0 && dc = 0 then None else Some (r + dr, c + dc)) [ -1; 0; 1 ]) [ -1; 0; 1 ])

(* the mines, away from the first square opened and its neighbours *)
let lay g r0 c0 =
  let safe = (r0, c0) :: neighbours g r0 c0 in
  let free = ref [] in
  Array.iteri (fun r row -> Array.iteri (fun c _ ->
      if not (List.mem (r, c) safe) then free := (r, c) :: !free) row) g.field;
  let free = Array.of_list !free in
  for i = 0 to g.level.mines - 1 do
    let j = i + Random.int (Array.length free - i) in
    let t = free.(i) in free.(i) <- free.(j); free.(j) <- t;
    let (r, c) = free.(i) in g.field.(r).(c).mine <- true
  done;
  Array.iteri (fun r row -> Array.iteri (fun c s ->
      s.around <- List.length (List.filter (fun (r, c) -> g.field.(r).(c).mine)
                                 (neighbours g r c))) row) g.field

let rec open_square g r c =
  let s = g.field.(r).(c) in
  if not s.opened && not s.flag then begin
    s.opened <- true;
    if s.mine then begin g.phase <- Lost; g.boom <- (r, c); g.ended <- Mynos.uptime () end
    else if s.around = 0 then List.iter (fun (r, c) -> open_square g r c) (neighbours g r c)
  end

let check_won g =
  if g.phase = Playing
  && Array.for_all (Array.for_all (fun s -> s.mine || s.opened)) g.field then begin
    g.phase <- Won; g.ended <- Mynos.uptime ();
    Array.iter (Array.iter (fun s -> if s.mine then s.flag <- true)) g.field
  end

let left g r c =
  match g.phase with
  | Won | Lost -> ()
  | Ready | Playing ->
    if g.phase = Ready then begin
      lay g r c; g.phase <- Playing; g.started <- Mynos.uptime ()
    end;
    let s = g.field.(r).(c) in
    if s.opened && s.around > 0 then begin
      (* its mines all marked: the others around it open *)
      let ns = neighbours g r c in
      if List.length (List.filter (fun (r, c) -> g.field.(r).(c).flag) ns) = s.around then
        List.iter (fun (r, c) -> open_square g r c) ns
    end else open_square g r c;
    check_won g

let right g r c =
  if g.phase = Playing || g.phase = Ready then begin
    let s = g.field.(r).(c) in
    if not s.opened then s.flag <- not s.flag
  end

(* {1 Drawing} *)

let colours = [| 0; 0x1565C0; 0x2E7D32; 0xC62828; 0x283593; 0x6D4C41; 0x00838F; 0x212121; 0x757575 |]

let origin g = ((width - g.level.cols * cell) / 2, top)

let square_at g ui =
  let ox, oy = origin g in
  let c = (ui.Gui.mx - ox) / cell and r = (ui.Gui.my - oy) / cell in
  if ui.Gui.mx >= ox && ui.Gui.my >= oy && r < g.level.rows && c < g.level.cols then Some (r, c)
  else None

let draw ui g =
  let gx = ui.Gui.g in
  let ox, oy = origin g in
  Array.iteri (fun r row -> Array.iteri (fun c s ->
      let x = ox + c * cell and y = oy + r * cell in
      let shown_mine = s.mine && (g.phase = Lost || g.phase = Won) in
      if s.opened || (shown_mine && not s.flag) then begin
        Gfx.fill gx x y cell cell (if (r, c) = g.boom then 0xEF9A9A else 0xEEF1F4);
        Gfx.rect gx x y cell cell 0xCFD6DD;
        if s.mine then begin
          Gfx.fill gx (x + 7) (y + 7) 10 10 0x263238;
          Gfx.fill gx (x + 11) (y + 4) 2 16 0x263238;
          Gfx.fill gx (x + 4) (y + 11) 16 2 0x263238
        end else if s.around > 0 then
          ignore (Gfx.text ~bold:true gx (x + 8) (y + 4) (string_of_int s.around) colours.(s.around))
      end else begin
        let hover = Gui.hovered ui x y cell cell && (g.phase = Ready || g.phase = Playing) in
        Gfx.fill gx x y cell cell (if hover then 0x9DB8D2 else 0xB0BEC5);
        Gfx.fill gx x y cell 2 0xCFD8DC; Gfx.fill gx x y 2 cell 0xCFD8DC;
        Gfx.fill gx x (y + cell - 2) cell 2 0x78909C; Gfx.fill gx (x + cell - 2) y 2 cell 0x78909C;
        if s.flag then begin
          let wrong = g.phase = Lost && not s.mine in
          Gfx.fill gx (x + 11) (y + 5) 2 14 0x37474F;
          Gfx.fill gx (x + 6) (y + 5) 6 6 (if wrong then 0x37474F else 0xD32F2F);
          Gfx.fill gx (x + 7) (y + 18) 10 2 0x37474F
        end
      end) row) g.field

let () =
  Random.self_init ();
  Gui.run ~title:"Mines" ~tick:1.0 width height (make levels.(1)) (fun ui g ->
      let g = ref g in
      let restart l = g := make l in
      (* the bar: the levels, flags, the counts *)
      Array.iteri (fun i l ->
          if Gui.button ui (12 + i * 92) 14 84 l.label then restart l) levels;
      if Gui.button ui 300 14 104 (if !g.flags_mode then "Flags: on" else "Flags: off") then
        !g.flags_mode <- not !g.flags_mode;
      let flags = Array.fold_left (fun a row ->
          Array.fold_left (fun a s -> if s.flag then a + 1 else a) a row) 0 !g.field in
      let secs = match !g.phase with
        | Ready -> 0
        | Playing -> int_of_float (Mynos.uptime () -. !g.started)
        | Won | Lost -> int_of_float (!g.ended -. !g.started) in
      Gui.label ui 424 22 (Printf.sprintf "Mines %d" (!g.level.mines - flags));
      Gui.label ui 528 22 (Printf.sprintf "Time %d" secs);
      (match !g.phase with
       | Won -> Gui.label ~bold:true ~colour:0x2E7D32 ui 626 22 "Cleared!"
       | Lost -> Gui.label ~bold:true ~colour:0xC62828 ui 626 22 "Boom."
       | _ -> ());
      draw ui !g;
      let oy = top + !g.level.rows * cell in
      Gui.label ~colour:Gui.muted ui 12 (max (oy + 10) (height - 26))
        "Left: open   Right (or Flags on): mark a mine   N: new   1 2 3: level   Q: quit";
      (* the pointer *)
      let right_up = !g.prev_buttons land 2 <> 0 && ui.Gui.buttons land 2 = 0 in
      !g.prev_buttons <- ui.Gui.buttons;
      (match square_at !g ui with
       | Some (r, c) when ui.Gui.clicked ->
         if !g.flags_mode then right !g r c else left !g r c
       | Some (r, c) when right_up -> right !g r c
       | _ -> ());
      List.iter (function
          | "q" | "Q" -> raise Gui.Quit
          | "n" | "N" -> restart !g.level
          | "f" | "F" -> !g.flags_mode <- not !g.flags_mode
          | "1" -> restart levels.(0) | "2" -> restart levels.(1) | "3" -> restart levels.(2)
          | _ -> ()) ui.Gui.keys;
      !g)
