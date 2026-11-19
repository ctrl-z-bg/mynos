(* edit: a small full-screen text editor for MyNOS, in OCaml, on Notty
   (third_party/notty, with its MyNOS backend).

     edit FILE

   Arrows, Home, End, PgUp, PgDn move; typing inserts; Backspace, Delete
   and Enter join and split lines. Ctrl-S saves, Ctrl-Q quits (twice if
   there are unsaved changes), Ctrl-K cuts the line, Ctrl-U pastes it,
   Ctrl-F searches (Enter: next match, Esc: done). Tabs are expanded to
   spaces when a file is read.

   Text is UTF-8: lines are kept as UTF-8 strings, and the cursor, the
   columns and the editing keys count characters, not bytes (an accented
   letter is two bytes). Bytes that are not UTF-8 are shown as '?' and
   kept as they are. *)

open Notty
module Term = Notty_mynos.Term

(* ---- UTF-8: characters in a line ---- *)

(* the byte where character [i] starts (the length, past the end) *)
let byte_of s i =
  let n = String.length s in
  let rec go b k =
    if k = i || b >= n then min b n
    else go (b + Uchar.utf_decode_length (String.get_utf_8_uchar s b)) (k + 1) in
  go 0 0

(* how many characters *)
let length s =
  let n = String.length s in
  let rec go b k =
    if b >= n then k
    else go (b + Uchar.utf_decode_length (String.get_utf_8_uchar s b)) (k + 1) in
  go 0 0

(* the characters [from, from + count) *)
let chars s from count =
  let a = byte_of s from in
  let b = byte_of s (from + count) in
  if a >= b then "" else String.sub s a (b - a)

let utf_8 u =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b u;
  Buffer.contents b

type editor = {
  file : string;
  lines : string Dynarray.t;
  mutable cy : int;               (* the cursor: line and column *)
  mutable cx : int;
  mutable top : int;              (* first line and column shown *)
  mutable left : int;
  mutable dirty : bool;
  mutable message : string;
  mutable cut : string option;
  mutable quit_armed : bool;
}

let expand_tabs s =
  if not (String.contains s '\t') then s
  else begin
    let b = Buffer.create (String.length s + 16) in
    let col = ref 0 in                        (* in characters *)
    String.iter (fun c ->
        if c = '\t' then begin
          let k = 8 - !col mod 8 in
          Buffer.add_string b (String.make k ' ');
          col := !col + k
        end else begin
          Buffer.add_char b c;
          (* a character starts at every byte but UTF-8's continuations *)
          if Char.code c land 0xC0 <> 0x80 then incr col
        end) s;
    Buffer.contents b
  end

let load file =
  let lines = Dynarray.create () in
  (match In_channel.with_open_bin file In_channel.input_all with
   | text ->
     let ls = String.split_on_char '\n' text in
     (* a final newline does not start another line *)
     let ls = match List.rev ls with "" :: r when r <> [] -> List.rev r | _ -> ls in
     List.iter (fun l ->
         let l = if String.ends_with ~suffix:"\r" l
           then String.sub l 0 (String.length l - 1) else l in
         Dynarray.add_last lines (expand_tabs l)) ls
   | exception Sys_error _ -> Dynarray.add_last lines "");
  lines

let save e =
  match
    Out_channel.with_open_bin e.file (fun oc ->
        Dynarray.iter (fun l -> output_string oc l; output_char oc '\n') e.lines)
  with
  | () ->
    e.dirty <- false;
    e.message <- Printf.sprintf "saved %s (%d lines)" e.file (Dynarray.length e.lines)
  | exception Sys_error m -> e.message <- "cannot save: " ^ m

let line e = Dynarray.get e.lines e.cy
let set_line e s = Dynarray.set e.lines e.cy s; e.dirty <- true

let clamp e =
  let n = Dynarray.length e.lines in
  e.cy <- max 0 (min e.cy (n - 1));
  e.cx <- max 0 (min e.cx (length (line e)))

(* ---- editing ---- *)

let insert e s =
  let l = line e in
  let b = byte_of l e.cx in
  set_line e (String.sub l 0 b ^ s ^ String.sub l b (String.length l - b));
  e.cx <- e.cx + length s

let newline e =
  let l = line e in
  let b = byte_of l e.cx in
  set_line e (String.sub l 0 b);
  Dynarray.add_last e.lines "";
  (* shift the lines below down by one *)
  for i = Dynarray.length e.lines - 1 downto e.cy + 2 do
    Dynarray.set e.lines i (Dynarray.get e.lines (i - 1))
  done;
  Dynarray.set e.lines (e.cy + 1) (String.sub l b (String.length l - b));
  e.cy <- e.cy + 1;
  e.cx <- 0

let remove_line e i =
  for j = i to Dynarray.length e.lines - 2 do
    Dynarray.set e.lines j (Dynarray.get e.lines (j + 1))
  done;
  ignore (Dynarray.pop_last e.lines);
  if Dynarray.length e.lines = 0 then Dynarray.add_last e.lines "";
  e.dirty <- true

let backspace e =
  if e.cx > 0 then begin
    let l = line e in
    let a = byte_of l (e.cx - 1) and b = byte_of l e.cx in
    set_line e (String.sub l 0 a ^ String.sub l b (String.length l - b));
    e.cx <- e.cx - 1
  end else if e.cy > 0 then begin
    let prev = Dynarray.get e.lines (e.cy - 1) and l = line e in
    Dynarray.set e.lines (e.cy - 1) (prev ^ l);
    remove_line e e.cy;
    e.cy <- e.cy - 1;
    e.cx <- length prev
  end

let delete e =
  if e.cx < length (line e) then begin
    e.cx <- e.cx + 1;
    backspace e
  end else if e.cy < Dynarray.length e.lines - 1 then begin
    e.cy <- e.cy + 1;
    e.cx <- 0;
    backspace e
  end

let cut_line e =
  e.cut <- Some (line e);
  remove_line e e.cy;
  e.cx <- 0;
  clamp e

let paste e =
  match e.cut with
  | None -> e.message <- "nothing to paste (Ctrl-K cuts a line)"
  | Some l ->
    e.cx <- 0;
    newline e;
    e.cy <- e.cy - 1;
    set_line e l

(* the next line from (cy, cx) containing s *)
let search e s =
  let n = Dynarray.length e.lines in
  let find_from l start =
    let ls = String.length l and k = String.length s in
    let rec go i =
      if i + k > ls then None
      else if String.sub l i k = s then Some i
      else go (i + 1) in
    go start in
  let rec go i =
    if i > n then false
    else
      let y = (e.cy + i) mod n in
      let l = Dynarray.get e.lines y in
      let start = if i = 0 then byte_of l (e.cx + 1) else 0 in
      match find_from l start with
      | Some x -> e.cy <- y; e.cx <- length (String.sub l 0 x); true
      | None -> go (i + 1) in
  s <> "" && go 0

(* ---- display ---- *)

let rows (_, h) = h - 2           (* text lines: all but status and message *)

let scroll e size =
  let w, _ = size and h = rows size in
  if e.cy < e.top then e.top <- e.cy;
  if e.cy >= e.top + h then e.top <- e.cy - h + 1;
  if e.cx < e.left then e.left <- e.cx;
  if e.cx >= e.left + w then e.left <- e.cx - w + 1

(* columns [left, left + w) of a line, in characters *)
let visible s left w = chars s left w

(* what Notty can draw: control characters and bytes that are not UTF-8
   become '?', one for each character, so that columns stay right *)
let printable s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then begin
      let d = String.get_utf_8_uchar s i in
      let u = Uchar.utf_decode_uchar d in
      if Uchar.utf_decode_is_valid d && Uchar.to_int u >= 0x20
         && not (Uchar.to_int u >= 0x7F && Uchar.to_int u < 0xA0)
      then Buffer.add_utf_8_uchar b u
      else Buffer.add_char b '?';
      go (i + Uchar.utf_decode_length d)
    end in
  go 0;
  Buffer.contents b

let render e size =
  let w, _ = size and h = rows size in
  let text =
    I.vcat (List.init h (fun i ->
        let y = e.top + i in
        if y < Dynarray.length e.lines then
          I.string A.empty (printable (visible (Dynarray.get e.lines y) e.left w))
        else I.string A.(fg lightblue) "~")) in
  let status =
    Printf.sprintf " %s%s  -  line %d/%d, column %d " e.file
      (if e.dirty then " (modified)" else "") (e.cy + 1)
      (Dynarray.length e.lines) (e.cx + 1) in
  let status = I.string A.(st reverse) (visible (status ^ String.make w ' ') 0 w) in
  let message = I.string A.empty (visible (printable e.message) 0 w) in
  I.(text <-> status <-> message)

(* ---- the main loop ---- *)

let prompt term e label =
  let rec loop acc =
    e.message <- label ^ acc;
    Term.image term (render e (Term.size term));
    Term.cursor term (Some (length e.message, rows (Term.size term) + 1));
    match Term.event term with
    | `Key (`Enter, _) -> Some acc
    | `Key (`Escape, _) | `End -> None
    | `Key (`ASCII 'G', [`Ctrl]) -> None
    | `Key (`Backspace, _) ->
      loop (if acc = "" then acc else String.sub acc 0 (byte_of acc (length acc - 1)))
    | `Key (`ASCII c, []) when c >= ' ' -> loop (acc ^ String.make 1 c)
    | `Key (`Uchar u, []) -> loop (acc ^ utf_8 u)
    | _ -> loop acc in
  loop ""

let find term e =
  let rec next s =
    if search e s then begin
      scroll e (Term.size term);
      e.message <- "found: Enter for the next, Esc to stop";
      Term.image term (render e (Term.size term));
      Term.cursor term (Some (e.cx - e.left, e.cy - e.top));
      match Term.event term with
      | `Key (`Enter, _) -> next s
      | _ -> e.message <- ""
    end else e.message <- "not found: " ^ s in
  match prompt term e "search: " with
  | Some s -> next s
  | None -> e.message <- ""

let main file =
  let e = { file; lines = load file; cy = 0; cx = 0; top = 0; left = 0;
            dirty = false; cut = None; quit_armed = false;
            message = "Ctrl-S save  Ctrl-Q quit  Ctrl-K cut  Ctrl-U paste  Ctrl-F find" } in
  let term = Term.create () in
  let rec loop () =
    let size = Term.size term in
    scroll e size;
    Term.image term (render e size);
    Term.cursor term (Some (e.cx - e.left, e.cy - e.top));
    let ev = Term.event term in
    let quit_was_armed = e.quit_armed in
    e.quit_armed <- false;
    match ev with
    | `End -> ()
    | `Key (`ASCII 'Q', [`Ctrl]) ->
      if e.dirty && not quit_was_armed then begin
        e.message <- "unsaved changes: Ctrl-Q again to quit, Ctrl-S to save";
        e.quit_armed <- true;
        loop ()
      end
    | `Key (k, mods) ->
      (match k, mods with
       | `ASCII 'S', [`Ctrl] -> save e
       | `ASCII 'K', [`Ctrl] -> cut_line e
       | `ASCII 'U', [`Ctrl] -> paste e
       | `ASCII 'F', [`Ctrl] -> find term e
       | `Arrow `Up, _ -> e.cy <- e.cy - 1
       | `Arrow `Down, _ -> e.cy <- e.cy + 1
       | `Arrow `Left, _ ->
         if e.cx > 0 then e.cx <- e.cx - 1
         else if e.cy > 0 then (e.cy <- e.cy - 1; e.cx <- max_int)
       | `Arrow `Right, _ ->
         if e.cx < length (line e) then e.cx <- e.cx + 1
         else if e.cy < Dynarray.length e.lines - 1 then (e.cy <- e.cy + 1; e.cx <- 0)
       | `Home, _ -> e.cx <- 0
       | `End, _ -> e.cx <- length (line e)
       | `Page `Up, _ -> e.cy <- e.cy - rows size
       | `Page `Down, _ -> e.cy <- e.cy + rows size
       | `Enter, _ -> newline e
       | `Backspace, _ -> backspace e
       | `Delete, _ -> delete e
       | `Tab, _ -> insert e (String.make (8 - e.cx mod 8) ' ')
       | `ASCII c, [] when c >= ' ' -> insert e (String.make 1 c)
       | `Uchar u, [] -> insert e (utf_8 u)
       | _ -> ());
      clamp e;
      loop ()
    | _ -> loop () in
  loop ();
  Term.release term

let () =
  match Sys.argv with
  | [| _; file |] -> main file
  | _ -> prerr_endline "usage: edit FILE"; exit 2
