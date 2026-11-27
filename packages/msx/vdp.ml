(* The TMS9918A (vdp.mli).

   Registers: 0, bit 1 M3 (Graphics II); 1, bit 6 the screen on, bit 5
   the interrupt, bit 4 M1 (text), bit 3 M2 (multicolor), bit 1 sprites
   of 16, bit 0 sprites magnified; 2 the names' table (x 0x400); 3 the
   colours' (x 0x40); 4 the patterns' (x 0x800); 5 the sprites'
   attributes (x 0x80); 6 the sprites' patterns (x 0x800); 7 the text's
   colour (high nibble) and the backdrop (low).

   Graphics II splits the screen in three thirds of 256 characters each;
   registers 3 and 4 there give a base (bit 7 of 3, bit 2 of 4) and a
   mask of the address, as the chip combines them. *)

let width = 288
let height = 216
let left = 16 and top = 12

(* the TMS9918A's 15 colours (0 is transparent), as emulators commonly
   give them *)
let palette = [| 0x000000; 0x000000; 0x21C842; 0x5EDC78; 0x5455ED; 0x7D76FC; 0xD4524D; 0x42EBF5;
                 0xFC5554; 0xFF7978; 0xD4C154; 0xE6CE80; 0x21B03B; 0xC95BBA; 0xCCCCCC; 0xFFFFFF |]

type mode = Graphics1 | Graphics2 | Multicolor | Text

type t = {
  vram : Bytes.t;
  regs : int array;
  mutable status : int;
  mutable addr : int;
  mutable latch : bool;                 (* the first byte of two written to 0x99 *)
  mutable first : int;
  mutable buffer : int;                 (* the byte read ahead *)
  px : int array;
  changed : bool array;
  line : int array;                     (* a line's 256 colours *)
  occ : int array;                      (* a sprite's pixel there, on this pass's line *)
  drawn : int array;                    (* a sprite's coloured pixel there *)
  mutable stamp : int;
}

let create () =
  { vram = Bytes.make 0x4000 '\000'; regs = Array.make 8 0; status = 0; addr = 0;
    latch = false; first = 0; buffer = 0;
    px = Array.make (width * height) 0; changed = Array.make height true;
    line = Array.make 256 0; occ = Array.make 256 0; drawn = Array.make 256 0; stamp = 0 }

let reset t =
  Bytes.fill t.vram 0 0x4000 '\000';
  Array.fill t.regs 0 8 0;
  t.status <- 0; t.addr <- 0; t.latch <- false; t.first <- 0; t.buffer <- 0

let vram t = t.vram
let register t r = t.regs.(r land 7)
let vb t a = Char.code (Bytes.unsafe_get t.vram (a land 0x3FFF))

let write_data t v =
  Bytes.unsafe_set t.vram t.addr (Char.unsafe_chr (v land 0xFF));
  t.buffer <- v land 0xFF;
  t.addr <- (t.addr + 1) land 0x3FFF;
  t.latch <- false

let read_data t =
  let r = t.buffer in
  t.buffer <- vb t t.addr;
  t.addr <- (t.addr + 1) land 0x3FFF;
  t.latch <- false;
  r

let write_ctrl t v =
  let v = v land 0xFF in
  if not t.latch then begin t.first <- v; t.latch <- true end
  else begin
    t.latch <- false;
    if v land 0x80 <> 0 then t.regs.(v land 7) <- t.first
    else begin
      t.addr <- t.first lor ((v land 0x3F) lsl 8);
      if v land 0x40 = 0 then begin
        t.buffer <- vb t t.addr;
        t.addr <- (t.addr + 1) land 0x3FFF
      end
    end
  end

let read_status t =
  let s = t.status in
  t.status <- s land 0x1F;
  t.latch <- false;
  s

let irq t = t.status land 0x80 <> 0 && t.regs.(1) land 0x20 <> 0

let mode t =
  if t.regs.(1) land 0x10 <> 0 then Text
  else if t.regs.(1) land 0x08 <> 0 then Multicolor
  else if t.regs.(0) land 0x02 <> 0 then Graphics2
  else Graphics1

let name_table t = (t.regs.(2) land 0x0F) lsl 10
let blank t = t.regs.(1) land 0x40 = 0

(* ---- sprites ---- *)

(* the sprites on line y (0-191): their status (the fifth, collisions)
   and, if [draw], their colours into [line]. The last sprite looked at,
   for the status's number when no fifth was found. *)
let sprites t y ~draw =
  let r1 = t.regs.(1) in
  let size = if r1 land 2 <> 0 then 16 else 8 in
  let mag = if r1 land 1 <> 0 then 2 else 1 in
  let span = size * mag in
  let sat = (t.regs.(5) land 0x7F) lsl 7 and spg = (t.regs.(6) land 7) lsl 11 in
  t.stamp <- t.stamp + 1;
  let stamp = t.stamp in
  let shown = ref 0 and i = ref 0 and last = ref 31 and stop = ref false in
  while not !stop && !i < 32 do
    let a = sat + 4 * !i in
    let sy = vb t a in
    if sy = 208 then begin last := !i; stop := true end
    else begin
      let top = (if sy > 208 then sy - 256 else sy) + 1 in
      let dy = y - top in
      if dy >= 0 && dy < span then begin
        if !shown = 4 then begin
          if t.status land 0x40 = 0 && not draw then
            t.status <- (t.status land 0xA0) lor 0x40 lor !i;
          last := !i; stop := true
        end else begin
          incr shown;
          let c = vb t (a + 3) in
          let x0 = vb t (a + 1) - (if c land 0x80 <> 0 then 32 else 0) in
          let colour = c land 15 in
          let name = if size = 16 then vb t (a + 2) land 0xFC else vb t (a + 2) in
          let row = dy / mag in
          let base = spg + name * 8 + row in
          for p = 0 to span - 1 do
            let sx = x0 + p in
            if sx >= 0 && sx < 256 then begin
              let col = p / mag in
              let byte = if col < 8 then vb t base else vb t (base + 16) in
              if (byte lsr (7 - (col land 7))) land 1 <> 0 then begin
                if Array.unsafe_get t.occ sx = stamp then begin
                  if not draw then t.status <- t.status lor 0x20
                end else Array.unsafe_set t.occ sx stamp;
                if draw && colour <> 0 && Array.unsafe_get t.drawn sx <> stamp then begin
                  Array.unsafe_set t.drawn sx stamp;
                  Array.unsafe_set t.line sx colour
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

let frame_end t =
  if not (blank t) && mode t <> Text then begin
    let last = ref 31 in
    for y = 0 to 191 do last := sprites t y ~draw:false done;
    if t.status land 0x40 = 0 then t.status <- (t.status land 0xE0) lor !last
  end;
  t.status <- t.status lor 0x80

(* ---- the picture ---- *)

let background t y =
  let r = t.regs and line = t.line in
  let nt = name_table t in
  match mode t with
  | Text ->
    let pg = (r.(4) land 7) lsl 11 in
    let fg = r.(7) lsr 4 and bg = r.(7) land 15 in
    Array.fill line 0 256 0;
    let row = y lsr 3 in
    for col = 0 to 39 do
      let c = vb t (nt + row * 40 + col) in
      let p = vb t (pg + c * 8 + (y land 7)) in
      for k = 0 to 5 do
        line.(8 + col * 6 + k) <- (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done
  | Graphics1 ->
    let pg = (r.(4) land 7) lsl 11 and ct = r.(3) lsl 6 in
    let row = y lsr 3 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let p = vb t (pg + c * 8 + (y land 7)) in
      let colours = vb t (ct + (c lsr 3)) in
      let fg = colours lsr 4 and bg = colours land 15 in
      for k = 0 to 7 do
        Array.unsafe_set line (col * 8 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done
  | Graphics2 ->
    let pbase = (r.(4) land 4) lsl 11 and pmask = ((r.(4) land 3) lsl 11) lor 0x7FF in
    let cbase = (r.(3) land 0x80) lsl 6 and cmask = ((r.(3) land 0x7F) lsl 6) lor 0x3F in
    let row = y lsr 3 and third = y lsr 6 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let off = ((third lsl 8) + c) * 8 + (y land 7) in
      let p = vb t (pbase lor (off land pmask)) in
      let colours = vb t (cbase lor (off land cmask)) in
      let fg = colours lsr 4 and bg = colours land 15 in
      for k = 0 to 7 do
        Array.unsafe_set line (col * 8 + k) (if (p lsr (7 - k)) land 1 <> 0 then fg else bg)
      done
    done
  | Multicolor ->
    let pg = (r.(4) land 7) lsl 11 in
    let row = y lsr 3 in
    for col = 0 to 31 do
      let c = vb t (nt + row * 32 + col) in
      let b = vb t (pg + c * 8 + (row land 3) * 2 + ((y land 7) lsr 2)) in
      for k = 0 to 3 do
        line.(col * 8 + k) <- b lsr 4;
        line.(col * 8 + 4 + k) <- b land 15
      done
    done

let put t y x rgb =
  let i = y * width + x in
  if Array.unsafe_get t.px i <> rgb then begin
    Array.unsafe_set t.px i rgb;
    t.changed.(y) <- true
  end

let pixels t =
  let backdrop = palette.(t.regs.(7) land 15) in
  for y = 0 to height - 1 do
    let sy = y - top in
    if sy < 0 || sy >= 192 || blank t then
      for x = 0 to width - 1 do put t y x backdrop done
    else begin
      background t sy;
      if mode t <> Text then ignore (sprites t sy ~draw:true);
      for x = 0 to left - 1 do put t y x backdrop; put t y (width - 1 - x) backdrop done;
      for x = 0 to 255 do
        let c = Array.unsafe_get t.line x in
        put t y (left + x) (if c = 0 then backdrop else Array.unsafe_get palette c)
      done
    end
  done;
  t.px

let changed t = t.changed

(* ---- saved state: the registers, the status, the address and its
   latch, the read-ahead, then the VRAM ---- *)

let state_size = 8 + 6 + 0x4000

let save t =
  let b = Buffer.create state_size in
  Array.iter (fun v -> Buffer.add_char b (Char.chr v)) t.regs;
  Buffer.add_char b (Char.chr t.status);
  Buffer.add_char b (Char.chr (t.addr land 0xFF));
  Buffer.add_char b (Char.chr (t.addr lsr 8));
  Buffer.add_char b (if t.latch then '\001' else '\000');
  Buffer.add_char b (Char.chr t.first);
  Buffer.add_char b (Char.chr t.buffer);
  Buffer.add_bytes b t.vram;
  Buffer.contents b

let restore t s =
  if String.length s <> state_size then failwith "vdp: a state of another size";
  for i = 0 to 7 do t.regs.(i) <- Char.code s.[i] done;
  t.status <- Char.code s.[8];
  t.addr <- Char.code s.[9] lor (Char.code s.[10] lsl 8);
  t.latch <- s.[11] <> '\000';
  t.first <- Char.code s.[12];
  t.buffer <- Char.code s.[13];
  Bytes.blit_string s 14 t.vram 0 0x4000;
  Array.fill t.changed 0 height true
