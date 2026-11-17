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

let hovered ui x y w h = ui.mx >= x && ui.my >= y && ui.mx < x + w && ui.my < y + h

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
  if ui.clicked && (let px, py = ui.press in px >= x && py >= y && px < x + w && py < y + h)
  then ui.field <- id;
  let focused = ui.field = id in
  let value =
    if not focused then value
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

exception Quit

let run ?(title = "") ?(tick = 0.) w h state frame =
  let window = Display.window ~title w h in
  let ui = { window; g = window.Display.pixels; mx = -1; my = -1; buttons = 0;
             clicked = false; press = (-1, -1); keys = []; focused = true; tick = false;
             field = -1 } in
  let rec loop state =
    Gfx.fill ui.g 0 0 w h background;
    match frame ui state with
    | exception Quit -> Display.destroy window
    | state ->
      Display.damage window;
      ui.clicked <- false; ui.keys <- []; ui.tick <- false;
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
       | exception Ipc.Remote_error _ -> ()) in
  loop state

let spawn program =
  try ignore (Mynos.spawn "ocamlrun" [| "ocamlrun"; program |])
  with Mynos.Error _ -> ()
