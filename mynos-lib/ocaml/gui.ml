(* A small immediate-mode toolkit: see gui.mli. *)

type ui = {
  mutable window : Display.window;
  mutable g : Gfx.t;
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
  mutable released : string list;
  mutable held : string list;
}

let width ui = ui.g.Gfx.width
let height ui = ui.g.Gfx.height

let background = 0xF4F6F8
let foreground = 0x1A2228
let muted = 0x5F6B76
let accent = 0x2D6CA2
let panel_colour = 0xFFFFFF

(* ---- text the mouse can select: what this frame drew, piece by piece ---- *)

type piece = {
  px : int; py : int;                      (* its first cell's top left *)
  chars : string array;                    (* a cell each (tabs expanded) *)
  pclip : (int * int * int * int) option;  (* the clip it was drawn in *)
}

let pieces : piece list ref = ref []       (* this frame's, last first *)

let utf8_cells s =
  let s = Gfx.expand_tabs s in
  let out = ref [] and i = ref 0 and n = String.length s in
  while !i < n do
    let j = ref (!i + 1) in
    while !j < n && Char.code s.[!j] land 0xC0 = 0x80 do incr j done;
    out := String.sub s !i (!j - !i) :: !out; i := !j
  done;
  Array.of_list (List.rev !out)

let selectable ?max x y s =
  if s <> "" then begin
    let chars = utf8_cells s in
    let chars = match max with
      | Some m when m < Array.length chars -> Array.sub chars 0 (Stdlib.max 0 m)
      | _ -> chars in
    pieces := { px = x; py = y; chars; pclip = Gfx.clip () } :: !pieces
  end

let text ?bold ?max ui x y s colour =
  selectable ?max x y s;
  Gfx.text ?bold ?max ui.g x y s colour

let label ?(colour = foreground) ?(bold = false) ui x y s =
  ignore (text ~bold ui x y s colour)

let paragraph ?(colour = foreground) ui x y width s =
  let per_line = max 1 (width / Gfx.char_w) in
  let words = String.split_on_char ' ' s in
  let lines = List.rev (List.fold_left (fun acc w ->
      match acc with
      | l :: rest when Gfx.cells l + 1 + Gfx.cells w <= per_line -> (l ^ " " ^ w) :: rest
      | _ -> w :: acc) [] words) in
  List.iteri (fun i l -> ignore (text ui x (y + i * 18) l colour)) lines;
  18 * List.length lines

let panel ?(colour = panel_colour) ui x y w h =
  Gfx.fill ui.g x y w h colour;
  Gfx.rect ui.g x y w h 0xD5DBE1

(* a file picker open (a modal panel): the window's other widgets get no
   pointer and no keys until it closes *)
let modals = ref 0
let in_modal = ref false
let blocked () = !modals > 0 && not !in_modal

(* ---- the selection: a drag over the pieces, from the point pressed to
   the pointer; a double click, a word. Copied to the clipboard when the
   button is let go, as in a terminal. Kept as points on the window: a
   cell is selected when one of the two points is after it and the other
   not, among the pieces drawn in the same clip as the first. ---- *)

type selection = {
  mutable anchor : (int * int) option;     (* the press, on a piece *)
  mutable focus : int * int;
  mutable region : (int * int * int * int) option;
  mutable dragging : bool;                 (* moved: a selection *)
  mutable shown : bool;                    (* one to draw (until a press) *)
  mutable word : bool;                     (* a double click's: fixed *)
  mutable last_press : float;
  mutable last_point : int * int;
  mutable last_buttons : int;
}

let sel = { anchor = None; focus = (0, 0); region = None; dragging = false; shown = false;
            word = false; last_press = 0.; last_point = (-100, -100); last_buttons = 0 }

let cw = Gfx.char_w and ch = Gfx.char_h

(* a cell is before a point: on a row above it, or on its row and left *)
let before p i (x, y) =
  if p.py + ch <= y then true
  else if p.py > y then false
  else p.px + i * cw + cw / 2 < x

let visible p i =
  match p.pclip with
  | None -> true
  | Some (x, y, w, h) ->
    let cx = p.px + i * cw in
    cx >= x && cx + cw <= x + w && p.py + ch > y && p.py < y + h

let hit p (x, y) =
  y >= p.py && y < p.py + ch && x >= p.px && x < p.px + Array.length p.chars * cw
  && (match p.pclip with
      | None -> true
      | Some (cx, cy, w, h) -> x >= cx && x < cx + w && y >= cy && y < cy + h)

let selected p i =
  match sel.anchor with
  | Some a when sel.shown && p.pclip = sel.region ->
    visible p i && before p i a <> before p i sel.focus
  | _ -> false

(* the selected text: rows top to bottom, pieces on a row left to right *)
let selection_text ps =
  let ps = List.sort (fun a b -> compare (a.py, a.px) (b.py, b.px)) ps in
  let rows = Buffer.create 256 and line = Buffer.create 80 and row_y = ref min_int
  and line_end = ref 0 and first = ref true in
  let end_line () =
    if not !first then begin
      let l = Buffer.contents line in
      let n = ref (String.length l) in
      while !n > 0 && l.[!n - 1] = ' ' do decr n done;
      Buffer.add_string rows (String.sub l 0 !n); Buffer.add_char rows '\n'
    end;
    Buffer.clear line; first := false in
  List.iter (fun p ->
      Array.iteri (fun i c ->
          if selected p i then begin
            let x = p.px + i * cw in
            if p.py <> !row_y then begin end_line (); row_y := p.py; line_end := x end;
            (* a gap between pieces of a row: as spaces *)
            if x > !line_end then Buffer.add_string line (String.make ((x - !line_end) / cw) ' ');
            Buffer.add_string line c; line_end := x + cw
          end) p.chars) ps;
  end_line ();
  let s = Buffer.contents rows in            (* each row ends with a newline *)
  if s = "" then "" else String.sub s 0 (String.length s - 1)

(* the selection colour, mixed into what was drawn *)
let highlight g x y w h =
  let x0 = max 0 x and y0 = max 0 y in
  let x1 = min g.Gfx.width (x + w) and y1 = min g.Gfx.height (y + h) in
  for yy = y0 to y1 - 1 do
    for xx = x0 to x1 - 1 do
      let k = yy * g.Gfx.width + xx in
      let c = Int32.to_int (Bigarray.Array1.unsafe_get g.Gfx.pixels k) land 0xFFFFFF in
      Bigarray.Array1.unsafe_set g.Gfx.pixels k (Int32.of_int (Gfx.mix c 0x3D8FE0 0.38))
    done
  done

let word_at p i =
  let is_word c = String.length c > 1 || (match c.[0] with
      | ' ' | '\t' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | ',' | ';' | '"' | '\'' | '`' -> false
      | _ -> true) in
  if not (is_word p.chars.(i)) then (i, i + 1)
  else begin
    let a = ref i and b = ref (i + 1) in
    while !a > 0 && is_word p.chars.(!a - 1) do decr a done;
    while !b < Array.length p.chars && is_word p.chars.(!b) do incr b done;
    (!a, !b)
  end

(* after a frame: the mouse's part, then the selection drawn over it *)
let finish_selection ui ps =
  let pressed = ui.buttons land 1 <> 0 && sel.last_buttons land 1 = 0 in
  let released = ui.buttons land 1 = 0 && sel.last_buttons land 1 <> 0 in
  sel.last_buttons <- ui.buttons;
  if pressed then begin
    let now = Mynos.uptime () and (px, py) = ui.press in
    let (lx, ly) = sel.last_point in
    let double = now -. sel.last_press < 0.4 && abs (px - lx) < 5 && abs (py - ly) < 5 in
    sel.last_press <- now; sel.last_point <- (px, py);
    sel.shown <- false; sel.dragging <- false; sel.word <- false; sel.anchor <- None;
    match List.find_opt (fun p -> hit p (px, py)) ps with
    | Some p when not (blocked ()) ->
      sel.region <- p.pclip;
      if double then begin
        let i = min (Array.length p.chars - 1) ((px - p.px) / cw) in
        let a, b = word_at p i in
        sel.anchor <- Some (p.px + a * cw, p.py + ch / 2);
        sel.focus <- (p.px + b * cw, p.py + ch / 2);
        sel.word <- true; sel.shown <- true;
        Clipboard.set (selection_text ps)
      end else begin
        sel.anchor <- Some (px, py); sel.focus <- (px, py)
      end
    | _ -> ()
  end else if ui.buttons land 1 <> 0 && not sel.word then begin
    match sel.anchor with
    | Some (ax, ay) ->
      if abs (ui.mx - ax) >= 4 || abs (ui.my - ay) >= 4 then begin
        sel.dragging <- true; sel.shown <- true
      end;
      sel.focus <- (ui.mx, ui.my)
    | None -> ()
  end;
  if released && sel.dragging then begin
    sel.dragging <- false;
    let s = selection_text ps in
    if s <> "" then Clipboard.set s
  end;
  if sel.shown then
    List.iter (fun p ->
        let n = Array.length p.chars in
        let i = ref 0 in
        while !i < n do
          if selected p !i then begin
            let j = ref !i in
            while !j < n && selected p !j do incr j done;
            let x = p.px + !i * cw and w = (!j - !i) * cw in
            (match p.pclip with
             | None -> highlight ui.g x p.py w ch
             | Some (cx, cy, cw', ch') ->
               let x0 = max x cx and y0 = max p.py cy in
               let x1 = min (x + w) (cx + cw') and y1 = min (p.py + ch) (cy + ch') in
               if x1 > x0 && y1 > y0 then highlight ui.g x0 y0 (x1 - x0) (y1 - y0));
            i := !j
          end else incr i
        done) ps

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

(* each field's cursor (a byte offset in its text), its first character
   shown, and the text it gave last: a text the program changed (cleared
   after Enter, a line recalled) puts the cursor at its end *)
let field_state : (int, int * int * string) Hashtbl.t = Hashtbl.create 8

let utf8_prev s i =
  let i = ref (i - 1) in
  while !i > 0 && Char.code s.[!i] land 0xC0 = 0x80 do decr i done;
  max 0 !i

let utf8_next s i =
  let n = String.length s in
  if i >= n then n
  else begin
    let i = ref (i + 1) in
    while !i < n && Char.code s.[!i] land 0xC0 = 0x80 do incr i done;
    !i
  end

(* the byte offset of the k-th character *)
let utf8_offset s k =
  let i = ref 0 and c = ref 0 in
  while !c < k && !i < String.length s do i := utf8_next s !i; incr c done;
  !i

let text_field ui id x y w value =
  let h = 22 in
  let room = max 1 ((w - 12) / Gfx.char_w) in
  let cur, first =
    match Hashtbl.find_opt field_state id with
    | Some (c, f, last) when last = value -> (ref (min c (String.length value)), f)
    | Some (_, f, _) -> (ref (String.length value), f)
    | None -> (ref (String.length value), 0) in
  if ui.clicked && not (blocked ())
     && (let px, py = ui.press in px >= x && py >= y && px < x + w && py < y + h)
  then begin
    ui.field <- id;
    (* the cursor where the click was *)
    let px, _ = ui.press in
    cur := utf8_offset value (first + max 0 ((px - x - 6 + Gfx.char_w / 2) / Gfx.char_w))
  end;
  let focused = ui.field = id in
  let value =
    if not focused || blocked () then value
    else List.fold_left (fun v k ->
        let n = String.length v and c = !cur in
        let insert t = cur := c + String.length t; String.sub v 0 c ^ t ^ String.sub v c (n - c) in
        match k with
        | "\127" | "\b" ->               (* Backspace: the character before *)
          if c = 0 then v
          else (let p = utf8_prev v c in cur := p; String.sub v 0 p ^ String.sub v c (n - c))
        | "\027[3~" ->                    (* Delete: the character after *)
          if c >= n then v else (let q = utf8_next v c in String.sub v 0 c ^ String.sub v q (n - q))
        | "\027[D" -> cur := (if c = 0 then 0 else utf8_prev v c); v
        | "\027[C" -> cur := utf8_next v c; v
        | "\027[H" | "\001" -> cur := 0; v              (* Home, Ctrl-A *)
        | "\027[F" | "\005" -> cur := n; v              (* End, Ctrl-E *)
        (* the clipboard (the system's): Ctrl-V pastes its first line at
           the cursor, Ctrl-C copies the field, Ctrl-X cuts it *)
        | "\022" ->
          (match String.split_on_char '\n' (Clipboard.get ()) with l :: _ -> insert l | [] -> v)
        | "\003" -> Clipboard.set v; v
        | "\021" -> cur := 0; ""                        (* Ctrl-U: all of it gone *)
        | "\024" -> Clipboard.set v; cur := 0; ""
        | k when String.length k > 0 && (k.[0] = '\027' || k.[0] < ' ') -> v
        | k -> insert k) value ui.keys in
  let cur = min !cur (String.length value) in
  (* the first character shown: the cursor in view, the field full *)
  let at = Gfx.cells (String.sub value 0 cur) and total = Gfx.cells value in
  let first = ref first in
  if at < !first then first := at;
  if at > !first + room - 1 then first := at - room + 1;
  if total - !first < room - 1 then first := total - room + 1;
  let first = max 0 !first in
  Hashtbl.replace field_state id (cur, first, value);
  Gfx.fill ui.g x y w h 0xFFFFFF;
  Gfx.rect ui.g x y w h (if focused then accent else 0xB8C2CC);
  let a = utf8_offset value first in
  let b = utf8_offset value (first + room) in
  ignore (Gfx.text ui.g (x + 6) (y + 3) (String.sub value a (b - a)) foreground);
  if focused then
    Gfx.fill ui.g (x + 6 + (at - first) * Gfx.char_w) (y + 4) 2 14 accent;
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
let scroll_to _ui id offset = let s = state id in s.offset <- max 0 offset; s.to_end <- false

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

let run ?(title = "") ?(tick = 0.) ?resizable ?unsaved w h state frame =
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
             field = -1; wheel = 0; released = []; held = [] } in
  (* the window may be gone already (the session ended: displayd closed
     every window), so its end is quiet *)
  (match resizable with
   | Some (mw, mh) -> (try Display.set_resizable window mw mh with Ipc.Remote_error _ -> ())
   | None -> ());
  let destroy () = try Display.destroy ui.window with Ipc.Remote_error _ | Mynos.Error _ -> () in
  (* ticks keep their pace: the wait for the next one is what is left until
     it is due, not a whole period after every event (moving the mouse over
     a window stopped its animation) *)
  let next_tick = ref (Mynos.uptime () +. tick) in
  (* the close box with changes not saved: a question over the window,
     which takes the clicks meanwhile (a modal, as the file picker) *)
  let closing = ref false in
  let ask_close () =
    in_modal := true;
    Fun.protect ~finally:(fun () -> in_modal := false) (fun () ->
        let w = width ui and h = height ui in
        let bw = min 440 (w - 16) and bh = 112 in
        let bx = (w - bw) / 2 and by = max 8 ((h - bh) / 2) in
        Gfx.fill ui.g (bx + 5) (by + 5) bw bh 0x55606A;
        Gfx.fill ui.g bx by bw bh 0xFFFFFF;
        Gfx.rect ui.g bx by bw bh 0x1B3A57;
        label ~bold:true ui (bx + 14) (by + 12) "Close without saving?";
        ignore (paragraph ~colour:muted ui (bx + 14) (by + 36) (bw - 28)
                  "The changes that were not saved will be lost.");
        let close = button ui (bx + bw - 262) (by + bh - 38) 148 "Close anyway" in
        let cancel = button ui (bx + bw - 106) (by + bh - 38) 92 "Cancel"
                     || List.mem "\027" ui.keys in
        if cancel && not close then begin closing := false; decr modals end;
        close) in
  let rec loop state =
    if tick > 0. && Mynos.uptime () >= !next_tick then begin
      ui.tick <- true;
      next_tick := Mynos.uptime () +. tick
    end;
    Gfx.fill ui.g 0 0 (width ui) (height ui) background;
    pieces := [];
    match frame ui state with
    | exception Quit -> destroy ()
    | state when !closing && ask_close () -> destroy ()
    | state ->
      finish_selection ui !pieces;
      match Display.damage ui.window with
      | exception (Ipc.Remote_error _ | Mynos.Error _) -> ()
      | () ->
      (* a click or a key may have changed the state halfway through the
         frame: what was drawn before it shows the old one (a list's old
         selection), so the frame is drawn once more at once *)
      let changed = ui.clicked || ui.keys <> [] in
      ui.clicked <- false; ui.keys <- []; ui.tick <- false; ui.wheel <- 0; ui.released <- [];
      if changed then loop state else
      let timeout = if tick > 0. then max 0.001 (!next_tick -. Mynos.uptime ()) else tick in
      (match Display.next_event ~timeout ui.window with
       | Display.Close ->
         (match unsaved with
          | Some f when f () ->
            (* asked once: the question shows until it is answered *)
            if not !closing then begin closing := true; incr modals end;
            loop state
          | _ -> destroy ())
       | Display.Mouse { x; y; buttons } ->
         if buttons land 1 <> 0 && ui.buttons land 1 = 0 then ui.press <- (x, y);
         if buttons land 1 = 0 && ui.buttons land 1 <> 0 then ui.clicked <- true;
         ui.mx <- x; ui.my <- y; ui.buttons <- buttons;
         loop state
       | Display.Key k ->
         ui.keys <- [ k ];
         if not (List.mem k ui.held) then ui.held <- ui.held @ [ k ];
         loop state
       | Display.Key_up k ->
         ui.released <- [ k ];
         ui.held <- List.filter (( <> ) k) ui.held;
         loop state
       | Display.Tick ->
         ui.tick <- true; next_tick := Mynos.uptime () +. tick; loop state
       | Display.Focus f ->
         (* the keys held go with the focus: their releases come to
            another window *)
         ui.focused <- f;
         if not f then begin ui.released <- ui.held; ui.held <- [] end;
         loop state
       | Display.Wheel n -> ui.wheel <- n; loop state
       | Display.Resize (nw, nh) ->
         (* the user's size: new pixels, drawn at once *)
         (match Display.resize ui.window nw nh with
          | win -> ui.window <- win; ui.g <- win.Display.pixels
          | exception (Ipc.Remote_error _ | Mynos.Error _) -> ());
         loop state
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

