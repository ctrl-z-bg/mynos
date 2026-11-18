(* A small immediate-mode toolkit: see gui.mli. *)

type ui = {
  window : Display.window;
  g : Gfx.t;
  mutable mx : int;
  mutable my : int;
  mutable buttons : int;
  mutable clicked : bool;
  mutable press : int * int;
  mutable keys : string list;
  mutable focused : bool;
  mutable tick : bool;
  mutable field : int;
  mutable wheel : int;
}

let background = 0xF4F6F8
let foreground = 0x1A2228
let muted = 0x5F6B76
let accent = 0x2D6CA2
let panel_colour = 0xFFFFFF

let label ?(colour = foreground) ?(bold = false) ui x y s =
  ignore (Gfx.text ~bold ui.g x y s colour)

let paragraph ?(colour = foreground) ui x y width s =
  let per_line = max 1 (width / Gfx.char_w) in
  let words = String.split_on_char ' ' s in
  let lines = List.rev (List.fold_left (fun acc w ->
      match acc with
      | l :: rest when Gfx.cells l + 1 + Gfx.cells w <= per_line -> (l ^ " " ^ w) :: rest
      | _ -> w :: acc) [] words) in
  List.iteri (fun i l -> ignore (Gfx.text ui.g x (y + i * 18) l colour)) lines;
  18 * List.length lines

let panel ?(colour = panel_colour) ui x y w h =
  Gfx.fill ui.g x y w h colour;
  Gfx.rect ui.g x y w h 0xD5DBE1

(* a file picker open (a modal panel): the window's other widgets get no
   pointer and no keys until it closes *)
let modals = ref 0
let in_modal = ref false
let blocked () = !modals > 0 && not !in_modal

let hovered ui x y w h =
  not (blocked ()) &&
  ui.mx >= x && ui.my >= y && ui.mx < x + w && ui.my < y + h
  && (match Gfx.clip () with
      | None -> true
      | Some (cx, cy, cw, ch) -> ui.mx >= cx && ui.my >= cy && ui.mx < cx + cw && ui.my < cy + ch)

let button ?(h = 26) ui x y w text =
  let over = hovered ui x y w h in
  let down = over && ui.buttons land 1 <> 0 in
  let bg = if down then 0x1F4F7A else if over then 0x3A7DB8 else accent in
  Gfx.fill ui.g x y w h bg;
  Gfx.fill ui.g x (y + h - 2) w 2 (Gfx.mix bg 0x000000 0.25);
  let tw = Gfx.cells text * Gfx.char_w in
  ignore (Gfx.text ~bold:true ui.g (x + (w - tw) / 2) (y + (h - Gfx.char_h) / 2) text 0xFFFFFF);
  let px, py = ui.press in
  ui.clicked && over && px >= x && py >= y && px < x + w && py < y + h

let text_field ui id x y w value =
  let h = 22 in
  if ui.clicked && not (blocked ())
     && (let px, py = ui.press in px >= x && py >= y && px < x + w && py < y + h)
  then ui.field <- id;
  let focused = ui.field = id in
  let value =
    if not focused || blocked () then value
    else List.fold_left (fun v k ->
        match k with
        | "\127" | "\b" ->               (* Backspace: a whole character *)
          let n = String.length v in
          if n = 0 then v
          else begin
            let i = ref (n - 1) in
            while !i > 0 && Char.code v.[!i] land 0xC0 = 0x80 do decr i done;
            String.sub v 0 !i
          end
        | k when String.length k > 0 && (k.[0] = '\027' || k.[0] < ' ') -> v
        | k -> v ^ k) value ui.keys in
  Gfx.fill ui.g x y w h 0xFFFFFF;
  Gfx.rect ui.g x y w h (if focused then accent else 0xB8C2CC);
  let room = (w - 12) / Gfx.char_w in
  let n = Gfx.cells value in
  let shown =                              (* its end, when it is long *)
    if n <= room then value
    else begin
      let skip = ref (n - room) and i = ref 0 in
      while !skip > 0 do
        incr i;
        while !i < String.length value && Char.code value.[!i] land 0xC0 = 0x80 do incr i done;
        decr skip
      done;
      String.sub value !i (String.length value - !i)
    end in
  ignore (Gfx.text ui.g (x + 6) (y + 3) shown foreground);
  if focused then
    Gfx.fill ui.g (x + 6 + Gfx.cells shown * Gfx.char_w) (y + 4) 2 14 accent;
  value

let list_item ui x y w ~selected label =
  let h = 22 in
  let over = hovered ui x y w h in
  if selected then Gfx.fill ui.g x y w h accent
  else if over then Gfx.fill ui.g x y w h 0xDCE6EF;
  ignore (Gfx.text ~max:((w - 12) / Gfx.char_w) ui.g (x + 8) (y + 3) label
            (if selected then 0xFFFFFF else foreground));
  let px, py = ui.press in
  ui.clicked && over && px >= x && py >= y && px < x + w && py < y + h

(* scroll boxes: how far each is scrolled, and its content's height as
   measured at the last frame (immediate mode: known only after drawing) *)
type scroll_state = { mutable offset : int; mutable content : int; mutable to_end : bool }
let scrolls : (int, scroll_state) Hashtbl.t = Hashtbl.create 8
let state id = match Hashtbl.find_opt scrolls id with
  | Some s -> s
  | None -> let s = { offset = 0; content = 0; to_end = false } in Hashtbl.add scrolls id s; s

let scroll_to_end _ui id = (state id).to_end <- true

let bar_w = 10

let scroll ?(colour = panel_colour) ui id x y w h content =
  let s = state id in
  let inner = h - 2 in
  let max_off () = max 0 (s.content - inner) in
  if s.to_end then (s.offset <- max_off (); s.to_end <- false);
  (* the wheel over it: three lines a notch *)
  if ui.wheel <> 0 && hovered ui x y w h then begin
    s.offset <- s.offset + ui.wheel * 3 * 18;
    ui.wheel <- 0
  end;
  (* the bar: pressed or dragged, the thumb follows the pointer *)
  let thumb_h () = max 24 (inner * inner / max 1 s.content) in
  let bx = x + w - bar_w - 1 in
  let px, py = ui.press in
  if max_off () > 0 && ui.buttons land 1 <> 0
     && px >= bx && px < x + w && py >= y && py < y + h then begin
    let room = inner - thumb_h () in
    if room > 0 then
      s.offset <- (ui.my - y - thumb_h () / 2) * max_off () / room
  end;
  s.offset <- max 0 (min (max_off ()) s.offset);
  Gfx.fill ui.g x y w h colour;
  let used = Gfx.with_clip (x + 1) (y + 1) (w - 2 - bar_w) inner
      (fun () -> content (y + 1 - s.offset)) in
  s.content <- used;
  s.offset <- max 0 (min (max_off ()) s.offset);
  Gfx.rect ui.g x y w h 0xD5DBE1;
  if max_off () > 0 then begin
    let th = thumb_h () in
    let ty = y + 1 + (inner - th) * s.offset / max_off () in
    Gfx.fill ui.g bx (y + 1) bar_w inner 0xEDF1F4;
    Gfx.fill ui.g (bx + 2) ty (bar_w - 4) th
      (if hovered ui bx y bar_w h || ui.buttons land 1 <> 0 && px >= bx then 0x7F8C98 else 0xA9B4BE)
  end

exception Quit

let run ?(title = "") ?(tick = 0.) w h state frame =
  let window =
    try Display.window ~title w h with
    | Ipc.Remote_error (_, m) | Failure m ->
      (* outside the graphical session: say where it runs, and end *)
      Printf.eprintf "%s: %s.\nA graphical program: start the graphical session (gui), then \
                      run it from a Terminal window, from Files, or with &.\n%!"
        (Filename.basename Sys.argv.(0)) m;
      exit 2
    | Mynos.Error _ ->
      prerr_endline "no display service (displayd)"; exit 2 in
  let ui = { window; g = window.Display.pixels; mx = -1; my = -1; buttons = 0;
             clicked = false; press = (-1, -1); keys = []; focused = true; tick = false;
             field = -1; wheel = 0 } in
  let rec loop state =
    Gfx.fill ui.g 0 0 w h background;
    match frame ui state with
    | exception Quit -> Display.destroy window
    | state ->
      Display.damage window;
      ui.clicked <- false; ui.keys <- []; ui.tick <- false; ui.wheel <- 0;
      (match Display.next_event ~timeout:tick window with
       | Display.Close -> Display.destroy window
       | Display.Mouse { x; y; buttons } ->
         if buttons land 1 <> 0 && ui.buttons land 1 = 0 then ui.press <- (x, y);
         if buttons land 1 = 0 && ui.buttons land 1 <> 0 then ui.clicked <- true;
         ui.mx <- x; ui.my <- y; ui.buttons <- buttons;
         loop state
       | Display.Key k -> ui.keys <- [ k ]; loop state
       | Display.Tick -> ui.tick <- true; loop state
       | Display.Focus f -> ui.focused <- f; loop state
       | Display.Wheel n -> ui.wheel <- n; loop state
       | exception Ipc.Remote_error _ -> ()) in
  loop state

let spawn ?(args = []) program =
  try ignore (Mynos.spawn "ocamlrun" (Array.of_list ("ocamlrun" :: program :: args)))
  with Mynos.Error _ -> ()

(* ---- files ---- *)

type entry = { name : string; is_dir : bool; size : int }

let entries dir =
  match Sys.readdir dir with
  | names ->
    let full n = if dir = "/" then "/" ^ n else Filename.concat dir n in
    let es = Array.to_list (Array.map (fun n ->
        let is_dir = try Sys.is_directory (full n) with Sys_error _ -> false in
        let size = if is_dir then 0 else
            try Int64.to_int (In_channel.with_open_bin (full n) In_channel.length)
            with _ -> 0 in
        { name = n; is_dir; size }) names) in
    List.sort (fun a b ->
        if a.is_dir <> b.is_dir then compare b.is_dir a.is_dir
        else compare (String.lowercase_ascii a.name) (String.lowercase_ascii b.name)) es
  | exception Sys_error _ -> []

let size_text n =
  if n < 1024 then Printf.sprintf "%d B" n
  else if n < 1024 * 1024 then Printf.sprintf "%d KB" ((n + 512) / 1024)
  else Printf.sprintf "%.1f MB" (float n /. 1048576.)

let parent dir =
  if dir = "/" then "/" else
    let p = Filename.dirname dir in if p = "." then "/" else p

let join dir n = if dir = "/" then "/" ^ n else dir ^ "/" ^ n

(* ---- the file picker ---- *)

type picked = Picked of string | Cancelled

type picker = {
  title : string;
  filter : string -> bool;
  mutable dir : string;
  mutable listing : entry list;
  mutable chosen : string option;
  mutable all : bool;               (* the files the filter hides, too *)
}

let pickers : (int, picker) Hashtbl.t = Hashtbl.create 2

let go p dir = p.dir <- dir; p.listing <- entries dir; p.chosen <- None

let open_file_picker ?(title = "Open a file") ?(dir = "/") ?(filter = fun _ -> true) id =
  let dir, chosen =
    if (try Sys.is_directory dir with Sys_error _ -> false) then dir, None
    else if Sys.file_exists dir then parent dir, Some (Filename.basename dir)
    else "/", None in
  let p = { title; filter; dir; listing = []; chosen = None; all = false } in
  go p dir;
  p.chosen <- chosen;
  if not (Hashtbl.mem pickers id) then incr modals;
  Hashtbl.replace pickers id p

let close id =
  if Hashtbl.mem pickers id then (Hashtbl.remove pickers id; decr modals)

let file_picker ui id =
  match Hashtbl.find_opt pickers id with
  | None -> None
  | Some p ->
    in_modal := true;
    Fun.protect ~finally:(fun () -> in_modal := false) (fun () ->
        let ww = ui.g.Gfx.width and wh = ui.g.Gfx.height in
        let w = min (ww - 24) 600 and h = min (wh - 24) 440 in
        let x = (ww - w) / 2 and y = (wh - h) / 2 in
        let result = ref None in
        let pick n = result := Some (Picked (join p.dir n)) in
        (* the panel, its shadow, its title *)
        Gfx.fill ui.g (x + 5) (y + 5) w h 0x55606A;
        Gfx.fill ui.g x y w h 0xFFFFFF;
        Gfx.rect ui.g x y w h 0x1B3A57;
        Gfx.fill ui.g x y w 28 0x1B3A57;
        ignore (Gfx.text ~bold:true ui.g (x + 10) (y + 6) p.title 0xFFFFFF);
        (* the places, and up *)
        let by = y + 36 in
        List.iteri (fun i (label, dir) ->
            if button ui (x + 10 + i * 78) by 72 label then go p dir)
          [ "/", "/"; "/tmp", "/tmp"; "/disk", "/disk" ];
        if button ui (x + 244) by 56 "Up" then go p (parent p.dir);
        if button ui (x + w - 130) by 120 (if p.all then "All files" else "Filtered") then
          p.all <- not p.all;
        (* where: each part of the path goes there *)
        let cy = by + 34 in
        let parts = List.filter (( <> ) "") (String.split_on_char '/' p.dir) in
        let cx = ref (x + 10) in
        let crumb label dir =
          let wd = 8 * Gfx.cells label + 8 in
          let over = hovered ui !cx cy wd 20 in
          if over then Gfx.fill ui.g !cx cy wd 20 0xDCE6EF;
          ignore (Gfx.text ~bold:true ui.g (!cx + 4) (cy + 2) label accent);
          let px, py = ui.press in
          if ui.clicked && over && px >= !cx && px < !cx + wd && py >= cy && py < cy + 20
          then go p dir;
          cx := !cx + wd in
        crumb "/" "/";
        ignore (List.fold_left (fun acc part ->
            let d = join acc part in
            ignore (Gfx.text ui.g !cx (cy + 2) "\xe2\x80\xba" muted);
            cx := !cx + 10;
            crumb part d; d) "/" parts);
        (* the entries *)
        let ly = cy + 28 and lh = h - (cy + 28 - y) - 48 in
        let shown = List.filter (fun e -> e.is_dir || p.all || p.filter e.name) p.listing in
        scroll ui (-1000 - id) (x + 10) ly (w - 20) lh (fun top ->
            List.iteri (fun i e ->
                let ry = top + i * 22 in
                let selected = p.chosen = Some e.name in
                let label = if e.is_dir then e.name ^ "/" else e.name in
                if list_item ui (x + 11) ry (w - 34) ~selected label then begin
                  if e.is_dir then go p (join p.dir e.name)
                  else if selected then pick e.name           (* a second click *)
                  else p.chosen <- Some e.name
                end;
                if not e.is_dir then begin
                  let s = size_text e.size in
                  ignore (Gfx.text ui.g (x + w - 34 - 8 * String.length s) (ry + 3) s
                            (if selected then 0xFFFFFF else muted))
                end) shown;
            if shown = [] then
              ignore (Gfx.text ui.g (x + 18) (top + 4)
                        (if p.listing = [] then "(empty, or not readable)"
                         else "(nothing here matches: All files shows the rest)") muted);
            22 * List.length shown + 4);
        (* the choice, and the answer *)
        let fy = y + h - 38 in
        ignore (Gfx.text ~max:((w - 260) / 8) ui.g (x + 12) (fy + 5)
                  (match p.chosen with Some n -> join p.dir n | None -> p.dir)
                  (if p.chosen = None then muted else foreground));
        if button ui (x + w - 236) fy 110 "Cancel" then result := Some Cancelled;
        if button ui (x + w - 120) fy 110 "Open" then
          (match p.chosen with Some n -> pick n | None -> ());
        (* keys: Enter opens, Escape cancels, Backspace goes up *)
        List.iter (function
            | "\r" | "\n" -> (match p.chosen with Some n -> pick n | None -> ())
            | "\027" -> result := Some Cancelled
            | "\127" | "\b" -> go p (parent p.dir)
            | _ -> ()) ui.keys;
        (match !result with Some _ -> close id | None -> ());
        !result)

