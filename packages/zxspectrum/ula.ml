(* The ULA's picture (ula.mli). A frame is 312 lines of 224 T-states; the
   first of the 192 lines of the picture is line 64; the border shown is
   24 lines above it and 24 below (lines 40 to 279), 32 pixels each
   side. A line's border takes the colour it has when the line starts. *)

let width = 320 and height = 240
let first_line = 40                     (* the first line shown *)
let line_t = 224

let palette = [|
  0x000000; 0x0000D7; 0xD70000; 0xD700D7; 0x00D700; 0x00D7D7; 0xD7D700; 0xD7D7D7;
  0x000000; 0x0000FF; 0xFF0000; 0xFF00FF; 0x00FF00; 0x00FFFF; 0xFFFF00; 0xFFFFFF |]

type t = {
  pixels : int array;
  changed : bool array;
  mutable border : int;                 (* now *)
  mutable start_border : int;           (* at the frame's start *)
  mutable changes : (int * int) list;   (* (T-state, colour), latest first *)
}

let create () =
  { pixels = Array.make (width * height) 0; changed = Array.make height true;
    border = 7; start_border = 7; changes = [] }

let border t = t.border

let set_border t ~tstate c =
  let c = c land 7 in
  if c <> t.border then begin
    t.border <- c;
    t.changes <- (tstate, c) :: t.changes
  end

let pixels t = t.pixels
let changed t = t.changed

let row_border t y colour =
  let base = y * width in
  let before = ref false in
  let c = palette.(colour) in
  let fill a b = for i = base + a to base + b - 1 do
      if Array.unsafe_get t.pixels i <> c then begin Array.unsafe_set t.pixels i c; before := true end
    done in
  if y < 24 || y >= 216 then fill 0 width else begin fill 0 32; fill 288 width end;
  if !before then t.changed.(y) <- true

let render t mem ~flash =
  (* the border, line by line: the colour at each line's start *)
  let changes = List.rev t.changes in
  let rest = ref changes and colour = ref t.start_border in
  for y = 0 to height - 1 do
    let start = (first_line + y) * line_t in
    while (match !rest with (ts, _) :: _ -> ts <= start | [] -> false) do
      (match !rest with (_, c) :: r -> colour := c; rest := r | [] -> ())
    done;
    row_border t y !colour
  done;
  t.changes <- [];
  t.start_border <- t.border;
  (* the picture *)
  for y = 0 to 191 do
    let row = 0x4000 lor ((y land 0xC0) lsl 5) lor ((y land 7) lsl 8) lor ((y land 0x38) lsl 2) in
    let attrs = 0x5800 + (y lsr 3) * 32 in
    let base = (y + 24) * width + 32 in
    let any = ref false in
    for col = 0 to 31 do
      let bits = Char.code (Bytes.unsafe_get mem (row + col)) in
      let a = Char.code (Bytes.unsafe_get mem (attrs + col)) in
      let bright = (a lsr 3) land 8 in
      let ink = palette.(bright lor (a land 7)) and paper = palette.(bright lor ((a lsr 3) land 7)) in
      let ink, paper = if flash && a land 0x80 <> 0 then paper, ink else ink, paper in
      let p = base + col * 8 in
      for b = 0 to 7 do
        let c = if bits land (0x80 lsr b) <> 0 then ink else paper in
        if Array.unsafe_get t.pixels (p + b) <> c then begin
          Array.unsafe_set t.pixels (p + b) c; any := true
        end
      done
    done;
    if !any then t.changed.(y + 24) <- true
  done
