(* Textarea: a multi-line text box for Gui windows: see textarea.mli.

   Positions are a line (from 0, inside) and a byte offset in it; what is
   shown is in columns (a character one column, a tab to the next multiple
   of 8): [col] and [byte_at] convert. *)

type highlighter = {
  start : int;
  colour : int -> string -> (int * int * int) list * int;
}

type mark = { mline : int; first : int; last : int; message : string }

type t = {
  mutable lines : string array;
  mutable cy : int; mutable cx : int;          (* the cursor *)
  mutable ay : int; mutable ax : int;          (* the selection's other end *)
  mutable top : int; mutable left : int;       (* the first line, column shown *)
  mutable want : int;                          (* the column Up and Down keep *)
  mutable undos : (string array * int * int) list;
  mutable redos : (string array * int * int) list;
  mutable last_kind : int;                     (* typing groups its undo *)
  mutable last_time : float;
  mutable modified : bool;
  mutable version : int;
  mutable marks : mark list;
  highlight : highlighter option;
  mutable states : int array;                  (* the state before each line *)
  mutable states_version : int;
  mutable pressing : bool;                     (* the mouse, selecting *)
  mutable bar : bool;                          (* the mouse, on the bar *)
  tab : int option;
  numbers : bool;
  mutable cursor_xy : int * int;
  mutable rows : int;                          (* lines shown, at the last frame *)
  mutable cols : int;
  mutable follow : bool;                       (* scroll to the cursor *)
}

let clipboard = ref ""

(* ---- UTF-8 and columns ---- *)

let is_cont c = Char.code c land 0xC0 = 0x80
let next s i = let i = ref (i + 1) in while !i < String.length s && is_cont s.[!i] do incr i done; !i
let prev s i = let i = ref (i - 1) in while !i > 0 && is_cont s.[!i] do decr i done; max 0 !i

let col s b =
  let c = ref 0 and i = ref 0 in
  while !i < b && !i < String.length s do
    if s.[!i] = '\t' then c := (!c / 8 + 1) * 8 else if not (is_cont s.[!i]) then incr c;
    incr i
  done;
  !c

(* the byte where column [v] is (the start of the character covering it) *)
let byte_at s v =
  let c = ref 0 and i = ref 0 and n = String.length s in
  let stop = ref false in
  while not !stop && !i < n do
    let w = if s.[!i] = '\t' then (!c / 8 + 1) * 8 - !c else 1 in
    if !c + w > v then stop := true
    else begin c := !c + w; i := next s !i end
  done;
  !i

(* [n] columns of a line as shown (no tabs left) from column [c0] *)
let slice e c0 n =
  let i = ref 0 and c = ref 0 and len = String.length e in
  while !i < len && !c < c0 do i := next e !i; incr c done;
  let j = ref !i and k = ref 0 in
  while !j < len && !k < n do j := next e !j; incr k done;
  String.sub e !i (!j - !i)

(* ---- the text ---- *)

let split s = Array.of_list (String.split_on_char '\n' s)

let create ?tab ?(numbers = false) ?highlight s =
  { lines = split s; cy = 0; cx = 0; ay = 0; ax = 0; top = 0; left = 0; want = 0;
    undos = []; redos = []; last_kind = 0; last_time = 0.; modified = false; version = 0;
    marks = []; highlight; states = [||]; states_version = -1; pressing = false; bar = false;
    tab; numbers; cursor_xy = (0, 0); rows = 1; cols = 1; follow = false }

let text t = String.concat "\n" (Array.to_list t.lines)
let modified t = t.modified
let set_modified t b = t.modified <- b
let version t = t.version
let lines t = Array.length t.lines
let line t n = if n >= 1 && n <= Array.length t.lines then t.lines.(n - 1) else ""

let changed t = t.modified <- true; t.version <- t.version + 1; t.follow <- true

(* before a change: what to undo. Typing (kind 1) and erasing (2) make one
   step while they go on; anything else (3) is a step of its own *)
let snapshot t kind =
  let now = Mynos.uptime () in
  if kind = 3 || kind <> t.last_kind || now -. t.last_time > 1.0 then begin
    t.undos <- (Array.copy t.lines, t.cy, t.cx) :: t.undos;
    if List.length t.undos > 200 then t.undos <- List.filteri (fun i _ -> i < 200) t.undos
  end;
  t.last_kind <- kind; t.last_time <- now;
  t.redos <- []

let restore t (l, y, x) =
  t.lines <- l; t.cy <- y; t.cx <- x; t.ay <- y; t.ax <- x; changed t

let undo t =
  match t.undos with
  | s :: rest ->
    t.redos <- (Array.copy t.lines, t.cy, t.cx) :: t.redos; t.undos <- rest;
    t.last_kind <- 0; restore t s
  | [] -> ()

let redo t =
  match t.redos with
  | s :: rest ->
    t.undos <- (Array.copy t.lines, t.cy, t.cx) :: t.undos; t.redos <- rest;
    t.last_kind <- 0; restore t s
  | [] -> ()

let clamp t =
  let n = Array.length t.lines in
  t.cy <- max 0 (min (n - 1) t.cy);
  t.cx <- max 0 (min (String.length t.lines.(t.cy)) t.cx);
  t.ay <- max 0 (min (n - 1) t.ay);
  t.ax <- max 0 (min (String.length t.lines.(t.ay)) t.ax)

let has_selection t = t.ay <> t.cy || t.ax <> t.cx

(* the selection, its start before its end *)
let ordered t =
  if (t.ay, t.ax) < (t.cy, t.cx) then (t.ay, t.ax, t.cy, t.cx) else (t.cy, t.cx, t.ay, t.ax)

let get t (y1, x1, y2, x2) =
  if y1 = y2 then String.sub t.lines.(y1) x1 (x2 - x1)
  else begin
    let b = Buffer.create 256 in
    Buffer.add_string b (String.sub t.lines.(y1) x1 (String.length t.lines.(y1) - x1));
    for y = y1 + 1 to y2 - 1 do Buffer.add_char b '\n'; Buffer.add_string b t.lines.(y) done;
    Buffer.add_char b '\n';
    Buffer.add_string b (String.sub t.lines.(y2) 0 x2);
    Buffer.contents b
  end

let selection t = if has_selection t then Some (get t (ordered t)) else None

(* the range replaced by [s]; the cursor after it *)
let replace t (y1, x1, y2, x2) s =
  let before = String.sub t.lines.(y1) 0 x1
  and after = String.sub t.lines.(y2) x2 (String.length t.lines.(y2) - x2) in
  let ins = split s in
  let k = Array.length ins in
  ins.(0) <- before ^ ins.(0);
  let cx = String.length ins.(k - 1) in
  ins.(k - 1) <- ins.(k - 1) ^ after;
  let n = Array.length t.lines in
  t.lines <- Array.concat [ Array.sub t.lines 0 y1; ins; Array.sub t.lines (y2 + 1) (n - y2 - 1) ];
  t.cy <- y1 + k - 1; t.cx <- cx; t.ay <- t.cy; t.ax <- t.cx;
  changed t

let insert_kind t kind s =
  snapshot t kind;
  replace t (if has_selection t then ordered t else (t.cy, t.cx, t.cy, t.cx)) s;
  t.want <- col t.lines.(t.cy) t.cx

let insert t s = insert_kind t 3 s

let set_text t s =
  snapshot t 3;
  t.lines <- split s; t.cy <- 0; t.cx <- 0; t.ay <- 0; t.ax <- 0; t.top <- 0; t.left <- 0;
  changed t

let replace_lines t first last s =
  let n = Array.length t.lines in
  let first = max 1 (min (n + 1) first) in
  let last = max (first - 1) (min n last) in
  snapshot t 3;
  if last < first then begin
    (* an insertion before line [first] *)
    let ins = split s in
    let at = first - 1 in
    t.lines <- Array.concat [ Array.sub t.lines 0 at; ins; Array.sub t.lines at (n - at) ];
    t.cy <- at; t.cx <- 0; t.ay <- at; t.ax <- 0; changed t
  end else begin
    replace t (first - 1, 0, last - 1, String.length t.lines.(last - 1)) s;
    t.ay <- first - 1; t.ax <- 0
  end

let delete_selection t kind =
  if has_selection t then begin snapshot t kind; replace t (ordered t) "" end

(* ---- moving ---- *)

let goto t line column =
  t.cy <- line - 1; clamp t;
  t.cx <- byte_at t.lines.(t.cy) (column - 1); t.ay <- t.cy; t.ax <- t.cx;
  t.want <- column - 1; t.follow <- true

let cursor t = (t.cy + 1, col t.lines.(t.cy) t.cx + 1)

let left t =
  if t.cx > 0 then t.cx <- prev t.lines.(t.cy) t.cx
  else if t.cy > 0 then begin t.cy <- t.cy - 1; t.cx <- String.length t.lines.(t.cy) end

let right t =
  if t.cx < String.length t.lines.(t.cy) then t.cx <- next t.lines.(t.cy) t.cx
  else if t.cy < Array.length t.lines - 1 then begin t.cy <- t.cy + 1; t.cx <- 0 end

let vertical t d =
  t.cy <- max 0 (min (Array.length t.lines - 1) (t.cy + d));
  t.cx <- byte_at t.lines.(t.cy) t.want

(* Home: the first character that is not a space, then the line's start *)
let home t =
  let l = t.lines.(t.cy) in
  let i = ref 0 in
  while !i < String.length l && (l.[!i] = ' ' || l.[!i] = '\t') do incr i done;
  t.cx <- if t.cx = !i then 0 else !i

let find t s =
  if s = "" then false
  else begin
    let n = Array.length t.lines in
    let found = ref None in
    let search y from =
      let l = t.lines.(y) and k = String.length s in
      let rec go i = if i + k > String.length l then None
        else if String.sub l i k = s then Some i else go (i + 1) in
      go from in
    let start_x = if has_selection t then max t.cx t.ax else t.cx in
    let k = ref 0 in
    while !found = None && !k <= n do
      let y = (t.cy + !k) mod n in
      let from = if !k = 0 then start_x else 0 in
      (match search y from with Some i -> found := Some (y, i) | None -> ());
      incr k
    done;
    match !found with
    | Some (y, i) ->
      t.ay <- y; t.ax <- i; t.cy <- y; t.cx <- i + String.length s;
      t.want <- col t.lines.(y) t.cx; t.follow <- true; true
    | None -> false
  end

let word_before_cursor t =
  let l = t.lines.(t.cy) in
  let ok c = match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' | '.' -> true | _ -> false in
  let i = ref t.cx in
  while !i > 0 && ok l.[!i - 1] do decr i done;
  String.sub l !i (t.cx - !i)

let cursor_xy t = t.cursor_xy

let set_marks t m = t.marks <- m
let mark_at_cursor t =
  List.find_opt (fun m ->
      m.mline = t.cy + 1
      && t.cx >= m.first && (m.last <= m.first || t.cx <= m.last)) t.marks

(* ---- keys ---- *)

let key t k =
  let moved shift =
    if not shift then begin t.ay <- t.cy; t.ax <- t.cx end;
    t.follow <- true; t.last_kind <- 0 in
  let keep_col () = t.want <- col t.lines.(t.cy) t.cx in
  match k with
  | "\027[D" | "\027[1;2D" -> left t; keep_col (); moved (k <> "\027[D")
  | "\027[C" | "\027[1;2C" -> right t; keep_col (); moved (k <> "\027[C")
  | "\027[A" | "\027[1;2A" -> vertical t (-1); moved (k <> "\027[A")
  | "\027[B" | "\027[1;2B" -> vertical t 1; moved (k <> "\027[B")
  | "\027[H" | "\027[1;2H" -> home t; keep_col (); moved (k <> "\027[H")
  | "\027[F" | "\027[1;2F" -> t.cx <- String.length t.lines.(t.cy); keep_col (); moved (k <> "\027[F")
  | "\027[5~" -> vertical t (- (max 1 (t.rows - 1))); moved false
  | "\027[6~" -> vertical t (max 1 (t.rows - 1)); moved false
  | "\001" ->                                           (* Ctrl-A: all *)
    t.ay <- 0; t.ax <- 0; t.cy <- Array.length t.lines - 1;
    t.cx <- String.length t.lines.(t.cy); t.follow <- true
  | "\003" -> (match selection t with Some s -> clipboard := s | None -> ())
  | "\024" ->                                           (* Ctrl-X *)
    (match selection t with Some s -> clipboard := s; delete_selection t 3 | None -> ())
  | "\022" -> if !clipboard <> "" then insert_kind t 3 !clipboard   (* Ctrl-V *)
  | "\026" -> undo t
  | "\025" -> redo t
  | "\r" | "\n" ->
    (* Enter: the new line keeps this one's indentation *)
    let l = t.lines.(t.cy) in
    let i = ref 0 in
    while !i < String.length l && !i < t.cx && (l.[!i] = ' ' || l.[!i] = '\t') do incr i done;
    insert_kind t 3 ("\n" ^ String.sub l 0 !i)
  | "\t" ->
    (match t.tab with
     | Some n ->
       let c = col t.lines.(t.cy) t.cx in
       insert_kind t 1 (String.make (n - c mod n) ' ')
     | None -> insert_kind t 1 "\t")
  | "\127" | "\b" ->
    if has_selection t then delete_selection t 2
    else if t.cx > 0 || t.cy > 0 then begin
      snapshot t 2;
      let y = t.cy and x = t.cx in
      left t;
      replace t (t.cy, t.cx, y, x) ""
    end;
    keep_col ()
  | "\027[3~" ->
    if has_selection t then delete_selection t 2
    else begin
      let y = t.cy and x = t.cx in
      right t;
      if (t.cy, t.cx) <> (y, x) then begin
        let y2 = t.cy and x2 = t.cx in
        t.cy <- y; t.cx <- x;
        snapshot t 2; replace t (y, x, y2, x2) ""
      end
    end;
    keep_col ()
  | k when String.length k > 0 && k.[0] >= ' ' && k.[0] <> '\127' -> insert_kind t 1 k
  | _ -> ()                                              (* the program's *)

(* ---- drawing ---- *)

let bar_w = 10
let selection_colour = 0xCFE0F3

(* the state before each line, up to [upto] (computed again after a change) *)
let states t upto =
  match t.highlight with
  | None -> ()
  | Some h ->
    if t.states_version <> t.version || Array.length t.states <> Array.length t.lines then begin
      t.states <- Array.make (Array.length t.lines) h.start;
      t.states_version <- t.version;
      let s = ref h.start in
      for y = 0 to Array.length t.lines - 1 do
        t.states.(y) <- !s;
        s := snd (h.colour !s (Gfx.expand_tabs t.lines.(y)))
      done
    end;
    ignore upto

let frame ui id t x y w h =
  let g = ui.Gui.g in
  let cw = Gfx.char_w and ch = Gfx.char_h in
  let n = Array.length t.lines in
  let gutter = if t.numbers then (String.length (string_of_int n) + 2) * cw else 4 in
  let tx = x + gutter and tw = w - gutter - bar_w in
  t.rows <- max 1 (h / ch); t.cols <- max 1 (tw / cw);
  let inside px py = px >= x && py >= y && px < x + w - bar_w && py < y + h in
  let pos px py =
    let ly = max 0 (min (n - 1) (t.top + (py - y) / ch)) in
    let c = max 0 (t.left + (px - tx + cw / 2) / cw) in
    (ly, byte_at t.lines.(ly) c) in
  (* the mouse: a press gives the keys and places the cursor; a drag selects *)
  let px, py = ui.Gui.press in
  if ui.Gui.buttons land 1 <> 0 && not t.pressing && not t.bar && Gui.hovered ui x y w h then begin
    if inside px py then begin
      ui.Gui.field <- id;
      let ly, lx = pos px py in
      t.cy <- ly; t.cx <- lx; t.ay <- ly; t.ax <- lx; t.want <- col t.lines.(ly) lx;
      t.pressing <- true; t.last_kind <- 0
    end else if px >= x + w - bar_w && py >= y && px < x + w && py < y + h then begin
      ui.Gui.field <- id; t.bar <- true
    end
  end;
  if ui.Gui.buttons land 1 = 0 then begin t.pressing <- false; t.bar <- false end;
  if t.pressing then begin
    let ly, lx = pos ui.Gui.mx ui.Gui.my in
    t.cy <- ly; t.cx <- lx; t.want <- col t.lines.(ly) lx;
    if ui.Gui.my < y then t.top <- max 0 (t.top - 1)
    else if ui.Gui.my >= y + h then t.top <- min (max 0 (n - 1)) (t.top + 1)
  end;
  if t.bar then
    t.top <- max 0 (min (max 0 (n - t.rows)) ((ui.Gui.my - y) * n / max 1 h - t.rows / 2));
  if ui.Gui.wheel <> 0 && Gui.hovered ui x y w h then begin
    t.top <- max 0 (min (max 0 (n - t.rows / 2)) (t.top + 3 * ui.Gui.wheel));
    ui.Gui.wheel <- 0
  end;
  (* the keys *)
  if ui.Gui.field = id then begin
    List.iter (key t) ui.Gui.keys;
    clamp t
  end;
  let n = Array.length t.lines in
  (* the cursor in view, after a key or an edit *)
  if t.follow then begin
    t.follow <- false;
    if t.cy < t.top then t.top <- t.cy
    else if t.cy >= t.top + t.rows then t.top <- t.cy - t.rows + 1;
    let c = col t.lines.(t.cy) t.cx in
    if c < t.left then t.left <- max 0 (c - 8)
    else if c >= t.left + t.cols then t.left <- c - t.cols + 8
  end;
  t.top <- max 0 (min t.top (max 0 (n - 1)));
  (* the box *)
  Gfx.fill g x y w h 0xFFFFFF;
  if t.numbers then Gfx.fill g x y (gutter - 4) h 0xF0F3F6;
  let sy1, sx1, sy2, sx2 = ordered t in
  let sel = has_selection t in
  states t (t.top + t.rows);
  Gfx.with_clip x y (w - bar_w) h (fun () ->
      for r = 0 to t.rows do
        let ly = t.top + r in
        if ly < n then begin
          let l = t.lines.(ly) in
          let ry = y + r * ch in
          if t.numbers then
            ignore (Gfx.text g x ry (Printf.sprintf "%*d" (gutter / cw - 1) (ly + 1)) 0x9AA5B1);
          (* the selection's part of this line *)
          if sel && ly >= sy1 && ly <= sy2 then begin
            let c1 = if ly = sy1 then col l sx1 else 0
            and c2 = if ly = sy2 then col l sx2 else col l (String.length l) + 1 in
            let a = max 0 (c1 - t.left) and b = c2 - t.left in
            if b > a then Gfx.fill g (tx + a * cw) ry ((b - a) * cw) ch selection_colour
          end;
          let e = Gfx.expand_tabs l in
          let shown = slice e t.left (t.cols + 1) in
          let ncells = Gfx.cells shown in
          (* colours, a cell at a time, then drawn in runs *)
          let colours = Array.make (max 1 ncells) Gui.foreground in
          (match t.highlight with
           | Some hl when ly < Array.length t.states ->
             List.iter (fun (c0, k, colour) ->
                 for c = max c0 t.left to min (c0 + k) (t.left + ncells) - 1 do
                   colours.(c - t.left) <- colour
                 done) (fst (hl.colour t.states.(ly) e))
           | _ -> ());
          let chars = Array.make ncells "" in
          let i = ref 0 and k = ref 0 in
          while !i < String.length shown && !k < ncells do
            let j = next shown !i in chars.(!k) <- String.sub shown !i (j - !i); i := j; incr k
          done;
          let c = ref 0 in
          while !c < ncells do
            let c0 = !c and colour = colours.(!c) in
            let b = Buffer.create 32 in
            while !c < ncells && colours.(!c) = colour do Buffer.add_string b chars.(!c); incr c done;
            ignore (Gfx.text g (tx + c0 * cw) ry (Buffer.contents b) colour)
          done;
          (* marks: a red line under them *)
          List.iter (fun m ->
              if m.mline = ly + 1 then begin
                let c1 = col l m.first in
                let c2 = if m.last <= m.first then max (c1 + 1) (col l (String.length l)) else col l m.last in
                let a = max 0 (c1 - t.left) and b = c2 - t.left in
                if b > a then Gfx.fill g (tx + a * cw) (ry + ch - 2) ((b - a) * cw) 2 0xD32F2F
              end) t.marks
        end
      done;
      (* the cursor *)
      let cc = col t.lines.(t.cy) t.cx - t.left and cr = t.cy - t.top in
      t.cursor_xy <- (tx + cc * cw, y + cr * ch);
      if ui.Gui.field = id && cr >= 0 && cr < t.rows + 1 && cc >= 0 then
        Gfx.fill g (tx + cc * cw) (y + cr * ch) 2 ch Gui.accent);
  (* the bar *)
  Gfx.fill g (x + w - bar_w) y bar_w h 0xEDF1F4;
  if n > t.rows then begin
    let th = max 20 (h * t.rows / n) in
    let ty = y + (h - th) * t.top / max 1 (n - t.rows) in
    Gfx.fill g (x + w - bar_w + 2) (min (y + h - th) ty) (bar_w - 4) th
      (if t.bar then 0x7F8C98 else 0xA9B4BE)
  end;
  Gfx.rect g x y w h (if ui.Gui.field = id then Gui.accent else 0xD5DBE1)

(* ---- OCaml's colours ---- *)

let keywords = [ "and"; "as"; "assert"; "begin"; "class"; "constraint"; "do"; "done";
                 "downto"; "else"; "end"; "exception"; "external"; "false"; "for"; "fun";
                 "function"; "functor"; "if"; "in"; "include"; "inherit"; "initializer";
                 "lazy"; "let"; "match"; "method"; "module"; "mutable"; "new"; "nonrec";
                 "object"; "of"; "open"; "or"; "private"; "rec"; "sig"; "struct"; "then";
                 "to"; "true"; "try"; "type"; "val"; "virtual"; "when"; "while"; "with";
                 "lor"; "land"; "lxor"; "lsl"; "lsr"; "asr"; "mod"; "effect" ]

let c_keyword = 0x8E3BAF and c_string = 0x2E7D32 and c_comment = 0x8A96A3
and c_number = 0xB35C00 and c_module = 0x1F5F99

(* the state: 0 code, n > 0 inside n nested comments, -1 inside a string *)
let ocaml_line state e =
  let n = String.length e in
  let spans = ref [] in
  let add a b c = if b > a then spans := (a, b - a, c) :: !spans in
  (* columns are characters: count them as the bytes go *)
  let colof = Array.make (n + 1) 0 in
  let c = ref 0 in
  for i = 0 to n - 1 do colof.(i) <- !c; if not (is_cont e.[i]) then incr c done;
  colof.(n) <- !c;
  let st = ref state and i = ref 0 in
  let start = ref 0 in
  while !i < n do
    if !st > 0 then begin
      (* in a comment, until its end (nested ones counted) *)
      start := !i;
      while !i < n && !st > 0 do
        if !i + 1 < n && e.[!i] = '(' && e.[!i + 1] = '*' then (incr st; i := !i + 2)
        else if !i + 1 < n && e.[!i] = '*' && e.[!i + 1] = ')' then (decr st; i := !i + 2)
        else incr i
      done;
      add colof.(!start) colof.(!i) c_comment
    end else if !st < 0 then begin
      start := !i;
      while !i < n && !st < 0 do
        if e.[!i] = '\\' then i := !i + 2
        else if e.[!i] = '"' then (st := 0; incr i)
        else incr i
      done;
      i := min !i n;
      add colof.(!start) colof.(!i) c_string
    end else begin
      let ch = e.[!i] in
      if ch = '(' && !i + 1 < n && e.[!i + 1] = '*' && not (!i + 2 < n && e.[!i + 2] = ')') then begin
        (* a comment begins: its "(*" coloured, the rest by the branch above *)
        add colof.(!i) colof.(!i + 2) c_comment;
        st := 1; i := !i + 2
      end
      else if ch = '"' then (st := -1; start := !i; incr i;
                             (* the string's opening quote is coloured with it *)
                             spans := (colof.(!start), 1, c_string) :: !spans)
      else if ch = '\'' && !i + 2 < n && e.[!i + 2] = '\'' then
        (add colof.(!i) colof.(!i + 3) c_string; i := !i + 3)
      else if ch = '\'' && !i + 3 < n && e.[!i + 1] = '\\' && e.[!i + 3] = '\'' then
        (add colof.(!i) colof.(!i + 4) c_string; i := !i + 4)
      else if ch >= '0' && ch <= '9' then begin
        start := !i;
        while !i < n && (match e.[!i] with '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | 'x' | 'o'
                                           | '_' | '.' | 'l' | 'L' | 'n' -> true | _ -> false) do incr i done;
        add colof.(!start) colof.(!i) c_number
      end else if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch = '_' then begin
        start := !i;
        while !i < n && (match e.[!i] with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
                                           | _ -> false) do incr i done;
        let w = String.sub e !start (!i - !start) in
        if List.mem w keywords then add colof.(!start) colof.(!i) c_keyword
        else if ch >= 'A' && ch <= 'Z' then add colof.(!start) colof.(!i) c_module
      end else incr i
    end
  done;
  (List.rev !spans, !st)

let ocaml = { start = 0; colour = ocaml_line }
