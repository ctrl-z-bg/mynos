(* The TMS9918A and the V9938 (vdp.mli).

   Registers (both): 0, bit 1 M3 (V9938: bit 2 M4, bit 3 M5, bit 4 IE1
   the line interrupt); 1, bit 6 the screen on, bit 5 the frame's
   interrupt, bit 4 M1 (text), bit 3 M2 (multicolor), bit 1 sprites of
   16, bit 0 sprites magnified; 2 the names' table; 3 the colours'; 4 the
   patterns'; 5 the sprites' attributes; 6 the sprites' patterns; 7 the
   text's colour (high nibble) and the backdrop (low). The V9938's
   others: 8 (bit 5 TP: colour 0 is palette 0, not the backdrop; bit 1
   SPD: no sprites), 9 (bit 7 LN: 212 lines), 10 and 11 the colours' and
   the sprites' tables' high bits, 12 and 13 text 2's blinking, 14 the
   VRAM address's high bits, 15 the status register read, 16 the
   palette's entry, 17 the register port 0x9B writes, 19 the line
   interrupt's line, 23 the vertical scroll, 32-46 the command engine
   (vdp_cmd.ml). Not modelled: 18 (the display's adjustment), 9's
   interlace and PAL, 8's mouse and light pen.

   The modes (M1-M5): text 1 and 2 (40 and 80 columns), multicolor,
   Graphics 1 to 7 (SCREEN 1 to 8; 4 to 7 the V9938's bitmaps). The
   tables' bases are 17 bits; Graphics 2 and 3 split the screen in three
   thirds of 256 characters, registers 3 and 4 giving a base and a mask
   of the address, as the chip combines them.

   The VRAM is kept in the order the CPU sees it: Graphics 6 and 7's
   interleaving of its two banks is not modelled (a picture written in
   one mode and shown in the other would differ on the chip).

   Lines are drawn only while someone looks ([set_draw]): else each line
   only finds its sprites' status, and [pixels] draws the whole picture
   from the VRAM of now when asked. *)

(* the TMS9918A's 15 colours (0 is transparent), as emulators commonly
   give them *)
let tms_palette = [| 0x000000; 0x000000; 0x21C842; 0x5EDC78; 0x5455ED; 0x7D76FC; 0xD4524D; 0x42EBF5;
                     0xFC5554; 0xFF7978; 0xD4C154; 0xE6CE80; 0x21B03B; 0xC95BBA; 0xCCCCCC; 0xFFFFFF |]

(* the MSX2's palette at power on (R, G, B from 0 to 7) *)
let msx2_palette = [| 0,0,0; 0,0,0; 1,6,1; 3,7,3; 1,1,7; 2,3,7; 5,1,1; 2,6,7;
                      7,1,1; 7,3,3; 6,6,1; 6,6,4; 1,4,1; 6,2,5; 5,5,5; 7,7,7 |]

let level3 v = v * 255 / 7
let rgb333 r g b = (level3 r lsl 16) lor (level3 g lsl 8) lor level3 b

(* Graphics 7's colours, GGGRRRBB; its sprites' 16 (G, R, B) *)
let g7_colour = Array.init 256 (fun c ->
    let g = (c lsr 5) land 7 and r = (c lsr 2) land 7 and b = c land 3 in
    (level3 r lsl 16) lor (level3 g lsl 8) lor (b * 255 / 3))
let g7_sprite = Array.map (fun (g, r, b) -> rgb333 r g b)
    [| 0,0,0; 0,0,2; 0,3,0; 0,3,2; 3,0,0; 3,0,2; 3,3,0; 3,3,2;
       7,4,2; 0,0,7; 0,7,0; 0,7,7; 7,0,0; 7,0,7; 7,7,0; 7,7,7 |]

type mode = Graphics1 | Graphics2 | Multicolor | Text | Graphics3 | Graphics4 | Graphics5
          | Graphics6 | Graphics7 | Text2

type t = {
  v9938 : bool;
  vram : Bytes.t;
  vmask : int;
  regs : int array;                     (* 64 *)
  st : int array;                       (* the status registers, S0-S9 *)
  palraw : int array;                   (* 16: R << 8 | G << 4 | B, 0-7 each *)
  pal : int array;                      (* the same as 0xRRGGBB *)
  mutable pal_first : int;              (* a palette write's first byte; -1 none *)
  mutable addr : int;
  mutable latch : bool;                 (* the first byte of two written to 0x99 *)
  mutable first : int;
  mutable buffer : int;                 (* the byte read ahead *)
  width : int;
  height : int;
  left : int;                           (* the border's width, in the picture's pixels *)
  px : int array;
  changed : bool array;
  lb : int array;                       (* a line's colours (0xRRGGBB), 512 *)
  occ : int array;                      (* a sprite's pixel there, on this line (a stamp) *)
  drawn : int array;                    (* a sprite's colour there (a stamp) *)
  sidx : int array;                     (* that colour's index *)
  grp : int array;                      (* the sprite (CC = 0) that put it there *)
  mutable stamp : int;
  mutable cur : int;                    (* the frame's line now *)
  mutable clock : unit -> int;          (* T-states into the line now *)
  mutable draw : bool;
  mutable blink_on : bool;              (* text 2's blinking's phase *)
  mutable blink_count : int;
  cmd : Vdp_cmd.t;
}

let create ?(v9938 = false) () =
  let width = if v9938 then 576 else 288 and height = if v9938 then 228 else 216 in
  let vsize = if v9938 then 0x20000 else 0x4000 in
  let vram = Bytes.make vsize '\000' in
  { v9938; vram; vmask = vsize - 1; regs = Array.make 64 0; st = Array.make 10 0;
    palraw = Array.map (fun (r, g, b) -> (r lsl 8) lor (g lsl 4) lor b) msx2_palette;
    pal = (if v9938 then Array.map (fun (r, g, b) -> rgb333 r g b) msx2_palette
           else Array.copy tms_palette);
    pal_first = -1; addr = 0; latch = false; first = 0; buffer = 0;
    width; height; left = (if v9938 then 32 else 16);
    px = Array.make (width * height) 0; changed = Array.make height true;
    lb = Array.make 512 0; occ = Array.make 256 0; drawn = Array.make 256 0;
    sidx = Array.make 256 0; grp = Array.make 256 0; stamp = 0; cur = 0;
    clock = (fun () -> 0); draw = true; blink_on = false; blink_count = 0;
    cmd = Vdp_cmd.create vram }

let width t = t.width
let height t = t.height
let is_v9938 t = t.v9938
let set_clock t f = t.clock <- f
let set_draw t b = t.draw <- b

let set_pal t i raw =
  t.palraw.(i) <- raw;
  t.pal.(i) <- rgb333 ((raw lsr 8) land 7) ((raw lsr 4) land 7) (raw land 7)

let reset t =
  Bytes.fill t.vram 0 (Bytes.length t.vram) '\000';
  Array.fill t.regs 0 64 0;
  Array.fill t.st 0 10 0;
  t.addr <- 0; t.latch <- false; t.first <- 0; t.buffer <- 0; t.pal_first <- -1;
  if t.v9938 then
    Array.iteri (fun i (r, g, b) -> set_pal t i ((r lsl 8) lor (g lsl 4) lor b)) msx2_palette;
  Vdp_cmd.reset t.cmd

let vram t = t.vram
let register t r = t.regs.(r land 63)
let vb t a = Char.code (Bytes.unsafe_get t.vram (a land t.vmask))

let mode t =
  let r0 = t.regs.(0) and r1 = t.regs.(1) in
  let m345 = if t.v9938 then (r0 lsr 1) land 7 else (r0 lsr 1) land 1 in
  if r1 land 0x10 <> 0 then (if t.v9938 && m345 land 1 <> 0 then Text2 else Text)
  else if r1 land 0x08 <> 0 then Multicolor
  else match m345 with
    | 0 -> Graphics1 | 1 -> Graphics2 | 2 -> Graphics3 | 3 -> Graphics4
    | 4 -> Graphics5 | 5 -> Graphics6 | 7 -> Graphics7 | _ -> Graphics1

(* the command engine's view of the mode: the bitmaps' number, the
   others as Graphics 7 *)
let cmd_mode t = match mode t with Graphics4 -> 4 | Graphics5 -> 5 | Graphics6 -> 6 | _ -> 7

(* the VRAM address goes on: on the V9938, into register 14 but in the
   TMS9918A's modes (there the low 14 bits wrap) *)
let advance t =
  if not t.v9938 then t.addr <- (t.addr + 1) land 0x3FFF
  else match mode t with
    | Text | Graphics1 | Graphics2 | Multicolor ->
      t.addr <- (t.addr land 0x1C000) lor ((t.addr + 1) land 0x3FFF)
    | _ ->
      t.addr <- (t.addr + 1) land 0x1FFFF;
      t.regs.(14) <- (t.addr lsr 14) land 7

let write_data t v =
  Bytes.unsafe_set t.vram t.addr (Char.unsafe_chr (v land 0xFF));
  t.buffer <- v land 0xFF;
  advance t;
  t.latch <- false

let read_data t =
  let r = t.buffer in
  t.buffer <- vb t t.addr;
  advance t;
  t.latch <- false;
  r

let set_reg t r v =
  if not t.v9938 then t.regs.(r land 7) <- v
  else if r < 47 then begin
    t.regs.(r) <- v;
    match r with
    | 14 -> t.addr <- (t.addr land 0x3FFF) lor ((v land 7) lsl 14)
    | 16 -> t.pal_first <- -1
    | 44 -> Vdp_cmd.colour_written t.cmd t.regs v t.st (cmd_mode t)
    | 46 -> Vdp_cmd.start t.cmd t.regs t.st (cmd_mode t)
    | _ -> ()
  end

let write_ctrl t v =
  let v = v land 0xFF in
  if not t.latch then begin t.first <- v; t.latch <- true end
  else begin
    t.latch <- false;
    if v land 0x80 <> 0 then set_reg t (if t.v9938 then v land 0x3F else v land 7) t.first
    else begin
      let hi = if t.v9938 then (t.regs.(14) land 7) lsl 14 else 0 in
      t.addr <- hi lor t.first lor ((v land 0x3F) lsl 8);
      if v land 0x40 = 0 then begin
        t.buffer <- vb t t.addr;
        advance t
      end
    end
  end

(* port 0x9A: a palette entry, two bytes (0RRR0BBB, 00000GGG) *)
let write_palette t v =
  if t.v9938 then begin
    let v = v land 0xFF in
    if t.pal_first < 0 then t.pal_first <- v
    else begin
      let i = t.regs.(16) land 15 in
      set_pal t i ((((t.pal_first lsr 4) land 7) lsl 8) lor ((v land 7) lsl 4) lor (t.pal_first land 7));
      t.pal_first <- -1;
      t.regs.(16) <- (i + 1) land 15
    end
  end

(* port 0x9B: the register register 17 points at; 17 goes on unless its
   bit 7 *)
let write_indirect t v =
  if t.v9938 then begin
    let r17 = t.regs.(17) in
    let r = r17 land 0x3F in
    if r <> 17 then set_reg t r (v land 0xFF);
    if r17 land 0x80 = 0 then t.regs.(17) <- (r17 land 0xC0) lor ((r + 1) land 0x3F)
  end

let lines_shown t = if t.v9938 && t.regs.(9) land 0x80 <> 0 then 212 else 192

let read_status t =
  t.latch <- false;
  if not t.v9938 then begin
    let s = t.st.(0) in
    t.st.(0) <- s land 0x1F;
    s
  end else
    match t.regs.(15) land 15 with
    | 0 -> let s = t.st.(0) in t.st.(0) <- s land 0x1F; s
    | 1 -> let s = t.st.(1) in t.st.(1) <- s land 0xFE; s      (* FH cleared; the ID: 0, a V9938 *)
    | 2 ->
      let hr = t.clock () >= 171 and vr = t.cur >= lines_shown t in
      Vdp_cmd.status2 t.cmd lor (if hr then 0x20 else 0) lor (if vr then 0x40 else 0) lor 0x0C
    | 7 -> Vdp_cmd.read_colour t.cmd t.regs t.st (cmd_mode t)
    | 9 -> t.st.(9) lor 0xFE
    | n when n < 10 -> t.st.(n)
    | _ -> 0xFF

let irq t =
  (t.st.(0) land 0x80 <> 0 && t.regs.(1) land 0x20 <> 0)
  || (t.v9938 && t.st.(1) land 1 <> 0 && t.regs.(0) land 0x10 <> 0)

let name_table t = (if t.v9938 then t.regs.(2) land 0x7F else t.regs.(2) land 0x0F) lsl 10
let blank t = t.regs.(1) land 0x40 = 0

(* ---- colours ---- *)

(* a palette index's colour; 0 the backdrop's, unless TP *)
let colour t c =
  if c = 0 && not (t.v9938 && t.regs.(8) land 0x20 <> 0) then
    Array.unsafe_get t.pal (t.regs.(7) land 15)
  else Array.unsafe_get t.pal c

let backdrop t =
  if t.v9938 && mode t = Graphics7 then g7_colour.(t.regs.(7)) else t.pal.(t.regs.(7) land 15)

(* ---- sprites, on a line (0-255, scrolled), in the 256 columns: their
   status, and with [draw] their colours (sidx, at the line's stamp).
   The last sprite looked at, for the status's number when there was no
   fifth (ninth) ---- *)

(* mode 1 (Graphics 1, 2, multicolor): 4 on a line, 208 ends the list *)
let sprites1 t y ~draw =
  let r1 = t.regs.(1) in
  let size = if r1 land 2 <> 0 then 16 else 8 in
  let mag = if r1 land 1 <> 0 then 2 else 1 in
  let span = size * mag in
  let sat = if t.v9938 then ((t.regs.(11) land 3) lsl 15) lor (t.regs.(5) lsl 7)
    else (t.regs.(5) land 0x7F) lsl 7
  and spg = (t.regs.(6) land (if t.v9938 then 0x3F else 7)) lsl 11 in
  t.stamp <- t.stamp + 1;
  let stamp = t.stamp in
  let shown = ref 0 and i = ref 0 and last = ref 31 and stop = ref false in
  while not !stop && !i < 32 do
    let a = sat + 4 * !i in
    let sy = vb t a in
    if sy = 208 then begin last := !i; stop := true end
    else begin
      let dy = (y - sy - 1) land 255 in
      if dy < span then begin
        if !shown = 4 then begin
          if t.st.(0) land 0x40 = 0 then t.st.(0) <- (t.st.(0) land 0xA0) lor 0x40 lor !i;
          last := !i; stop := true
        end else begin
          incr shown;
          let c = vb t (a + 3) in
          let x0 = vb t (a + 1) - (if c land 0x80 <> 0 then 32 else 0) in
          let col = c land 15 in
          let name = if size = 16 then vb t (a + 2) land 0xFC else vb t (a + 2) in
          let base = spg + name * 8 + dy / mag in
          for p = 0 to span - 1 do
            let sx = x0 + p in
            if sx >= 0 && sx < 256 then begin
              let k = p / mag in
              let byte = if k < 8 then vb t base else vb t (base + 16) in
              if (byte lsr (7 - (k land 7))) land 1 <> 0 then begin
                if Array.unsafe_get t.occ sx = stamp then t.st.(0) <- t.st.(0) lor 0x20
                else Array.unsafe_set t.occ sx stamp;
                if draw && col <> 0 && Array.unsafe_get t.drawn sx <> stamp then begin
                  Array.unsafe_set t.drawn sx stamp;
                  Array.unsafe_set t.sidx sx col
                end
              end
            end
          done
        end
      end
    end;
    incr i
  done;
  if not !stop then last := 31;
  !last

(* mode 2 (Graphics 3 to 7): 8 on a line, 216 ends the list, a colour a
   line (16 bytes a sprite, 512 before the attributes): bits 0-3 the
   colour, 5 IC (no collision), 6 CC (or'ed with the sprites before it
   since the last without CC, whose priority it shares), 7 EC (32 to the
   left) *)
let sprites2 t y ~draw =
  let r1 = t.regs.(1) in
  let size = if r1 land 2 <> 0 then 16 else 8 in
  let mag = if r1 land 1 <> 0 then 2 else 1 in
  let span = size * mag in
  let sat = ((t.regs.(11) land 3) lsl 15) lor ((t.regs.(5) land 0xFC) lsl 7) in
  let sct = sat land lnot 0x200 in
  let spg = (t.regs.(6) land 0x3F) lsl 11 in
  let tp = t.regs.(8) land 0x20 <> 0 in
  t.stamp <- t.stamp + 1;
  let stamp = t.stamp in
  let shown = ref 0 and i = ref 0 and last = ref 31 and stop = ref false in
  let group = ref (-1) in
  while not !stop && !i < 32 do
    let a = sat + 4 * !i in
    let sy = vb t a in
    if sy = 216 then begin last := !i; stop := true end
    else begin
      let dy = (y - sy - 1) land 255 in
      if dy < span then begin
        if !shown = 8 then begin
          if t.st.(0) land 0x40 = 0 then t.st.(0) <- (t.st.(0) land 0xA0) lor 0x40 lor !i;
          last := !i; stop := true
        end else begin
          incr shown;
          let row = dy / mag in
          let c = vb t (sct + 16 * !i + row) in
          let cc = c land 0x40 <> 0 and ic = c land 0x20 <> 0 in
          if not cc then group := !i;
          let x0 = vb t (a + 1) - (if c land 0x80 <> 0 then 32 else 0) in
          let col = c land 15 in
          let name = if size = 16 then vb t (a + 2) land 0xFC else vb t (a + 2) in
          let base = spg + name * 8 + row in
          (* a CC sprite with no sprite before it on the line: not shown *)
          if not cc || !group >= 0 then
            for p = 0 to span - 1 do
              let sx = x0 + p in
              if sx >= 0 && sx < 256 then begin
                let k = p / mag in
                let byte = if k < 8 then vb t base else vb t (base + 16) in
                if (byte lsr (7 - (k land 7))) land 1 <> 0 then begin
                  if not cc && not ic then begin
                    if Array.unsafe_get t.occ sx = stamp then t.st.(0) <- t.st.(0) lor 0x20
                    else Array.unsafe_set t.occ sx stamp
                  end;
                  if draw then begin
                    if Array.unsafe_get t.drawn sx = stamp then begin
                      if cc && Array.unsafe_get t.grp sx = !group then
                        Array.unsafe_set t.sidx sx (Array.unsafe_get t.sidx sx lor col)
                    end else if col <> 0 || tp || cc then begin
                      Array.unsafe_set t.drawn sx stamp;
                      Array.unsafe_set t.sidx sx col;
                      Array.unsafe_set t.grp sx !group
                    end
                  end
                end
              end
            done
        end
      end
    end;
    incr i
  done;
  if not !stop then last := 31;
  !last

(* ---- the background, a line: lb's colours (0xRRGGBB), 256 or 512 of
   them; the line's width returned ---- *)

let background t y =
  let r = t.regs and lb = t.lb in
  let nt = name_table t in
  match mode t with
  | Text ->
    let pg = (r.(4) land (if t.v9938 then 0x3F else 7)) lsl 11 in
    let fg = colour t (r.(7) lsr 4) and bg = colour t (r.(7) land 15) in
    Array.fill lb 0 256 (backdrop t);
    let row = y lsr 3 in
    for col = 0 to 39 do
      let c = vb t (nt + row * 40 + col) in
      let p = vb t (pg + c * 8 + (y land 7)) in
      for k = 0 to 5 do
        Array.unsafe_set lb (8 + col * 6 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done;
    256
  | Text2 ->
    let pg = (r.(4) land 0x3F) lsl 11 in
    let nt2 = (r.(2) land 0x7C) lsl 10 in
    let ct = ((r.(10) land 7) lsl 14) lor ((r.(3) land 0xF8) lsl 6) in
    let fg = colour t (r.(7) lsr 4) and bg = colour t (r.(7) land 15) in
    let bfg = colour t (r.(12) lsr 4) and bbg = colour t (r.(12) land 15) in
    Array.fill lb 0 512 (backdrop t);
    let row = y lsr 3 in
    for col = 0 to 79 do
      let n = row * 80 + col in
      let c = vb t (nt2 + n) in
      let p = vb t (pg + c * 8 + (y land 7)) in
      let blink = t.blink_on && (vb t (ct + n / 8) lsr (7 - n land 7)) land 1 <> 0 in
      let fg, bg = if blink then bfg, bbg else fg, bg in
      for k = 0 to 5 do
        Array.unsafe_set lb (16 + col * 6 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done;
    512
  | Graphics1 ->
    let pg = (r.(4) land 0x3F) lsl 11 and ct = (((r.(10) land 7) lsl 8) lor r.(3)) lsl 6 in
    let row = y lsr 3 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let p = vb t (pg + c * 8 + (y land 7)) in
      let colours = vb t (ct + (c lsr 3)) in
      let fg = colour t (colours lsr 4) and bg = colour t (colours land 15) in
      for k = 0 to 7 do
        Array.unsafe_set lb (col * 8 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done;
    256
  | Graphics2 | Graphics3 ->
    let pbase = (r.(4) land 0x3C) lsl 11 and pmask = ((r.(4) land 3) lsl 11) lor 0x7FF in
    let cbase = ((r.(10) land 7) lsl 14) lor ((r.(3) land 0x80) lsl 6)
    and cmask = ((r.(3) land 0x7F) lsl 6) lor 0x3F in
    let row = y lsr 3 and third = (y lsr 6) land 3 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let off = ((third lsl 8) + c) * 8 + (y land 7) in
      let p = vb t (pbase lor (off land pmask)) in
      let colours = vb t (cbase lor (off land cmask)) in
      let fg = colour t (colours lsr 4) and bg = colour t (colours land 15) in
      for k = 0 to 7 do
        Array.unsafe_set lb (col * 8 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done;
    256
  | Multicolor ->
    let pg = (r.(4) land 0x3F) lsl 11 in
    let row = y lsr 3 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let b = vb t (pg + c * 8 + (row land 3) * 2 + ((y land 7) lsr 2)) in
      let a = colour t (b lsr 4) and z = colour t (b land 15) in
      for k = 0 to 3 do
        Array.unsafe_set lb (col * 8 + k) a;
        Array.unsafe_set lb (col * 8 + 4 + k) z
      done
    done;
    256
  | Graphics4 ->
    (* SCREEN 5: 256 x 4 bits, 128 bytes a line, a page of 32 KB *)
    let base = ((r.(2) land 0x60) lsl 10) lor (y lsl 7) in
    for x = 0 to 127 do
      let b = vb t (base + x) in
      Array.unsafe_set lb (2 * x) (colour t (b lsr 4));
      Array.unsafe_set lb (2 * x + 1) (colour t (b land 15))
    done;
    256
  | Graphics5 ->
    (* SCREEN 6: 512 x 2 bits *)
    let base = ((r.(2) land 0x60) lsl 10) lor (y lsl 7) in
    for x = 0 to 127 do
      let b = vb t (base + x) in
      for k = 0 to 3 do
        Array.unsafe_set lb (4 * x + k) (colour t ((b lsr (6 - 2 * k)) land 3))
      done
    done;
    512
  | Graphics6 ->
    (* SCREEN 7: 512 x 4 bits, 256 bytes a line, a page of 64 KB *)
    let base = ((r.(2) land 0x20) lsl 11) lor (y lsl 8) in
    for x = 0 to 255 do
      let b = vb t (base + x) in
      Array.unsafe_set lb (2 * x) (colour t (b lsr 4));
      Array.unsafe_set lb (2 * x + 1) (colour t (b land 15))
    done;
    512
  | Graphics7 ->
    (* SCREEN 8: 256 x 8 bits *)
    let base = ((r.(2) land 0x20) lsl 11) lor (y lsl 8) in
    for x = 0 to 255 do
      Array.unsafe_set lb x (Array.unsafe_get g7_colour (vb t (base + x)))
    done;
    256

(* ---- the picture ---- *)

let put t y x rgb =
  let i = y * t.width + x in
  if Array.unsafe_get t.px i <> rgb then begin
    Array.unsafe_set t.px i rgb;
    t.changed.(y) <- true
  end

let border_row t y =
  let bd = backdrop t in
  for x = 0 to t.width - 1 do put t y x bd done

let top t = (t.height - lines_shown t) / 2

let sprites_on t =
  match mode t with
  | Text | Text2 -> false
  | _ -> not (t.v9938 && t.regs.(8) land 2 <> 0)

let sprites t y ~draw =
  let last = (match mode t with
      | Graphics1 | Graphics2 | Multicolor -> sprites1 | _ -> sprites2) t y ~draw in
  if t.st.(0) land 0x40 = 0 then t.st.(0) <- (t.st.(0) land 0xE0) lor last

(* an active line drawn; with [status], its sprites' status found too *)
let draw_line t y ~status =
  let py = top t + y in
  if blank t then border_row t py
  else begin
    let scroll = if t.v9938 then t.regs.(23) else 0 in
    let vy = (y + scroll) land 255 in
    let w = background t vy in
    let on = sprites_on t in
    if on then begin
      if status then sprites t vy ~draw:true
      else begin
        (* the status kept as it is *)
        let s0 = t.st.(0) in
        sprites t vy ~draw:true;
        t.st.(0) <- s0
      end
    end;
    let stamp = t.stamp in
    let g7 = t.v9938 && mode t = Graphics7 in
    let spr x =
      let i = Array.unsafe_get t.sidx x in
      if g7 then Array.unsafe_get g7_sprite i else colour t i in
    let bd = backdrop t in
    for x = 0 to t.left - 1 do put t py x bd; put t py (t.width - 1 - x) bd done;
    let l = t.left in
    if not t.v9938 then
      for x = 0 to 255 do
        put t py (l + x) (if on && Array.unsafe_get t.drawn x = stamp then spr x else Array.unsafe_get t.lb x)
      done
    else if w = 512 then
      for x = 0 to 511 do
        let s = x lsr 1 in
        put t py (l + x) (if on && Array.unsafe_get t.drawn s = stamp then spr s else Array.unsafe_get t.lb x)
      done
    else
      for x = 0 to 255 do
        let c = if on && Array.unsafe_get t.drawn x = stamp then spr x else Array.unsafe_get t.lb x in
        put t py (l + 2 * x) c; put t py (l + 2 * x + 1) c
      done
  end

(* line [y] of the frame, as the beam reaches it (0 to 261): an active
   line drawn (or only its sprites' status found) with the VRAM and the
   registers of now; after the last, the bottom border and the frame's
   end (F, the interrupt) *)
let line t y =
  t.cur <- y;
  let shown = lines_shown t in
  if y = 0 then begin
    if t.draw then for r = 0 to top t - 1 do border_row t r done;
    (* text 2's blinking: register 13's on and off times, in tenths of
       frames' sixes *)
    if t.v9938 && t.regs.(13) <> 0 then begin
      t.blink_count <- t.blink_count + 1;
      let on = (t.regs.(13) lsr 4) * 10 and off = (t.regs.(13) land 15) * 10 in
      if t.blink_count >= (if t.blink_on then on else off) then begin
        t.blink_on <- not t.blink_on; t.blink_count <- 0
      end
    end
  end;
  if y < shown then begin
    if t.draw then draw_line t y ~status:true
    else if not (blank t) && sprites_on t then
      sprites t ((y + (if t.v9938 then t.regs.(23) else 0)) land 255) ~draw:false;
    (* the line interrupt: after the line register 19 names *)
    if t.v9938 && y = (t.regs.(19) - t.regs.(23)) land 255 then t.st.(1) <- t.st.(1) lor 1
  end else if y = shown then begin
    if t.draw then for r = top t + shown to t.height - 1 do border_row t r done;
    t.st.(0) <- t.st.(0) lor 0x80
  end

(* the picture: as the lines drew it, or, if they were not drawn, the
   whole of it now *)
let pixels t =
  if not t.draw then begin
    let shown = lines_shown t in
    for r = 0 to top t - 1 do border_row t r done;
    for y = 0 to shown - 1 do draw_line t y ~status:false done;
    for r = top t + shown to t.height - 1 do border_row t r done
  end;
  t.px

let changed t = t.changed

(* ---- saved state: the registers, the status, the address and its
   latch, the read-ahead (the V9938's palette and command engine), then
   the VRAM ---- *)

let state_size t = if t.v9938 then 64 + 10 + 6 + 32 + Vdp_cmd.state_size + 0x20000 else 8 + 6 + 0x4000

let save t =
  let b = Buffer.create (state_size t) in
  let byte v = Buffer.add_char b (Char.chr (v land 0xFF)) in
  if t.v9938 then begin Array.iter byte t.regs; Array.iter byte t.st end
  else begin for i = 0 to 7 do byte t.regs.(i) done; byte t.st.(0) end;
  byte t.addr; byte (t.addr lsr 8);
  if t.v9938 then byte (t.addr lsr 16);
  byte (if t.latch then 1 else 0);
  byte t.first; byte t.buffer;
  if t.v9938 then begin
    Array.iter (fun v -> byte (v lsr 8); byte v) t.palraw;
    Buffer.add_string b (Vdp_cmd.save t.cmd)
  end;
  Buffer.add_bytes b t.vram;
  Buffer.contents b

let restore t s =
  if String.length s <> state_size t then failwith "vdp: a state of another size";
  let p = ref 0 in
  let byte () = let v = Char.code s.[!p] in incr p; v in
  if t.v9938 then begin
    for i = 0 to 63 do t.regs.(i) <- byte () done;
    for i = 0 to 9 do t.st.(i) <- byte () done
  end else begin
    for i = 0 to 7 do t.regs.(i) <- byte () done;
    t.st.(0) <- byte ()
  end;
  let lo = byte () in
  let mid = byte () in
  let hi = if t.v9938 then byte () else 0 in
  t.addr <- lo lor (mid lsl 8) lor (hi lsl 16);
  t.latch <- byte () <> 0;
  t.first <- byte ();
  t.buffer <- byte ();
  if t.v9938 then begin
    for i = 0 to 15 do
      let h = byte () in
      let l = byte () in
      set_pal t i ((h lsl 8) lor l)
    done;
    Vdp_cmd.restore t.cmd (String.sub s !p Vdp_cmd.state_size);
    p := !p + Vdp_cmd.state_size
  end;
  Bytes.blit_string s !p t.vram 0 (Bytes.length t.vram);
  Array.fill t.changed 0 t.height true
