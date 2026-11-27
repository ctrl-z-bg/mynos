(* The V9938's command engine (vdp_cmd.mli).

   Registers 32-46: SX (32, 33: 9 bits), SY (34, 35: 10), DX (36, 37),
   DY (38, 39), NX (40, 41), NY (42, 43), CLR (44), ARG (45: bit 0 MAJ,
   1 EQ, 2 DIX left, 3 DIY up), CMD (46: the command in the high nibble,
   the logical operation in the low). The commands work on the bitmap
   modes' pixels (Graphics 4 to 7; the others' VRAM as Graphics 7's).

   A command is done at once, as if the chip were infinitely fast;
   those that move bytes between the CPU and the VRAM (HMMC, LMMC, LMCM)
   go a byte or a pixel at a time, as the CPU writes register 44 or
   reads status register 7, TR saying when it may. *)

type kind = Idle | To_vram of bool | From_vram   (* bool: logical (pixels) *)

type t = {
  vram : Bytes.t;
  mutable kind : kind;
  (* a transfer's progress *)
  mutable x : int; mutable y : int; mutable left : int;   (* left in the row *)
  mutable rows : int;
  mutable x0 : int; mutable nx : int;
  mutable dix : int; mutable diy : int;
  mutable lop : int;
  mutable tr : bool;
  mutable bd : bool;
}

let create vram = { vram; kind = Idle; x = 0; y = 0; left = 0; rows = 0; x0 = 0; nx = 0;
                    dix = 1; diy = 1; lop = 0; tr = false; bd = false }

let reset t = t.kind <- Idle; t.tr <- false; t.bd <- false

let vmask t = Bytes.length t.vram - 1
let get t a = Char.code (Bytes.unsafe_get t.vram (a land vmask t))
let set t a v = Bytes.unsafe_set t.vram (a land vmask t) (Char.unsafe_chr (v land 0xFF))

type geometry = { width : int; bpp : int; line : int }   (* pixels, bits a pixel, bytes a line *)

let geometry (mode : int) =
  match mode with
  | 4 -> { width = 256; bpp = 4; line = 128 }
  | 5 -> { width = 512; bpp = 2; line = 128 }
  | 6 -> { width = 512; bpp = 4; line = 256 }
  | _ -> { width = 256; bpp = 8; line = 256 }

let pixel_addr g x y = y * g.line + x * g.bpp / 8

let point t g x y =
  let b = get t (pixel_addr g x y) in
  match g.bpp with
  | 4 -> if x land 1 = 0 then b lsr 4 else b land 15
  | 2 -> (b lsr (6 - 2 * (x land 3))) land 3
  | _ -> b

(* the logical operations: IMP AND OR EOR NOT, 8 and up the same with
   colour 0 leaving the pixel as it is (TIMP...) *)
let logic lop src dst =
  if lop land 8 <> 0 && src = 0 then dst
  else match lop land 7 with
    | 0 -> src
    | 1 -> src land dst
    | 2 -> src lor dst
    | 3 -> src lxor dst
    | 4 -> lnot src
    | _ -> dst

let pset t g lop x y c =
  let a = pixel_addr g x y in
  let b = get t a in
  match g.bpp with
  | 4 ->
    let sh = if x land 1 = 0 then 4 else 0 in
    let d = (b lsr sh) land 15 in
    let v = logic lop (c land 15) d land 15 in
    set t a ((b land lnot (15 lsl sh)) lor (v lsl sh))
  | 2 ->
    let sh = 6 - 2 * (x land 3) in
    let d = (b lsr sh) land 3 in
    let v = logic lop (c land 3) d land 3 in
    set t a ((b land lnot (3 lsl sh)) lor (v lsl sh))
  | _ -> set t a (logic lop c b)

let r16 regs lo mask = (regs.(lo) lor (regs.(lo + 1) lsl 8)) land mask

let mode_number = function
  | `G4 -> 4 | `G5 -> 5 | `G6 -> 6 | `G7 -> 7

(* the pixels a byte holds in this mode *)
let per_byte g = 8 / g.bpp

(* a rectangle's pixels, row by row: f x y for each, x clipped to the
   screen's width (a row stops at its edge) *)
let rect g ~x0 ~y0 ~nx ~ny ~dix ~diy f =
  for j = 0 to ny - 1 do
    let y = (y0 + j * diy) land 1023 in
    let i = ref 0 in
    let x = ref x0 in
    while !i < nx && !x >= 0 && !x < g.width do
      f !x y; x := !x + dix; incr i
    done
  done

(* the next unit of a transfer from the CPU (register 44 written) *)
let colour_written t regs v st (m : int) =
  ignore regs; ignore st;
  match t.kind with
  | To_vram logical ->
    let g = geometry m in
    let w = if logical then g.width else g.width / per_byte g in
    if t.x >= 0 && t.x < w then begin
      if logical then pset t g t.lop t.x (t.y land 1023) v
      else set t ((t.y land 1023) * g.line + t.x) v
    end;
    t.x <- t.x + t.dix; t.left <- t.left - 1;
    if t.left <= 0 then begin
      t.rows <- t.rows - 1; t.y <- t.y + t.diy; t.x <- t.x0; t.left <- t.nx;
      if t.rows <= 0 then begin t.kind <- Idle; t.tr <- false end
    end
  | _ -> ()

let start t regs st (m : int) =
  let g = geometry m in
  let cmd = regs.(46) lsr 4 and lop = regs.(46) land 15 in
  let arg = regs.(45) in
  let dix = if arg land 4 <> 0 then -1 else 1 and diy = if arg land 8 <> 0 then -1 else 1 in
  let sx = r16 regs 32 0x1FF and sy = r16 regs 34 0x3FF in
  let dx = r16 regs 36 0x1FF and dy = r16 regs 38 0x3FF in
  let nx = (match r16 regs 40 0x1FF with 0 -> 512 | n -> n)
  and ny = (match r16 regs 42 0x3FF with 0 -> 1024 | n -> n) in
  let clr = regs.(44) in
  t.kind <- Idle; t.tr <- false;
  let pb = per_byte g in
  let first_unit = ref false in
  (match cmd with
  | 0xF | 0xB ->                                    (* HMMC, LMMC: from the CPU *)
    let logical = cmd = 0xB in
    t.kind <- To_vram logical; t.lop <- lop; t.dix <- dix; t.diy <- diy;
    t.x0 <- (if logical then dx else dx / pb); t.x <- t.x0; t.y <- dy;
    t.nx <- (if logical then nx else max 1 (nx / pb)); t.left <- t.nx; t.rows <- ny;
    t.tr <- true;
    first_unit := true
  | 0xA ->                                          (* LMCM: to the CPU *)
    t.kind <- From_vram; t.dix <- dix; t.diy <- diy;
    t.x0 <- sx; t.x <- sx; t.y <- sy; t.nx <- nx; t.left <- nx; t.rows <- ny;
    st.(7) <- point t g sx sy; t.tr <- true
  | 0xE ->                                          (* YMMM: the column from DX to the edge *)
    let bx = dx / pb in
    let w = g.width / pb in
    for j = 0 to ny - 1 do
      let s = (sy + j * diy) land 1023 and d = (dy + j * diy) land 1023 in
      let x = ref bx in
      while !x >= 0 && !x < w do
        set t (d * g.line + !x) (get t (s * g.line + !x)); x := !x + dix
      done
    done
  | 0xD ->                                          (* HMMM: bytes *)
    let w = g.width / pb in
    let bsx = sx / pb and bdx = dx / pb and bnx = max 1 (nx / pb) in
    for j = 0 to ny - 1 do
      let s = (sy + j * diy) land 1023 and d = (dy + j * diy) land 1023 in
      let i = ref 0 in
      while !i < bnx && bsx + !i * dix >= 0 && bsx + !i * dix < w
            && bdx + !i * dix >= 0 && bdx + !i * dix < w do
        set t (d * g.line + bdx + !i * dix) (get t (s * g.line + bsx + !i * dix)); incr i
      done
    done
  | 0xC ->                                          (* HMMV: bytes of CLR *)
    let w = g.width / pb in
    let bdx = dx / pb and bnx = max 1 (nx / pb) in
    for j = 0 to ny - 1 do
      let d = (dy + j * diy) land 1023 in
      let i = ref 0 in
      while !i < bnx && bdx + !i * dix >= 0 && bdx + !i * dix < w do
        set t (d * g.line + bdx + !i * dix) clr; incr i
      done
    done
  | 0x9 ->                                          (* LMMM: pixels, logical *)
    for j = 0 to ny - 1 do
      let s = (sy + j * diy) land 1023 and d = (dy + j * diy) land 1023 in
      let i = ref 0 in
      while !i < nx && sx + !i * dix >= 0 && sx + !i * dix < g.width
            && dx + !i * dix >= 0 && dx + !i * dix < g.width do
        pset t g lop (dx + !i * dix) d (point t g (sx + !i * dix) s); incr i
      done
    done
  | 0x8 ->                                          (* LMMV: pixels of CLR, logical *)
    rect g ~x0:dx ~y0:dy ~nx ~ny ~dix ~diy (fun x y -> pset t g lop x y clr)
  | 0x7 ->                                          (* LINE: NX the long side, NY the short *)
    let maj = arg land 1 in
    let long = r16 regs 40 0x3FF and short = r16 regs 42 0x3FF in
    let x = ref dx and y = ref dy and e = ref 0 in
    for _ = 0 to long do
      if !x >= 0 && !x < g.width then pset t g lop !x (!y land 1023) clr;
      if maj = 0 then begin
        x := !x + dix; e := !e + short;
        if 2 * !e >= long && long > 0 then begin y := !y + diy; e := !e - long end
      end else begin
        y := !y + diy; e := !e + short;
        if 2 * !e >= long && long > 0 then begin x := !x + dix; e := !e - long end
      end
    done
  | 0x6 ->                                          (* SRCH: along X, for CLR (EQ: for another) *)
    let eq = arg land 2 <> 0 in
    let target = clr land ((1 lsl g.bpp) - 1) in
    let x = ref sx and found = ref false in
    while not !found && !x >= 0 && !x < g.width do
      let c = point t g !x sy in
      if (c = target) <> eq then found := true else x := !x + dix
    done;
    t.bd <- !found;
    if !found then begin st.(8) <- !x land 0xFF; st.(9) <- (!x lsr 8) land 1 end
  | 0x5 -> if dx < g.width then pset t g lop dx dy clr        (* PSET *)
  | 0x4 -> st.(7) <- point t g sx sy                        (* POINT *)
  | _ -> ());                                               (* STOP, and the unused *)
  (* HMMC's and LMMC's first unit is register 44 already *)
  if !first_unit then colour_written t regs clr st m

(* status register 7 read: a pixel of LMCM's, the next fetched; else
   what POINT left there *)
let read_colour t regs st (m : int) =
  ignore regs;
  let v = st.(7) in
  (match t.kind with
   | From_vram ->
     let g = geometry m in
     t.x <- t.x + t.dix; t.left <- t.left - 1;
     if t.left <= 0 then begin
       t.rows <- t.rows - 1; t.y <- t.y + t.diy; t.x <- t.x0; t.left <- t.nx
     end;
     if t.rows <= 0 then begin t.kind <- Idle; t.tr <- false end
     else st.(7) <- point t g t.x (t.y land 1023)
   | _ -> ());
  v

let busy t = t.kind <> Idle

(* status register 2's bits of the engine's: TR (7), BD (4), CE (0) *)
let status2 t = (if t.tr then 0x80 else 0) lor (if t.bd then 0x10 else 0) lor (if busy t then 1 else 0)

let state_size = 16

let save t =
  let b = Bytes.make state_size '\000' in
  let put i v = Bytes.set b i (Char.chr (v land 0xFF)) in
  put 0 (match t.kind with Idle -> 0 | To_vram false -> 1 | To_vram true -> 2 | From_vram -> 3);
  put 1 t.x; put 2 (t.x lsr 8); put 3 t.y; put 4 (t.y lsr 8);
  put 5 t.left; put 6 (t.left lsr 8); put 7 t.rows; put 8 (t.rows lsr 8);
  put 9 t.x0; put 10 (t.x0 lsr 8); put 11 t.nx; put 12 (t.nx lsr 8);
  put 13 ((if t.dix < 0 then 1 else 0) lor (if t.diy < 0 then 2 else 0) lor (if t.tr then 4 else 0)
          lor (if t.bd then 8 else 0));
  put 14 t.lop;
  Bytes.to_string b

let restore t s =
  let g i = Char.code s.[i] in
  let w i = g i lor (g (i + 1) lsl 8) in
  t.kind <- (match g 0 with 1 -> To_vram false | 2 -> To_vram true | 3 -> From_vram | _ -> Idle);
  t.x <- w 1; t.y <- w 3; t.left <- w 5; t.rows <- w 7; t.x0 <- w 9; t.nx <- w 11;
  let f = g 13 in
  t.dix <- (if f land 1 <> 0 then -1 else 1); t.diy <- (if f land 2 <> 0 then -1 else 1);
  t.tr <- f land 4 <> 0; t.bd <- f land 8 <> 0;
  t.lop <- g 14
