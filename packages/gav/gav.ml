(* gav: GAV, GPL Arcade Volleyball, in OCaml for MyNOS.

   A port of GAV (https://github.com/ctrl-z-bg/gav, C++ and SDL, 2002-),
   a remake of the DOS game Arcade Volleyball: its physics, its players,
   its computer players and its "classic" pictures, in a window of
   640 x 400. One or two players a side, each a person at the keyboard or
   the computer: 1 against the computer, 1 against 1, 2 against 2.

     Left 1:  z c, x to jump        Right 1: the arrows, Up to jump
     Left 2:  h k, u to jump        Right 2: s f, e to jump
     Escape: back to the players' choice.

   Points as in the original: only the side that serves scores; 15 to
   win, by two. The game runs in steps of 20 ms (GAV's 50 a second),
   whatever the window's pace. *)

(* ---- the field (GAV's Configuration, at 640 x 400) ---- *)

let sw = 640 and sh = 400
let speedy = float sh /. 2.5
let floor_ord = sh - sh / 200
let net_x = sw / 2 - sw / 80
let net_y = sh / 2 + 3 * sh / 200
let ceiling = sh / 17
let left_wall = sw / 80
let right_wall = sw - sw / 40
let default_speed = 25 * sw / 64
let ball_amplify = 5.
let elastic = 0.8
let gravity = 250
let max_touches = 3
let pi = 3.14158
let jump_limit = int_of_float (float sh /. 1.82)
let jumping_time = 150
let winning_score = 15
let step_ms = 20

(* ---- pictures: frames side by side, black is transparent ---- *)

type sprite = { w : int; h : int; frames : int; iw : int; pix : int array }

let dir = "/disk/pkg/gav"

let load name frames =
  let path = if Sys.file_exists (Filename.concat dir name) then Filename.concat dir name else name in
  let img = Png.read (In_channel.with_open_bin path In_channel.input_all) in
  { w = img.Image.width / frames; h = img.height; frames; iw = img.width; pix = img.pixels }

let pixel s idx x y = s.pix.(y * s.iw + (idx mod s.frames) * s.w + x)

let draw (g : Gfx.t) s idx x0 y0 =
  for y = max 0 (- y0) to min s.h (g.height - y0) - 1 do
    for x = max 0 (- x0) to min s.w (g.width - x0) - 1 do
      let p = pixel s idx x y in
      if p <> 0 then
        Bigarray.Array1.unsafe_set g.pixels ((y0 + y) * g.width + x0 + x) (Int32.of_int p)
    done
  done

(* two frames overlap where both are not black *)
let collides s1 i1 x1 y1 s2 i2 x2 y2 =
  let xmin = max x1 x2 and xmax = min (x1 + s1.w) (x2 + s2.w) in
  let ymin = max y1 y2 and ymax = min (y1 + s1.h) (y2 + s2.h) in
  if xmin > xmax || ymin > ymax then false
  else begin
    let hit = ref false and y = ref ymin in
    while not !hit && !y < ymax do
      let x = ref xmin in
      while not !hit && !x < xmax do
        if pixel s1 i1 (!x - x1) (!y - y1) <> 0 && pixel s2 i2 (!x - x2) (!y - y2) <> 0 then
          hit := true;
        incr x
      done;
      incr y
    done;
    !hit
  end

(* ---- sounds: a few tones, played by a domain of their own so that the
   game does not wait for the sound service ---- *)

let sounds = Queue.create ()
let sounds_lock = Mutex.create ()
let sounds_ready = Condition.create ()

(* a thread, not a domain: a second domain must join every minor
   collection, which in MyNOS slows the game (camlboy measured it) *)
let () =
  ignore (Thread.create (fun () ->
      let ok = ref true in
      while true do
        let hz, ms = Mutex.protect sounds_lock (fun () ->
            while Queue.is_empty sounds do Condition.wait sounds_ready sounds_lock done;
            Queue.pop sounds) in
        if !ok then (try Sound.tone hz ms with _ -> ok := false)
      done) ())

let sound hz ms =
  Mutex.protect sounds_lock (fun () ->
      if Queue.length sounds < 4 then Queue.push (hz, ms) sounds;
      Condition.signal sounds_ready)

(* ---- players and teams ---- *)

type state = Still | Walk | Jump
let state_index = function Still -> 0 | Walk -> 1 | Jump -> 2

type input = { left : bool; right : bool; jump : bool }
let nothing = { left = false; right = false; jump = false }

type player = {
  id : int;                       (* 0 and 2 on the left, 1 and 3 on the right *)
  team : team;
  ai : bool;
  sprite : sprite;
  speed : int;
  mutable x : int;
  mutable y : int;
  mutable speed_x : int;
  mutable speed_y : float;
  mutable state : state;
  mutable frame : int;
  mutable passed : int;
  mutable fb : int;               (* the state's first and last frames *)
  mutable fe : int;
  mutable delay : int;
  mutable dispx : float;
  mutable dispy : float;
  mutable oif : int;              (* the computer's slot in the field *)
}
and team = {
  side : int;                     (* -1 left, 1 right *)
  xmin : int;
  xmax : int;
  mutable score : int;
  mutable players : player list;
}

let ground p = floor_ord - p.sprite.h

let make_team side =
  let xmin = if side < 0 then left_wall + 1 else sw / 2 in
  { side; xmin; xmax = xmin + 304 * sw / 640; score = 0; players = [] }

let set_state ?(force = false) p st =
  if p.state = st && not force then false
  else begin
    p.state <- st;
    (match st with
     | Jump -> p.fb <- 3; p.fe <- 3; p.delay <- 0
     | Still -> p.fb <- 0; p.fe <- 0; p.delay <- 0
     | Walk -> p.fb <- 1; p.fe <- 2; p.delay <- 250 / (2 - 1));
    true
  end

let add_player team ~ai ~id sprite =
  let p = { id; team; ai; sprite; speed = default_speed; x = 0; y = 0; speed_x = 0;
            speed_y = 0.; state = Still; frame = 0; passed = 0; fb = 0; fe = 0; delay = 0;
            dispx = 0.; dispy = 0.; oif = -1 } in
  team.players <- team.players @ [ p ];
  let n = List.length team.players in
  List.iteri (fun i q -> q.x <- (i + 1) * (team.xmax + team.xmin) / (n + 1) - q.sprite.w / 2)
    team.players;
  p.y <- ground p

(* the speed the ball feels: none against the walls of the half field *)
let speed_x p =
  if p.speed_x > 0 && p.x < p.team.xmax - p.sprite.w then p.speed_x
  else if p.speed_x < 0 && p.x > p.team.xmin then p.speed_x
  else 0

let update_frame p ticks changed =
  p.passed <- p.passed + ticks;
  if changed then begin p.passed <- 0; p.frame <- p.fb end
  else if p.delay > 0 && p.passed > p.delay then begin
    p.frame <- (if p.frame + 1 > p.fe then p.fb else p.frame + 1);
    p.passed <- 0
  end

let update_player p ticks input =
  let first = p.passed = 0 in
  let dx = (if input.left then -1 else 0) + (if input.right then 1 else 0) in
  p.speed_x <- dx * p.speed;
  p.dispx <- p.dispx +. float dx *. (float p.speed *. float ticks /. 1000.);
  if Float.abs p.dispx >= 1. then begin
    p.x <- p.x + truncate p.dispx;
    p.dispx <- p.dispx -. Float.of_int (truncate p.dispx)
  end;
  if p.x > p.team.xmax - p.sprite.w then p.x <- p.team.xmax - p.sprite.w
  else if p.x < p.team.xmin then p.x <- p.team.xmin;
  if p.y = ground p && input.jump then p.speed_y <- -. speedy;
  if p.y > ground p then begin p.y <- ground p; p.speed_y <- 0. end;
  p.dispy <- p.speed_y *. 5. *. (float ticks /. 1000.);
  if Float.abs p.dispy >= 1. then begin
    p.y <- p.y + truncate p.dispy;
    p.dispy <- p.dispy -. Float.of_int (truncate p.dispy)
  end;
  if p.y < ground p then p.speed_y <- p.speed_y +. speedy *. 5. *. float ticks /. 1000.;
  let old = p.state in
  if p.y < ground p then ignore (set_state p Jump)
  else if first || dx = 0 then ignore (set_state ~force:first p Still)
  else ignore (set_state p Walk);
  update_frame p ticks (old <> p.state)

(* ---- the ball ---- *)

type ball = {
  bs : sprite;
  mutable bx : int;
  mutable by : int;
  mutable spdx : int;
  mutable spdy : int;
  mutable oldx : int;
  mutable oldy : int;
  mutable bframe : int;
  mutable bpassed : int;
  mutable accel_y : int;
  mutable bside : int;
  mutable scorer : int;
  mutable scored_time : int;
  touches : int array;              (* by team: 0 left, 1 right *)
  mutable touching : player option;
}

let radius b = b.bs.w / 2
let team_index t = if t.side < 0 then 0 else 1
let reset_touches b = Array.fill b.touches 0 2 0

let reset_ball b x y =
  b.bside <- -1; b.scorer <- 0; b.bx <- x; b.by <- y; b.spdx <- 0; b.spdy <- 0;
  b.accel_y <- 0; reset_touches b

let distance b x y =
  let cx = b.bx + b.bs.w / 2 and cy = b.by + b.bs.h / 2 in
  sqrt (float ((x - cx) * (x - cx) + (y - cy) * (y - cy)))

(* the ball's path from its last place crosses the net's line *)
let crossing b x y =
  let xmin = min x b.oldx and xmax = max x b.oldx in
  let ymin = min y b.oldy and ymax = max y b.oldy in
  if xmin < net_x && xmax > net_x then
    Some ((net_x - xmin) * (ymax - ymin) / (xmax - xmin) + ymin)
  else None

let net_partial b x y =
  (match crossing b x y with
   | Some cy -> cy < net_y && cy > net_y - b.bs.h / 2
   | None -> false)
  || (x + b.bs.w > net_x && x < net_x && distance b net_x net_y < float (b.bs.w / 2))

let net_full b x y =
  (match crossing b x y with Some cy -> cy > net_y | None -> false)
  || (x + b.bs.w > net_x && x < net_x && y + b.bs.h / 2 >= net_y)

let approaching b spdx spdy =
  let sgnx = compare spdx 0 and sgny = Float.compare spdy 0. in
  (spdx - b.spdx) * sgnx >= 0 || (spdy -. float b.spdy) *. float sgny >= 0.

let collide b p =
  approaching b (speed_x p) (-. p.speed_y)
  && collides p.sprite (state_index p.state) p.x p.y b.bs b.bframe b.bx b.by

(* a player hits the ball: its speed turned and given the player's *)
let hit b p =
  let cplx = p.x + p.sprite.w / 2 and cply = p.y + p.sprite.h / 2 in
  let cbx = b.bx + b.bs.w / 2 and cby = b.by + b.bs.h / 2 in
  let dx = cplx - cbx and dy = cply - cby in
  let beta = if dx <> 0 then atan (float dy /. float dx) else pi /. 2. in
  let sinb = sin (-. beta) and cosb = cos (-. beta) in
  if b.spdy = 0 && b.spdx = 0 then b.spdy <- -200;           (* the service *)
  let y1 = float b.spdx *. sinb +. float (- b.spdy) *. cosb in
  let x1 = ball_amplify *. (float (speed_x p) *. cosb -. p.speed_y *. sinb) in
  let oldspdy = b.spdy in
  b.spdx <- truncate (x1 *. cos beta -. y1 *. sin beta);
  b.spdy <- truncate (-. (x1 *. sin beta +. y1 *. cos beta));
  if (speed_x p - b.spdx) * dx < 0 then b.spdx <- speed_x p;
  if (p.speed_y -. float b.spdy) *. float dy > 0. then b.spdy <- truncate p.speed_y;
  if b.spdy < 100 && cby < cply then b.spdy <- truncate (1.1 *. elastic *. float (abs oldspdy))

let debug = Sys.getenv_opt "GAV_DEBUG" <> None
let log fmt = Printf.ksprintf (fun s -> if debug then Mynos.log ("gav: " ^ s)) fmt

let assign_point b side team =
  log "point to the %s (it served: %b)" (if side < 0 then "left" else "right") (b.bside = side);
  if b.bside = side then begin team.score <- team.score + 1; sound 660 120 end
  else sound 330 80;
  b.bside <- side;
  b.bx <- net_x + side * (sw / 4) - radius b;
  b.by <- sh * 2 / 3 - radius b;
  b.spdx <- 0; b.spdy <- 0; b.accel_y <- 0; b.scorer <- 0;
  reset_touches b

(* out of a player: step by step, away from it, not into the net *)
let push_out b p =
  let n = ref 0 in
  while collide b p && !n < 400 do
    incr n;
    let nx = b.bx + (if b.spdx > 0 then 1 else -1) in
    b.by <- b.by - (if b.spdy > 0 then 1 else -1);
    if not (net_full b nx b.by) && not (net_partial b nx b.by) then b.bx <- nx
  done

let update_ball b passed tl tr =
  b.bpassed <- b.bpassed + passed;
  if b.bpassed > 1000 / b.bs.frames then begin
    b.bpassed <- 0; b.bframe <- (b.bframe + 1) mod b.bs.frames
  end;
  b.oldx <- b.bx; b.oldy <- b.by;
  (* a point waits 650 ms after the ball has touched the floor; the ball
     goes on meanwhile *)
  let scored =
    b.scorer <> 0
    && (b.scored_time <- b.scored_time + passed;
        b.scored_time > 650) in
  if scored then assign_point b b.scorer (if b.scorer < 0 then tl else tr)
  else begin
    if not (net_partial b b.bx b.by) then b.spdy <- b.spdy - b.accel_y * passed / 1000;
    b.bx <- b.bx + truncate (float b.spdx *. (float passed /. 1000.));
    b.by <- b.by - truncate (float b.spdy *. (float passed /. 1000.));
    let w = b.bs.w and h = b.bs.h in
    if b.by < ceiling then begin
      b.by <- ceiling; b.spdy <- - (truncate (float b.spdy *. elastic)); sound 220 30
    end;
    if b.bx < left_wall then begin
      b.bx <- left_wall; b.spdx <- - (truncate (float b.spdx *. elastic));
      if b.touches.(1) > 0 then reset_touches b;
      sound 220 30
    end;
    if b.bx > right_wall - w then begin
      b.bx <- right_wall - w; b.spdx <- - (truncate (float b.spdx *. elastic));
      if b.touches.(0) > 0 then reset_touches b;
      sound 220 30
    end;
    if net_full b b.bx b.by && not (net_full b b.oldx b.oldy) then begin
      b.spdx <- truncate (float (- b.spdx) *. elastic);
      b.bx <- (if b.oldx > b.bx then 2 * net_x - b.bx else 2 * net_x - 2 * w - b.bx);
      sound 150 40
    end else if net_partial b b.bx b.by then begin
      if not (net_partial b b.oldx (net_y - 3 * h / 4)) then begin
        if b.oldy < b.by && b.bx + w / 8 < net_x && b.bx + 7 * w / 8 > net_x then
          b.spdx <- - b.spdx;
        b.spdx <- truncate (float b.spdx *. elastic *. elastic *. elastic)
      end;
      b.by <- b.by - h / 4;
      b.spdy <- truncate (Float.abs (float b.spdy *. elastic *. elastic));
      if b.bx = b.oldx then b.bx <- b.bx + (if b.spdx > 0 then 5 else -5);
      sound 180 30
    end;
    if b.by > floor_ord - h then begin
      b.by <- floor_ord - h;
      b.spdy <- - (truncate (float b.spdy *. elastic));
      if b.scorer = 0 then begin
        b.scorer <- (if b.oldx < net_x then 1 else -1); b.scored_time <- 0
      end;
      sound 200 40
    end;
    List.iter (fun team ->
        List.iter (fun p ->
            if b.scorer = 0 then begin
              if collide b p then begin
                if (match b.touching with Some q -> q != p | None -> true) then begin
                  b.touching <- Some p;
                  let k = team_index team in
                  if b.touches.(k) = 0 then reset_touches b;
                  b.touches.(k) <- b.touches.(k) + 1;
                  sound 440 40;
                  if b.touches.(k) > max_touches then begin
                    b.scorer <- (if team.side < 0 then 1 else -1); b.scored_time <- 0
                  end;
                  hit b p
                end;
                push_out b p
              end else if (match b.touching with Some q -> q == p | None -> false) then
                b.touching <- None
            end) team.players) [ tl; tr ];
    if b.accel_y = 0 && abs b.spdx + abs b.spdy > 0 then b.accel_y <- gravity
  end

(* ---- the computer's players (GAV's PlayerAI) ---- *)

let plan p b =
  let team = p.team in
  let side = team.side and nplrs = List.length team.players in
  let maxx = team.xmax and minx = team.xmin and w = p.sprite.w and r = radius b in
  let net = abs (maxx - minx) in
  let mp = net / 2 in
  let rel x = if side > 0 then maxx - x else x - minx in
  let px = rel (p.x + w / 2) and bx = rel (r + b.bx) in
  let ttime = ref 1000 in
  let xt =
    if b.accel_y = 0 then rel (r / 2 + b.bx)
    else begin
      (* where the ball will come down, below 240 *)
      let ex = ref b.bx and ey = ref b.by and sx = ref b.spdx and sy = ref b.spdy in
      ttime := 0;
      let n = ref 0 in
      while !ey < 240 && !n < 500 do
        incr n;
        let ppx = !ex and ppy = !ey in
        ttime := !ttime + 20;
        ex := !ex + truncate (float !sx *. 0.02);
        ey := !ey - truncate (float !sy *. 0.02);
        sy := truncate (float !sy -. 20. *. float b.accel_y /. 1000.);
        if !ey < ceiling then begin ey := ceiling; sy := - (truncate (float !sy *. elastic)) end;
        if !ex < left_wall then begin ex := left_wall; sx := - (truncate (float !sx *. elastic)) end;
        if !ex > right_wall - 2 * r then begin
          ex := right_wall - 2 * r; sx := - (truncate (float !sx *. elastic))
        end;
        let mx = min !ex ppx in
        if mx > net_x - 2 * r && mx < net_x && (!ey > net_y || ppy > net_y) then begin
          ex := (if mx = !ex then net_x - 2 * r else net_x);
          sx := - (truncate (float !sx *. elastic));
          if !sx = 0 then sx := side * 20
        end
      done;
      rel (!ex + r)
    end in
  let slotsize = float (net / nplrs) in
  let mypos =
    if nplrs > 1 then begin
      if p.oif < 0 then List.iteri (fun i q -> q.oif <- i) team.players;
      let mypos = truncate (slotsize *. (float p.oif +. 0.5)) in
      let closer = ref None and best = ref net in
      List.iter (fun q ->
          let opx = rel (q.x + q.sprite.w / 2) in
          if q.id <> p.id && abs (opx - mypos) < !best then begin
            closer := Some q; best := abs (opx - mypos)
          end) team.players;
      (match !closer with
       | Some q when float !best < slotsize *. 0.35 ->
         let mine = q.oif in q.oif <- p.oif; p.oif <- mine
       | _ -> ());
      truncate (slotsize *. (float p.oif +. 0.5))
    end else mp - 50 in
  let hd = ref ((r + w) / 2) and minhd = ref 0 in
  if b.accel_y = 0 then begin
    if !hd / 2 >= 12 then minhd := Random.int (!hd / 2 - 10) + 10;
    hd := Random.int (max 1 (!hd - !minhd)) + !minhd + 1
  end;
  let closest =
    b.accel_y <> 0
    || List.for_all (fun q -> not (abs (px - xt) > abs (rel (q.x + q.sprite.w / 2) - xt)))
      team.players in
  let jmp = ref (
      if b.accel_y <> 0 then
        abs (px - bx) <= !hd && b.by > (if b.spdy > 20 then jump_limit else jump_limit + 20)
      else !minhd < bx - px && bx - px <= !hd) in
  let concern = if nplrs > 1 then slotsize *. 1.05 else slotsize in
  let move =
    if float (abs (xt - mypos)) < concern && closest then begin
      if !ttime < jumping_time then begin jmp := true; bx - px end
      else if b.accel_y <> 0 then xt - !hd - px
      else bx - !hd - px
    end else mypos - px in
  let move = - side * move in
  { left = abs move > 2 && move < 0; right = abs move > 2 && move > 0; jump = !jmp }

(* ---- the keys of the four places ---- *)

let keys = [|
  ([ "z"; "Z" ], [ "c"; "C" ], [ "x"; "X" ]);                    (* left 1 *)
  ([ "\027[D" ], [ "\027[C" ], [ "\027[A" ]);                     (* right 1 *)
  ([ "h"; "H" ], [ "k"; "K" ], [ "u"; "U" ]);                     (* left 2 *)
  ([ "s"; "S" ], [ "f"; "F" ], [ "e"; "E" ]);                     (* right 2 *)
|]
let key_names = [| "z c, x jumps"; "arrows, Up jumps"; "h k, u jumps"; "s f, e jumps" |]

let human_input ui id =
  let l, r, j = keys.(id) in
  let down ks = List.exists (fun k -> List.mem k ui.Gui.held) ks in
  { left = down l; right = down r; jump = down j }

(* ---- the game ---- *)

type place = Nobody | Person | Computer
let place_name = function Nobody -> "nobody" | Person -> "keyboard" | Computer -> "computer"

type game = {
  tl : team;
  tr : team;
  ball : ball;
  mutable last : float;
  mutable pending : float;          (* ms not yet stepped *)
  mutable winner : string option;
}

type screen = Choosing | Playing of game

type st = {
  places : place array;             (* left 1, right 1, left 2, right 2 *)
  mutable screen : screen;
}

let new_game places sprites =
  let pl_l, pl_r, ball_s = sprites in
  let tl = make_team (-1) and tr = make_team 1 in
  Array.iteri (fun id place ->
      let team = if id mod 2 = 0 then tl else tr in
      match place with
      | Nobody -> ()
      | Person -> add_player team ~ai:false ~id (if id mod 2 = 0 then pl_l else pl_r)
      | Computer -> add_player team ~ai:true ~id (if id mod 2 = 0 then pl_l else pl_r))
    places;
  let ball = { bs = ball_s; bx = 0; by = 0; spdx = 0; spdy = 0; oldx = 0; oldy = 0; bframe = 0;
               bpassed = 0; accel_y = 0; bside = -1; scorer = 0; scored_time = 0;
               touches = [| 0; 0 |]; touching = None } in
  reset_ball ball (truncate (float sw *. 0.25)) (truncate (float sh *. 0.66));
  { tl; tr; ball; last = Mynos.uptime (); pending = 0.; winner = None }

let steps = ref 0

let step ui g =
  incr steps;
  if !steps mod 50 = 0 then
    log "ball %d,%d speed %d,%d gravity %d; score %d-%d" g.ball.bx g.ball.by g.ball.spdx
      g.ball.spdy g.ball.accel_y g.tl.score g.tr.score;
  let inputs p = if p.ai then plan p g.ball else human_input ui p.id in
  List.iter (fun t -> List.iter (fun p -> update_player p step_ms (inputs p)) t.players)
    [ g.tl; g.tr ];
  update_ball g.ball step_ms g.tl g.tr;
  let won a b = a.score >= winning_score && a.score > b.score + 1 in
  if won g.tl g.tr then g.winner <- Some "The left side wins"
  else if won g.tr g.tl then g.winner <- Some "The right side wins";
  if g.winner <> None then begin sound 523 150; sound 659 150; sound 784 300 end

let () =
  Random.self_init ();
  let bg = load "background.png" 1 and font = load "font.png" 104 in
  let sprites = (load "plml.png" 4, load "plmr.png" 4, load "ball.png" 4) in
  (* the background, once, as pixels to copy *)
  let back = Gfx.create sw sh in
  Array.iteri (fun i p -> Bigarray.Array1.unsafe_set back.pixels i (Int32.of_int p)) bg.pix;
  let text g x y s =
    String.iteri (fun i c ->
        let k = Char.code c - 32 in
        if k >= 0 && k < 104 then draw g font k (x + i * font.w) y) s in
  let centre g y s = text g ((sw - String.length s * font.w) / 2) y s in
  let st = { places = [| Person; Computer; Nobody; Nobody |]; screen = Choosing } in
  Gui.run ~title:"GAV" ~tick:0.02 sw sh st (fun ui st ->
      let g = ui.Gui.g in
      Gfx.blit back 0 0 g 0 0 sw sh;
      (match st.screen with
       | Choosing ->
         centre g 40 "GPL ARCADE VOLLEYBALL";
         Gui.panel ui 120 80 400 250;
         Gui.label ~bold:true ui 136 92 "Who plays";
         let row i label y =
           Gui.label ui 136 (y + 5) label;
           let p = st.places.(i) in
           if Gui.button ui 236 y 110 (place_name p) then
             st.places.(i) <- (match p, i < 2 with
                 | Person, _ -> Computer
                 | Computer, true -> Person
                 | Computer, false -> Nobody
                 | Nobody, _ -> Person);
           if st.places.(i) = Person then Gui.label ~colour:Gui.muted ui 356 (y + 5) key_names.(i) in
         row 0 "Left 1" 120; row 2 "Left 2" 152; row 1 "Right 1" 192; row 3 "Right 2" 224;
         let start = Gui.button ui 136 280 120 "Play"
                     || List.exists (fun k -> k = "\r" || k = "\n" || k = " ") ui.Gui.keys in
         Gui.label ~colour:Gui.muted ui 270 285 "Enter plays; Escape stops a game";
         if start then st.screen <- Playing (new_game st.places sprites)
       | Playing game ->
         if List.mem "\027" ui.Gui.keys then st.screen <- Choosing
         else begin
           (* the game's time: steps of 20 ms, as many as have passed *)
           let now = Mynos.uptime () in
           game.pending <- Float.min 100. (game.pending +. (now -. game.last) *. 1000.);
           game.last <- now;
           while game.winner = None && game.pending >= float step_ms do
             step ui game;
             game.pending <- game.pending -. float step_ms
           done;
           List.iter (fun t -> List.iter (fun p -> draw g p.sprite p.frame p.x p.y) t.players)
             [ game.tl; game.tr ];
           text g 100 0 (string_of_int game.tl.score);
           text g (game.tr.xmax - 100) 0 (string_of_int game.tr.score);
           draw g game.ball.bs game.ball.bframe game.ball.bx game.ball.by;
           match game.winner with
           | Some w ->
             centre g 150 w;
             centre g 180 (Printf.sprintf "%d - %d" game.tl.score game.tr.score);
             centre g 230 "Enter: again";
             if List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys then
               st.screen <- Playing (new_game st.places sprites)
           | None -> ()
         end);
      st);
  exit 0
