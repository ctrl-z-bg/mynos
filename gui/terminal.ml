(* terminal: a terminal window (doc/decisions/gui.md, phase 3).

   It is a console service of its own (console/1, module Console;
   registered as "term<pid>"), and starts sh with MYNOS_CONSOLE naming it:
   libmynos then sends the shell's (and its programs') reads, terminal
   modes and output here instead of to consoled and the kernel's screen.
   The output goes through a VT100 emulator (as the kernel's terminal, in
   OCaml) onto an 80 x 25 grid, drawn with Gfx. Typed keys come from the
   display: edited into lines here in line mode, passed on in raw mode.

   Two domains: the service (requests; never waits for input: a read with
   nothing to give stays pending) and the window (keys, ticks). One lock. *)

(* the grid: 80 x 25 at first, then as the window is resized *)
let cols = ref 80
let rows = ref 25
let margin = 4
let cw = Gfx.char_w
let ch = Gfx.char_h

(* ---- colours ---- *)

let default_fg = 0xD8DEE4
let default_bg = 0x0F1419
let palette = [|
  0x1C2329; 0xE0605A; 0x7FC96B; 0xE2C15F; 0x5C9EE0; 0xC07ADB; 0x5EC4CF; 0xC8CED4;
  0x4A5560; 0xFF7B73; 0x9BE28A; 0xF5D77A; 0x7FB6F0; 0xD69BEA; 0x80DCE6; 0xF4F6F8 |]

(* ---- the screen ---- *)

type cell = { mutable c : string; mutable fg : int; mutable bg : int; mutable bold : bool }

let blank () = { c = " "; fg = -1; bg = -1; bold = false }
let screen = ref (Array.init !rows (fun _ -> Array.init !cols (fun _ -> blank ())))
let dirty = ref (Array.make !rows true)
let row = ref 0 and col = ref 0 and wrap_pending = ref false
let saved = ref (0, 0)
let cursor_on = ref true
let cur_fg = ref (-1) and cur_bg = ref (-1) and cur_bold = ref false and reverse = ref false
let alternate : (cell array array * int * int) option ref = ref None

let copy_cell d s = d.c <- s.c; d.fg <- s.fg; d.bg <- s.bg; d.bold <- s.bold
let clear_cell x = x.c <- " "; x.fg <- !cur_fg; x.bg <- !cur_bg; x.bold <- false

let erase r c0 c1 =
  for c = max 0 c0 to min !cols c1 - 1 do clear_cell !screen.(r).(c) done;
  !dirty.(r) <- true

(* ---- scrollback: the lines scrolled off the top of the main screen ---- *)

let history_max = 1000
let history : cell array array = Array.make history_max [||]
let hist_len = ref 0 and hist_next = ref 0
let view = ref 0                       (* lines looked back; 0: the screen *)
let all_dirty = ref true               (* the view moved: everything again *)
let scrolled = ref 0                   (* lines gone to the scrollback so far *)

let push_history r =
  incr scrolled;
  history.(!hist_next) <- Array.map (fun x -> { x with c = x.c }) !screen.(r);
  hist_next := (!hist_next + 1) mod history_max;
  if !hist_len < history_max then incr hist_len;
  (* looking back: the same lines stay in view *)
  if !view > 0 then (view := min !hist_len (!view + 1); all_dirty := true)

(* the k-th line above the screen (1: the last scrolled off) *)
let history_line k = history.((!hist_next - k + history_max) mod history_max)

let set_view v =
  let v = max 0 (min !hist_len v) in
  if v <> !view then (view := v; all_dirty := true)

(* ---- the selection, with the mouse: lines by number (the first ever
   is 0; the screen's top is !scrolled), so that it stays on its text
   while the screen scrolls; a column is a boundary between cells ---- *)

let line_of id =
  let k = id - !scrolled in
  if k >= 0 && k < !rows then !screen.(k)
  else if k < 0 && - k <= !hist_len then history_line (- k)
  else [||]

let sel_a : (int * int) option ref = ref None   (* where the drag began *)
let sel_b = ref (0, 0)                           (* where it is *)
let sel_shown = ref false

let sel_range () =
  match !sel_a with
  | Some a when !sel_shown -> Some (if compare a !sel_b <= 0 then (a, !sel_b) else (!sel_b, a))
  | _ -> None

let is_selected id c =
  match sel_range () with
  | Some (p1, p2) -> compare (id, c) p1 >= 0 && compare (id, c) p2 < 0
  | None -> false

let selection_text () =
  match sel_range () with
  | None -> ""
  | Some ((i1, c1), (i2, c2)) ->
    String.concat "\n" (List.init (i2 - i1 + 1) (fun k ->
        let id = i1 + k in
        let line = line_of id in
        let a = if id = i1 then c1 else 0 and b = if id = i2 then c2 else Array.length line in
        let b = min b (Array.length line) in
        let s = String.concat "" (List.init (max 0 (b - a)) (fun j -> line.(a + j).c)) in
        let n = ref (String.length s) in
        while !n > 0 && s.[!n - 1] = ' ' do decr n done;
        String.sub s 0 !n))

let scroll_up top n =
  if top = 0 && !alternate = None then
    for r = 0 to min n !rows - 1 do push_history r done;
  for r = top to !rows - 1 do
    if r + n < !rows then Array.iteri (fun c x -> copy_cell x !screen.(r + n).(c)) !screen.(r)
    else erase r 0 !cols;
    !dirty.(r) <- true
  done

let scroll_down top n =
  for r = !rows - 1 downto top do
    if r - n >= top then Array.iteri (fun c x -> copy_cell x !screen.(r - n).(c)) !screen.(r)
    else erase r 0 !cols;
    !dirty.(r) <- true
  done

let newline () =
  col := 0; wrap_pending := false;
  if !row = !rows - 1 then scroll_up 0 1 else incr row

let put s =
  if !wrap_pending then newline ();
  let x = !screen.(!row).(!col) in
  let fg, bg = if !reverse then
      ((if !cur_bg < 0 then 0 else !cur_bg), (if !cur_fg < 0 then 7 else !cur_fg))
    else (!cur_fg, !cur_bg) in
  x.c <- s; x.fg <- fg; x.bg <- bg; x.bold <- !cur_bold;
  !dirty.(!row) <- true;
  if !col = !cols - 1 then wrap_pending := true else incr col

let clamp () =
  row := max 0 (min (!rows - 1) !row);
  col := max 0 (min (!cols - 1) !col)

let set_alternate on =
  match on, !alternate with
  | true, None ->
    alternate := Some (Array.map (Array.map (fun x -> { x with c = x.c })) !screen, !row, !col);
    for r = 0 to !rows - 1 do erase r 0 !cols done;
    row := 0; col := 0
  | false, Some (s, r, c) ->
    (* saved at another size, maybe: what fits *)
    for r = 0 to !rows - 1 do erase r 0 !cols done;
    Array.iteri (fun i line ->
        if i < !rows then
          Array.iteri (fun j x -> if j < !cols then copy_cell !screen.(i).(j) x) line) s;
    Array.fill !dirty 0 !rows true;
    row := r; col := c; clamp (); alternate := None
  | _ -> ()

(* a new size of the grid (the window resized). Lines that no longer fit
   above the cursor go to the scrollback, so that the cursor's line stays
   in view; a line keeps the cells that fit. The programs inside learn the
   size when they ask (console/1 size); one that drew the whole screen
   (edit) draws again at its next start *)
let resize nc nr =
  let nc = max 20 nc and nr = max 5 nr in
  if nc <> !cols || nr <> !rows then begin
    let shift = max 0 (!row + 1 - nr) in
    if !alternate = None then for r = 0 to shift - 1 do push_history r done;
    let old = !screen and oldr = !rows and oldc = !cols in
    screen := Array.init nr (fun r ->
        Array.init nc (fun c ->
            let o = r + shift in
            if o < oldr && c < oldc then { (old.(o).(c)) with c = old.(o).(c).c } else blank ()));
    rows := nr; cols := nc;
    dirty := Array.make nr true;
    row := !row - shift;
    wrap_pending := false;
    clamp ();
    all_dirty := true
  end

let sgr params =
  let params = if params = [] then [ 0 ] else params in
  List.iter (fun p ->
      if p = 0 then (cur_fg := -1; cur_bg := -1; cur_bold := false; reverse := false)
      else if p = 1 then cur_bold := true
      else if p = 22 then cur_bold := false
      else if p = 7 then reverse := true
      else if p = 27 then reverse := false
      else if p >= 30 && p <= 37 then cur_fg := p - 30
      else if p = 39 then cur_fg := -1
      else if p >= 40 && p <= 47 then cur_bg := p - 40
      else if p = 49 then cur_bg := -1
      else if p >= 90 && p <= 97 then cur_fg := p - 90 + 8
      else if p >= 100 && p <= 107 then cur_bg := p - 100 + 8) params

let csi priv params final =
  let p i d = match List.nth_opt params i with Some v when v > 0 -> v | _ -> d in
  let n = p 0 1 in
  wrap_pending := false;
  if priv then begin
    if final = 'h' || final = 'l' then
      List.iter (fun v ->
          if v = 25 then cursor_on := final = 'h';
          if v = 1049 || v = 47 || v = 1047 then set_alternate (final = 'h')) params
  end else begin
    (match final with
     | 'A' -> row := !row - n
     | 'B' -> row := !row + n
     | 'C' -> col := !col + n
     | 'D' -> col := !col - n
     | 'E' -> row := !row + n; col := 0
     | 'F' -> row := !row - n; col := 0
     | 'G' -> col := n - 1
     | 'd' -> row := n - 1
     | 'H' | 'f' -> row := p 0 1 - 1; col := p 1 1 - 1
     | 'J' ->
       (match p 0 0 with
        | 0 -> erase !row !col !cols; for r = !row + 1 to !rows - 1 do erase r 0 !cols done
        | 1 -> for r = 0 to !row - 1 do erase r 0 !cols done; erase !row 0 (!col + 1)
        | _ -> for r = 0 to !rows - 1 do erase r 0 !cols done)
     | 'K' ->
       (match p 0 0 with
        | 0 -> erase !row !col !cols
        | 1 -> erase !row 0 (!col + 1)
        | _ -> erase !row 0 !cols)
     | 'L' -> scroll_down !row n
     | 'M' -> scroll_up !row n
     | 'P' ->
       let line = !screen.(!row) in
       for c = !col to !cols - 1 do
         if c + n < !cols then copy_cell line.(c) line.(c + n) else clear_cell line.(c)
       done;
       !dirty.(!row) <- true
     | '@' ->
       let line = !screen.(!row) in
       for c = !cols - 1 downto !col do
         if c - n >= !col then copy_cell line.(c) line.(c - n) else clear_cell line.(c)
       done;
       !dirty.(!row) <- true
     | 'X' -> erase !row !col (!col + n)
     | 'm' -> sgr params
     | 's' -> saved := (!row, !col)
     | 'u' -> let r, c = !saved in row := r; col := c
     | _ -> ());
    clamp ()
  end

(* the parser: text, ESC, CSI; UTF-8 characters gathered whole *)
type state = Text | Esc | Csi of bool * Buffer.t
let state = ref Text
let utf8 = Buffer.create 4
let utf8_left = ref 0

let output_byte b =
  match !state with
  | Esc ->
    state := Text;
    (match b with
     | '[' -> state := Csi (false, Buffer.create 8)
     | 'E' -> newline ()
     | 'D' -> if !row = !rows - 1 then scroll_up 0 1 else incr row
     | 'M' -> if !row = 0 then scroll_down 0 1 else decr row
     | '7' -> saved := (!row, !col)
     | '8' -> let r, c = !saved in row := r; col := c
     | 'c' -> for r = 0 to !rows - 1 do erase r 0 !cols done; row := 0; col := 0
     | _ -> ())
  | Csi (priv, buf) ->
    (match b with
     | '0' .. '9' | ';' -> Buffer.add_char buf b
     | '?' | '>' | '=' -> state := Csi (true, buf)
     | '\x40' .. '\x7E' ->
       state := Text;
       let params = List.map (fun s -> Option.value (int_of_string_opt s) ~default:0)
           (String.split_on_char ';' (Buffer.contents buf)) in
       let params = if Buffer.length buf = 0 then [] else params in
       csi priv params b
     | _ -> ())
  | Text ->
    let c = Char.code b in
    if !utf8_left > 0 && c land 0xC0 = 0x80 then begin
      Buffer.add_char utf8 b; decr utf8_left;
      if !utf8_left = 0 then put (Buffer.contents utf8)
    end else begin
      if !utf8_left > 0 then (utf8_left := 0; put "?");
      match b with
      | '\027' -> state := Esc
      | '\n' -> newline ()
      | '\r' -> col := 0; wrap_pending := false
      | '\b' -> if !col > 0 then decr col; wrap_pending := false
      | '\t' -> col := min (!cols - 1) ((!col + 8) land (lnot 7))
      | '\007' | '\000' -> ()
      | _ when c >= 0xC0 ->
        Buffer.clear utf8; Buffer.add_char utf8 b;
        utf8_left := if c >= 0xF0 then 3 else if c >= 0xE0 then 2 else 1
      | _ when c >= 0x20 && c < 0x7F -> put (String.make 1 b)
      | _ -> ()
    end

let output s = String.iter output_byte s

(* ---- drawing ---- *)

let window = ref None
let focused = ref true
let drawn_cursor = ref (-1, -1)

let colour i default = if i < 0 then default else palette.(i land 15)

let draw_row g r =
  let y = margin + r * ch in
  let k = r - !view in                 (* < 0: a line of the scrollback *)
  let line = if k >= 0 then !screen.(k) else history_line (- k) in
  let id = !scrolled + k in
  let sel i = is_selected id i in
  let (cr, cc) = if !view = 0 then (!row, !col) else (-1, -1) in
  let c = ref 0 in
  (* a line of the scrollback keeps the width it had: the rest is blank *)
  let n = min !cols (Array.length line) in
  if n < !cols then Gfx.fill g (margin + n * cw) y ((!cols - n) * cw) ch default_bg;
  while !c < n do
    (* a run of cells of the same attributes *)
    let x0 = !c in
    let a = line.(x0) in
    let is_cursor i = !cursor_on && r = cr && i = cc in
    let b = Buffer.create 80 in
    while !c < n && line.(!c).fg = a.fg && line.(!c).bg = a.bg && line.(!c).bold = a.bold
          && sel !c = sel x0
          && not (is_cursor !c) && (not (is_cursor x0) || !c = x0) do
      Buffer.add_string b line.(!c).c; incr c
    done;
    if !c = x0 then (Buffer.add_string b line.(x0).c; incr c);
    let fg = colour a.fg default_fg and bg = colour a.bg default_bg in
    let bg = if sel x0 then 0x2F5F96 else bg in          (* selected *)
    let fg, bg = if is_cursor x0 && !focused then (bg, 0xE8EEF2) else (fg, bg) in
    Gfx.fill g (margin + x0 * cw) y ((!c - x0) * cw) ch bg;
    if is_cursor x0 && not !focused then Gfx.rect g (margin + x0 * cw) y cw ch 0xE8EEF2;
    ignore (Gfx.text ~bold:a.bold g (margin + x0 * cw) y (Buffer.contents b) fg)
  done

(* the scrollbar, right of the grid *)
let bar_x () = !cols * cw + 2 * margin
let bar_w = 12
let height () = !rows * ch + 2 * margin
let drawn_bar = ref (-1, -1)

let draw_bar g =
  let total = !rows + !hist_len in
  let th = max 24 (height () * !rows / total) in
  let ty = if !hist_len = 0 then 0
    else (height () - th) * (!hist_len - !view) / !hist_len in
  if (ty, th) <> !drawn_bar then begin
    Gfx.fill g (bar_x ()) 0 bar_w (height ()) 0x1A2026;
    if !hist_len > 0 then Gfx.fill g (bar_x () + 3) (ty + 2) (bar_w - 6) (th - 4) 0x5A6670;
    drawn_bar := (ty, th);
    true
  end else false

let render () =
  match !window with
  | None -> ()
  | Some w ->
    let g = w.Display.pixels in
    if !all_dirty then (Array.fill !dirty 0 !rows true; all_dirty := false);
    (* looking back, screen rows show lower down: anything changed, all again *)
    if !view > 0 && Array.exists Fun.id !dirty then Array.fill !dirty 0 !rows true;
    (* rows on screen move down by view: a screen row r shows at r + view *)
    let (pr, _) = !drawn_cursor in
    if pr >= 0 && pr < !rows then !dirty.(pr) <- true;
    if !row + !view < !rows then !dirty.(!row + !view) <- true;
    let top = ref !rows and bottom = ref (-1) in
    for r = 0 to !rows - 1 do
      if !dirty.(r) then begin
        draw_row g r; !dirty.(r) <- false;
        top := min !top r; bottom := max !bottom r
      end
    done;
    drawn_cursor := (if !view = 0 then (!row, !col) else (-1, -1));
    let bar = draw_bar g in
    (try
       if bar then Display.damage w
       else if !bottom >= 0 then
         Display.damage ~y:(margin + !top * ch) ~h:((!bottom - !top + 1) * ch) w
     with _ -> ())

(* ---- the console service ---- *)

let lock = Mutex.create ()
let canon = ref true and echo = ref true and vmin = ref 1 and vtime = ref 0
let isig = ref true                    (* Ctrl-C ends the foreground program *)
let foreground = ref 0                 (* the program sh waits for *)
let line = Buffer.create 80                      (* being typed, line mode *)
let input = Buffer.create 256                    (* ready for readers *)
let eof = ref false
let pending : (int * int * float) list ref = ref []   (* channel, max, deadline *)

let reply ch s =
  (try Mynos.send ch s with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let read_reply s = Console.reply (Console.Read 0) s

(* give waiting reads what there is (under the lock) *)
let serve_reads () =
  let now = Mynos.uptime () in
  pending := List.filter (fun (chn, max, deadline) ->
      if Buffer.length input > 0 then begin
        let n = min max (Buffer.length input) in
        let s = Buffer.sub input 0 n in
        let rest = Buffer.sub input n (Buffer.length input - n) in
        Buffer.clear input; Buffer.add_string input rest;
        reply chn (read_reply s); false
      end else if !eof then (eof := false; reply chn (read_reply ""); false)
      else if deadline > 0. && now >= deadline then (reply chn (read_reply ""); false)
      else true) !pending

let handle chn msg =
  match Console.decode msg with
  | Error answer -> reply chn answer                (* describe, or an error *)
  | Ok (Console.Protocol.Request req) ->
    Mutex.lock lock;
    Fun.protect ~finally:(fun () -> Mutex.unlock lock) (fun () ->
        let ok (type a) (r : a Console.request) (v : a) = reply chn (Console.reply r v) in
        match req with
        | Console.Read len ->
          let deadline =
            if not !canon && !vmin = 0 && !vtime > 0
            then Mynos.uptime () +. float !vtime /. 10. else 0. in
          pending := !pending @ [ (chn, max 1 len, deadline) ];
          serve_reads ()
        | Console.Mode (mode, vm, vt) as r ->
          canon := mode land Console.canon <> 0; echo := mode land Console.echo <> 0;
          isig := mode land Console.nosig = 0;
          vmin := vm; vtime := vt;
          if !canon then Buffer.clear line;
          ok r ()
        | Console.Keymap _ as r -> ok r Console.layout_us
        | Console.Foreground pid as r ->
          let caller = try Mynos.channel_peer chn with Mynos.Error _ -> -1 in
          let child = List.exists (fun (p : Mynos.process) ->
              p.p_pid = pid && p.parent = caller)
              (try Mynos.processes () with Mynos.Error _ -> []) in
          if pid = 0 || child then foreground := pid;
          ok r ()
        | Console.Write data as r ->
          output data;
          ok r ();
          render ()
        | Console.Size as r -> ok r (!cols, !rows)
        | Console.Ready as r -> ok r (Buffer.length input > 0 || !eof))

let serve port =
  while true do
    match Mynos.listen port with
    | chn ->
      (match Mynos.recv ~timeout:1.0 chn with
       | msg -> handle chn msg
       | exception Mynos.Error _ -> (try Mynos.free_channel chn with Mynos.Error _ -> ()))
    | exception Mynos.Error _ -> ()
  done

(* ---- keys ---- *)

(* the lines typed in line mode, as consoled keeps them: Up and Down (or
   Ctrl-P and Ctrl-N) bring them back; they are shared with the console
   through its file, read at the first Up and appended to *)
let history_file = "/disk/.history"
let lines_max = 64
let lines : string array = Array.make lines_max ""
let lines_count = ref 0               (* lines entered so far, all time *)
let lines_pos = ref 0                 (* the one shown while browsing *)
let lines_loaded = ref false
let draft = ref ""                    (* the new line, kept while browsing *)

let remember s =
  if s <> "" && not (!lines_count > 0
                     && lines.((!lines_count - 1) mod lines_max) = s) then begin
    lines.(!lines_count mod lines_max) <- s;
    incr lines_count;
    true
  end else false

let load_history () =
  if not !lines_loaded then begin
    lines_loaded := true;
    let typed = List.init (min !lines_count lines_max) (fun i ->
        lines.((!lines_count - min !lines_count lines_max + i) mod lines_max)) in
    lines_count := 0;
    (try
       In_channel.with_open_bin history_file (fun ic ->
           let n = In_channel.length ic in
           let skip = Int64.(max 0L (sub n 65536L)) in
           In_channel.seek ic skip;
           let all = String.split_on_char '\n' (In_channel.input_all ic) in
           (* a line cut by the seek is dropped *)
           let all = if skip > 0L then List.tl all else all in
           List.iter (fun l -> ignore (remember l)) all)
     with Sys_error _ | End_of_file -> ());
    List.iter (fun l -> ignore (remember l)) typed
  end;
  lines_pos := !lines_count

let append_history s =
  try Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat ] 0o644
        history_file (fun oc -> output_string oc (s ^ "\n"))
  with Sys_error _ -> ()

(* the line being typed replaced by [s], on the screen too *)
let show_line s =
  if !echo then begin
    let old = Buffer.contents line in
    String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then output "\b \b") old;
    output s
  end;
  Buffer.clear line; Buffer.add_string line s

let browse dir =
  if not !lines_loaded then load_history ();
  let oldest = max 0 (!lines_count - lines_max) in
  let pos = !lines_pos + dir in
  if pos >= oldest && pos <= !lines_count then begin
    if !lines_pos = !lines_count then draft := Buffer.contents line;
    lines_pos := pos;
    show_line (if pos = !lines_count then !draft else lines.(pos mod lines_max))
  end

let key k =
  if k = "\003" && !isig && !foreground > 0 then begin
    (* Ctrl-C: the program sh waits for ends (no signals: killed) *)
    let pid = !foreground in
    foreground := 0;
    output "^C\r\n";
    Buffer.clear line; Buffer.clear input;
    (try Mynos.kill pid with Mynos.Error _ -> ())
  end else
  if not !canon then begin
    Buffer.add_string input k;
    if !echo && k <> "" && k.[0] >= ' ' then output k
  end else if k = "\027[A" || k = "\027OA" || k = "\016" then browse (-1)
  else if k = "\027[B" || k = "\027OB" || k = "\014" then browse 1
  else if k <> "" && k.[0] = '\027' then ()   (* no other editing keys in line mode *)
  else begin
    let i = ref 0 in
    while !i < String.length k do
      let c = k.[!i] in
      (match c with
       | '\r' | '\n' ->
         if !echo then output "\r\n";
         let typed = Buffer.contents line in
         if !echo && remember typed then append_history typed;
         lines_pos := !lines_count;
         Buffer.add_buffer input line; Buffer.add_char input '\n'; Buffer.clear line
       | '\127' | '\b' ->
         let s = Buffer.contents line in
         if s <> "" then begin
           let j = ref (String.length s - 1) in
           while !j > 0 && Char.code s.[!j] land 0xC0 = 0x80 do decr j done;
           Buffer.clear line; Buffer.add_string line (String.sub s 0 !j);
           if !echo then output "\b \b"
         end
       | '\004' ->
         if Buffer.length line = 0 then eof := true
         else (Buffer.add_buffer input line; Buffer.clear line)
       | c when Char.code c < 0x20 -> ()
       | c ->
         Buffer.add_char line c;
         if !echo then output_byte c);
      incr i
    done
  end

let () =
  let me = Mynos.getpid () in
  let name = Printf.sprintf "term%d" me in
  let port = Mynos.register name in
  let w = Display.window ~title:"Terminal" (!cols * cw + 2 * margin + bar_w) (height ()) in
  window := Some w;
  (* resizable, down to 20 x 5 *)
  (try Display.set_resizable w (20 * cw + 2 * margin + bar_w) (5 * ch + 2 * margin)
   with Ipc.Remote_error _ -> ());
  Gfx.fill w.Display.pixels 0 0 w.pixels.Gfx.width w.pixels.Gfx.height default_bg;
  Mutex.lock lock; render (); Mutex.unlock lock;
  ignore (Domain.spawn (fun () -> serve port));
  let env = Array.append
      (Array.of_list (List.filter (fun kv ->
           not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                  [ "MYNOS_CONSOLE"; "MYNOS_STDIN"; "MYNOS_STDOUT"; "MYNOS_STDERR" ]))
           (Array.to_list (Mynos.environment ()))))
      [| "MYNOS_CONSOLE=" ^ name; "PATH=/disk/bin:/"; "HOME=/disk"; "OCAMLLIB=/" |] in
  let child = Mynos.spawn ~env "ocamlrun" [| "ocamlrun"; "/sh.byte" |] in
  let alive () = match Mynos.process_info child with
    | Some i -> i.Mynos.alive | None -> false | exception Mynos.Error _ -> false in
  let current () = match !window with Some w -> w | None -> w in
  let right_was = ref false in
  (* the left button: a drag selects, a double click a word; copied when
     let go *)
  let left_was = ref false and dragging = ref false and word = ref false in
  let press_xy = ref (0, 0) and last_press = ref 0. in
  let point x y =
    let r = max 0 (min (!rows - 1) ((y - margin) / ch)) in
    let c = max 0 (min !cols ((x - margin + cw / 2) / cw)) in
    (!scrolled + r - !view, c) in
  let mouse x y buttons =
    let down = buttons land 1 <> 0 in
    if down && not !left_was && x < bar_x () then begin
      let now = Mynos.uptime () and (lx, ly) = !press_xy in
      let double = now -. !last_press < 0.4 && abs (x - lx) < 5 && abs (y - ly) < 5 in
      last_press := now; press_xy := (x, y);
      dragging := false; word := false;
      if !sel_shown then (sel_shown := false; all_dirty := true);
      let (id, _) = point x y in
      if double then begin
        (* the word under the pointer: what is not a space nor a bracket *)
        let line = line_of id in
        let i = max 0 ((x - margin) / cw) in
        let is_word j = j < Array.length line
                        && not (List.mem line.(j).c [ " "; "("; ")"; "["; "]"; "{"; "}"; "<"; ">";
                                                      "\""; "'"; ","; ";"; "`" ]) in
        if is_word i then begin
          let a = ref i and b = ref (i + 1) in
          while !a > 0 && is_word (!a - 1) do decr a done;
          while is_word !b do incr b done;
          sel_a := Some (id, !a); sel_b := (id, !b); sel_shown := true; word := true;
          all_dirty := true;
          Clipboard.set (selection_text ())
        end
      end else begin
        sel_a := Some (point x y); sel_b := point x y
      end
    end else if down && !left_was && not !word && !sel_a <> None then begin
      let (px, py) = !press_xy in
      if abs (x - px) >= 4 || abs (y - py) >= 4 then begin
        (* above or below the grid: the view follows *)
        if y < margin then set_view (!view + 1)
        else if y >= height () - margin then set_view (!view - 1);
        dragging := true; sel_shown := true;
        sel_b := point x y; all_dirty := true
      end
    end else if not down && !left_was && !dragging then begin
      dragging := false;
      let s = selection_text () in
      if s <> "" then Clipboard.set s
    end;
    left_was := down in
  let rec loop () =
    match Display.next_event ~timeout:0.1 (current ()) with
    | Display.Close -> ()
    | ev ->
      Mutex.lock lock;
      (match ev with
       | Display.Key k -> set_view 0; key k
       | Display.Focus f -> focused := f
       | Display.Wheel n -> set_view (!view - 3 * n)
       | Display.Mouse { buttons; _ } when buttons land 2 <> 0 && not !right_was ->
         (* a right click pastes the clipboard (the system's), as if typed *)
         right_was := true;
         let s = Clipboard.get () in
         if s <> "" then begin set_view 0; key s end
       | Display.Resize (nw, nh) ->
         (* the grid that fits, and the window at its exact size *)
         resize ((nw - 2 * margin - bar_w) / cw) ((nh - 2 * margin) / ch);
         (match Display.resize (current ()) (!cols * cw + 2 * margin + bar_w) (height ()) with
          | w' ->
            window := Some w';
            Gfx.fill w'.Display.pixels 0 0 w'.pixels.Gfx.width w'.pixels.Gfx.height default_bg;
            drawn_bar := (-1, -1);
            drawn_cursor := (-1, -1);
            all_dirty := true
          | exception (Ipc.Remote_error _ | Mynos.Error _) -> ())
       | Display.Mouse { x; y; buttons } when buttons land 1 <> 0 && x >= bar_x () && !hist_len > 0 ->
         (* the bar: the thumb follows the pointer *)
         let th = max 24 (height () * !rows / (!rows + !hist_len)) in
         let room = max 1 (height () - th) in
         set_view (!hist_len - (y - th / 2) * !hist_len / room)
       | _ -> ());
      (match ev with Display.Mouse { buttons; _ } when buttons land 2 = 0 -> right_was := false | _ -> ());
      (match ev with Display.Mouse { x; y; buttons } -> mouse x y buttons | _ -> ());
      serve_reads ();
      render ();
      Mutex.unlock lock;
      if ev = Display.Tick && not (alive ()) then () else loop ()
    | exception _ -> () in
  loop ();
  (* closed with sh still running: a hang-up. sh and what it started (a
     program in the foreground, jobs started with &) end with the
     terminal; what has left the tree (a service an agent started, whose
     parent has ended) stays *)
  if alive () then begin
    let ps = try Mynos.processes () with Mynos.Error _ -> [] in
    let rec tree pid =
      pid :: List.concat_map (fun (p : Mynos.process) ->
          if p.parent = pid then tree p.p_pid else []) ps in
    List.iter (fun pid -> try Mynos.kill pid with Mynos.Error _ -> ()) (tree child)
  end;
  Display.destroy (current ());
  exit 0
