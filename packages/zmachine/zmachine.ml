(* zmachine: a Z-machine interpreter (module Zvm), for Infocom's games
   and those written since with Inform: story files .z1 to .z5, .z7, .z8.

     zmachine STORY            in a window (in the graphical session), or
                               in the terminal (outside it)
     zmachine -t STORY         in the terminal
     zmachine NAME             the story of the installed package NAME
                               (/disk/pkg/NAME: zmachine zork1)

   The window keeps what was printed (the wheel, Page Up and Page Down
   scroll it); Up and Down recall the commands typed. SAVE and RESTORE
   ask for a file name (by default the story's, .sav, on /disk). *)

open Term

(* {1 In a window} *)

let cols = 80 and rows = 30
let margin = 8
let width = cols * Gfx.char_w + 2 * margin + 12
let height = rows * Gfx.char_h + 2 * margin

let background = 0x10151C and foreground = 0xD8DEE4 and bright = 0xFFFFFF
let status_bg = 0x2E5E8E

type line = (string * Zvm.style) list

type state = {
  mutable vm : Zvm.vm;
  mutable path : string;
  mutable lines : line list;                 (* the lower window, the last first *)
  mutable col : int;                         (* the last line's length *)
  mutable input : string;
  mutable wants : Zvm.wants;
  mutable history : string list;
  mutable recall : int;
  mutable scroll : int;                      (* lines up from the end *)
  mutable file_default : string;
  mutable ready : bool;                      (* a story chosen *)
}

let add_text st (text, style) =
  let pieces = wrap (cols - 1) st.col text in
  List.iteri (fun i p ->
      if i = 0 then begin
        (match st.lines with
         | l :: rest -> st.lines <- (l @ [ (p, style) ]) :: rest
         | [] -> st.lines <- [ [ (p, style) ] ]);
        st.col <- st.col + length p
      end else begin
        st.lines <- [ (p, style) ] :: st.lines;
        st.col <- length p
      end) pieces;
  (* a long story: the oldest lines go *)
  if List.length st.lines > 2000 then st.lines <- List.filteri (fun i _ -> i < 1500) st.lines

let collect st =
  let s = st.vm.Zvm.screen in
  if s.Zvm.cleared then begin st.lines <- [ [] ]; st.col <- 0; s.Zvm.cleared <- false end;
  List.iter (add_text st) (Zvm.take_lower s)

let rec advance st =
  st.wants <- Zvm.run st.vm;
  collect st;
  match st.wants with
  | Zvm.File_name _ ->
    add_text st ("File name [" ^ st.file_default ^ "]: ", Zvm.plain)
  | _ -> ()

and submit st =
  let line = st.input in
  st.input <- ""; st.scroll <- 0; st.recall <- -1;
  match st.wants with
  | Zvm.Line _ ->
    add_text st (line ^ "\n", { Zvm.plain with Zvm.bold = true });
    if line <> "" then st.history <- line :: st.history;
    Zvm.give_line st.vm line; advance st
  | Zvm.File_name _ ->
    add_text st (line ^ "\n", { Zvm.plain with Zvm.bold = true });
    let f = if line = "" then st.file_default else line in
    let msg = Zvm.give_file st.vm f in
    if msg <> "" then add_text st (msg ^ "\n", Zvm.plain);
    advance st
  | _ -> ()

let draw ui st =
  let g = ui.Gui.g in
  Gfx.fill g 0 0 width height background;
  let s = st.vm.Zvm.screen in
  let x0 = margin and y0 = margin in
  let text x y str style =
    let fg = if style.Zvm.bold then bright else foreground in
    if style.Zvm.reverse then begin
      Gfx.fill g x y (Gfx.char_w * length str) Gfx.char_h foreground;
      ignore (Gui.text ~bold:style.Zvm.bold ui x y str background)
    end else ignore (Gui.text ~bold:style.Zvm.bold ui x y str fg) in
  (* the top: version 3's status line, or the upper window *)
  let top_rows =
    match s.Zvm.status with
    | Some (place, right) when st.vm.Zvm.version <= 3 ->
      Gfx.fill g 0 0 width (Gfx.char_h + margin) status_bg;
      ignore (Gfx.text ~bold:true g x0 (margin / 2) place bright);
      ignore (Gfx.text g (width - margin - 12 - Gfx.char_w * length right) (margin / 2) right bright);
      1
    | _ ->
      Array.iteri (fun r row ->
          Array.iteri (fun c (ch, style) ->
              if ch <> " " || style.Zvm.reverse then
                text (x0 + c * Gfx.char_w) (y0 + r * Gfx.char_h) ch style) row) s.Zvm.upper;
      s.Zvm.upper_rows in
  (* the lower window: its last lines, the input on the last *)
  let avail = rows - top_rows in
  let cursor = match st.wants with Zvm.Line _ | Zvm.File_name _ -> true | _ -> false in
  let lines = match st.lines with
    | last :: rest when cursor -> (last @ [ (st.input, { Zvm.plain with Zvm.bold = true }) ]) :: rest
    | ls -> ls in
  let total = List.length lines in
  st.scroll <- max 0 (min st.scroll (total - avail));
  let shown = List.filteri (fun i _ -> i >= st.scroll && i < st.scroll + avail) lines in
  List.iteri (fun i line ->
      let y = y0 + (top_rows + avail - 1 - i) * Gfx.char_h in
      let x = ref x0 in
      List.iter (fun (str, style) -> text !x y str style; x := !x + Gfx.char_w * length str) line;
      if i = 0 && st.scroll = 0 && cursor then Gfx.fill g !x (y + Gfx.char_h - 3) Gfx.char_w 2 bright)
    shown;
  if st.scroll > 0 then begin
    let t = Printf.sprintf " %d lines more below " st.scroll in
    Gfx.fill g (width - 12 - Gfx.char_w * String.length t - margin) (height - Gfx.char_h - 2)
      (Gfx.char_w * String.length t) Gfx.char_h status_bg;
    ignore (Gfx.text g (width - 12 - Gfx.char_w * String.length t - margin) (height - Gfx.char_h - 2) t bright)
  end;
  (match st.wants with
   | Zvm.Quit when st.ready ->
     let t = " The story has ended: Escape closes the window " in
     Gfx.fill g x0 (height - Gfx.char_h - 2) (Gfx.char_w * String.length t) Gfx.char_h status_bg;
     ignore (Gfx.text g x0 (height - Gfx.char_h - 2) t bright)
   | _ -> ())

(* a key, as the Z-machine numbers them *)
let zkey = function
  | "\r" | "\n" -> Some 13 | "\127" | "\b" -> Some 8 | "\027" -> Some 27
  | "\027[A" -> Some 129 | "\027[B" -> Some 130 | "\027[D" -> Some 131 | "\027[C" -> Some 132
  | k when String.length k = 1 && k.[0] >= ' ' && k.[0] <= '~' -> Some (Char.code k.[0])
  | _ -> None

let stories n =
  List.exists (fun e -> Filename.check_suffix (String.lowercase_ascii n) e)
    [ ".z1"; ".z2"; ".z3"; ".z4"; ".z5"; ".z7"; ".z8"; ".dat" ]

let load path = Zvm.create ~cols ~rows ~name:(Filename.basename path)
    (In_channel.with_open_bin path In_channel.input_all)

(* [path]: the story, or "" to choose one first *)
let window path =
  let vm = if path = "" then Zvm.create ~name:"" (String.make 64 '\003') else load path in
  let st = { vm; path; lines = [ [] ]; col = 0; input = ""; wants = Zvm.Quit; history = [];
             recall = -1; scroll = 0; file_default = default_save path; ready = path <> "" } in
  if path = "" then begin
    add_text st ("Choose a story: a file .z3, .z5 or .z8 (the installed ones are in \
                  /disk/pkg, as zork1/zork1.z3).\n", Zvm.plain);
    Gui.open_file_picker ~title:"A story" ~dir:"/disk/pkg" ~filter:stories 1
  end else advance st;
  let title p = if p = "" then "Z-machine" else "Z-machine: " ^ Filename.basename p in
  Gui.run ~title:(title path) width height st (fun ui st ->
      List.iter (fun k ->
          match st.wants, k with
          | _, "\027" when not st.ready -> raise Gui.Quit
          | _ when not st.ready -> ()
          | Zvm.Quit, "\027" -> raise Gui.Quit
          | Zvm.Key, k ->
            (match zkey k with Some c -> Zvm.give_key st.vm c; advance st | None -> ())
          | _, ("\r" | "\n") -> submit st
          | _, ("\127" | "\b") ->
            let n = String.length st.input in
            if n > 0 then begin
              (* a whole UTF-8 character *)
              let i = ref (n - 1) in
              while !i > 0 && Char.code st.input.[!i] land 0xC0 = 0x80 do decr i done;
              st.input <- String.sub st.input 0 !i
            end
          | _, "\027[A" ->
            if st.recall + 1 < List.length st.history then begin
              st.recall <- st.recall + 1; st.input <- List.nth st.history st.recall end
          | _, "\027[B" ->
            if st.recall > 0 then begin st.recall <- st.recall - 1; st.input <- List.nth st.history st.recall end
            else begin st.recall <- -1; st.input <- "" end
          | _, "\027[5~" -> st.scroll <- st.scroll + (rows - 4)
          | _, "\027[6~" -> st.scroll <- max 0 (st.scroll - (rows - 4))
          | (Zvm.Line _ | Zvm.File_name _), k
            when String.length k >= 1 && k.[0] <> '\027' && Char.code k.[0] >= 32 ->
            if length st.input < cols - 10 then st.input <- st.input ^ k; st.scroll <- 0
          | _ -> ()) ui.Gui.keys;
      if ui.Gui.wheel <> 0 then st.scroll <- max 0 (st.scroll - 3 * ui.Gui.wheel);
      draw ui st;
      (match Gui.file_picker ui 1 with
       | Some (Gui.Picked p) ->
         (match load p with
          | vm ->
            st.vm <- vm; st.path <- p; st.file_default <- default_save p;
            st.lines <- [ [] ]; st.col <- 0; st.ready <- true;
            (try Display.set_title ui.Gui.window (title p) with _ -> ());
            advance st
          | exception (Zvm.Error m | Sys_error m) -> add_text st (m ^ "\n", Zvm.plain))
       | Some Gui.Cancelled -> if st.path = "" then raise Gui.Quit
       | None -> ());
      st)

(* is there a graphical session? A window asked, and closed at once *)
let session () =
  match Display.window ~title:"" 16 16 with
  | w -> Display.destroy w; true
  | exception _ -> false

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let term, args = match args with "-t" :: rest -> true, rest | a -> false, a in
  (* a story's command is a script, "#!/disk/bin/zmachine.byte STORY":
     its own path comes after the story, and is not needed *)
  match args with
  | [] when not term && session () -> window ""
  | arg :: _ ->
    (match story_path arg with
     | exception Failure m -> prerr_endline ("zmachine: " ^ m); exit 2
     | path ->
       match if term || not (session ()) then terminal path else window path with
       | () -> ()
       | exception Zvm.Error m -> prerr_endline ("zmachine: " ^ m); exit 1)
  | [] -> prerr_endline "usage: zmachine [-t] STORY (a .z3, .z5... file, or an installed story's package)"; exit 2
