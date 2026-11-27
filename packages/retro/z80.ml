(* The Z80 (z80.mli; doc/decisions/retro-emulators.md). Written for MyNOS
   (MIT), after the behaviour FUSE documents and tests: its flag tables
   and macros (the undocumented bits 3 and 5, MEMPTR, the block
   instructions' flags) are followed here, so that its tests.in and
   tests.expected can check this core instruction by instruction.

   Registers are ints in a record, each always masked to its width: the
   same results with 31-bit (i386) and 63-bit (x86-64, AArch64) ints.
   An instruction is decoded by a match on its opcode (one jump in the
   bytecode), its T-states returned as a constant of its case. *)

type bus = {
  fetch : int -> int;
  read : int -> int;
  write : int -> int -> unit;
  input : int -> int;
  output : int -> int -> unit;
}

type t = {
  mutable a : int; mutable f : int;
  mutable b : int; mutable c : int;
  mutable d : int; mutable e : int;
  mutable h : int; mutable l : int;
  mutable af' : int; mutable bc' : int; mutable de' : int; mutable hl' : int;
  mutable ix : int; mutable iy : int;
  mutable sp : int; mutable pc : int;
  mutable i : int;
  mutable r : int;                     (* its 7 counting bits *)
  mutable r7 : int;                    (* its bit 7, as LD R,A left it *)
  mutable iff1 : bool; mutable iff2 : bool;
  mutable im : int;
  mutable halted : bool;
  mutable memptr : int;
  mutable ei_just : bool;              (* the last instruction was EI *)
  mutable q : int;                     (* Q: F if the last instruction set the flags *)
  mutable last_q : int;                (* the previous instruction's (SCF, CCF) *)
  mutable fw : bool;                   (* this instruction set the flags *)
  mutable tstates : int;
  mutable bus_ : bus;
  mutable fetch_ : int -> int;
  mutable read_ : int -> int;
  mutable write_ : int -> int -> unit;
  mutable input_ : int -> int;
  mutable output_ : int -> int -> unit;
}

(* ---- flags ---- *)

let fc = 0x01 and fn = 0x02 and fp = 0x04 and fv = 0x04
and f3 = 0x08 and fh = 0x10 and f5 = 0x20 and fz = 0x40 and fs = 0x80

let parity = Array.init 256 (fun i ->
    let rec ones x n = if x = 0 then n else ones (x lsr 1) (n + (x land 1)) in
    if ones i 0 land 1 = 0 then fp else 0)
let sz53 = Array.init 256 (fun i -> (i land (f3 lor f5 lor fs)) lor (if i = 0 then fz else 0))
let sz53p = Array.init 256 (fun i -> sz53.(i) lor parity.(i))
let halfcarry_add = [| 0; fh; fh; fh; 0; 0; 0; fh |]
let halfcarry_sub = [| 0; 0; fh; 0; fh; 0; fh; fh |]
let overflow_add = [| 0; 0; 0; fv; fv; 0; 0; 0 |]
let overflow_sub = [| 0; fv; 0; 0; 0; 0; fv; 0 |]

(* the flags, as an instruction computes them: Q follows (FUSE's Q = F) *)
let setf t v = t.f <- v; t.fw <- true

(* ---- the bus ---- *)

let set_bus t bus =
  t.bus_ <- bus;
  t.fetch_ <- bus.fetch; t.read_ <- bus.read; t.write_ <- bus.write;
  t.input_ <- bus.input; t.output_ <- bus.output

let bus t = t.bus_

let reset t =
  t.a <- 0xFF; t.f <- 0xFF; t.b <- 0; t.c <- 0; t.d <- 0; t.e <- 0; t.h <- 0; t.l <- 0;
  t.af' <- 0xFFFF; t.bc' <- 0; t.de' <- 0; t.hl' <- 0;
  t.ix <- 0; t.iy <- 0; t.sp <- 0xFFFF; t.pc <- 0;
  t.i <- 0; t.r <- 0; t.r7 <- 0;
  t.iff1 <- false; t.iff2 <- false; t.im <- 0; t.halted <- false;
  t.memptr <- 0; t.ei_just <- false; t.q <- 0; t.last_q <- 0

let create bus =
  let t = { a = 0; f = 0; b = 0; c = 0; d = 0; e = 0; h = 0; l = 0;
            af' = 0; bc' = 0; de' = 0; hl' = 0; ix = 0; iy = 0; sp = 0; pc = 0;
            i = 0; r = 0; r7 = 0; iff1 = false; iff2 = false; im = 0; halted = false;
            memptr = 0; ei_just = false; q = 0; last_q = 0; fw = false; tstates = 0;
            bus_ = bus; fetch_ = bus.fetch; read_ = bus.read; write_ = bus.write;
            input_ = bus.input; output_ = bus.output } in
  reset t;
  t

let halted t = t.halted
let tstates t = t.tstates
let set_tstates t n = t.tstates <- n

(* ---- memory, the stack, operands ---- *)

let rd t a = t.read_ (a land 0xFFFF)
let wr t a v = t.write_ (a land 0xFFFF) (v land 0xFF)
let rd16 t a = rd t a lor (rd t (a + 1) lsl 8)
let wr16 t a v = wr t a v; wr t (a + 1) (v lsr 8)

let inc_r t = t.r <- (t.r + 1) land 0x7F

(* an opcode's fetch (M1): R counts it *)
let fetch_op t =
  let v = t.fetch_ t.pc in
  t.pc <- (t.pc + 1) land 0xFFFF;
  inc_r t;
  v

let imm8 t =
  let v = t.read_ t.pc in
  t.pc <- (t.pc + 1) land 0xFFFF;
  v

let imm16 t =
  let lo = imm8 t in
  let hi = imm8 t in
  lo lor (hi lsl 8)

let disp t = let d = imm8 t in if d >= 128 then d - 256 else d

let push16 t v =
  t.sp <- (t.sp - 1) land 0xFFFF; wr t t.sp (v lsr 8);
  t.sp <- (t.sp - 1) land 0xFFFF; wr t t.sp v

let pop16 t =
  let lo = rd t t.sp in
  let hi = rd t (t.sp + 1) in
  t.sp <- (t.sp + 2) land 0xFFFF;
  lo lor (hi lsl 8)

let bc t = (t.b lsl 8) lor t.c
let de t = (t.d lsl 8) lor t.e
let hl t = (t.h lsl 8) lor t.l
let set_bc t v = t.b <- (v lsr 8) land 0xFF; t.c <- v land 0xFF
let set_de t v = t.d <- (v lsr 8) land 0xFF; t.e <- v land 0xFF
let set_hl t v = t.h <- (v lsr 8) land 0xFF; t.l <- v land 0xFF

(* ---- arithmetic (FUSE's macros) ---- *)

let add_a t v =
  let r = t.a + v in
  let lookup = ((t.a land 0x88) lsr 3) lor ((v land 0x88) lsr 2) lor ((r land 0x88) lsr 1) in
  t.a <- r land 0xFF;
  setf t @@ (if r land 0x100 <> 0 then fc else 0) lor halfcarry_add.(lookup land 7)
         lor overflow_add.(lookup lsr 4) lor sz53.(t.a)

let adc_a t v =
  let r = t.a + v + (t.f land fc) in
  let lookup = ((t.a land 0x88) lsr 3) lor ((v land 0x88) lsr 2) lor ((r land 0x88) lsr 1) in
  t.a <- r land 0xFF;
  setf t @@ (if r land 0x100 <> 0 then fc else 0) lor halfcarry_add.(lookup land 7)
         lor overflow_add.(lookup lsr 4) lor sz53.(t.a)

let sub_a t v =
  let r = t.a - v in
  let lookup = ((t.a land 0x88) lsr 3) lor ((v land 0x88) lsr 2) lor ((r land 0x88) lsr 1) in
  t.a <- r land 0xFF;
  setf t @@ (if r land 0x100 <> 0 then fc else 0) lor fn lor halfcarry_sub.(lookup land 7)
         lor overflow_sub.(lookup lsr 4) lor sz53.(t.a)

let sbc_a t v =
  let r = t.a - v - (t.f land fc) in
  let lookup = ((t.a land 0x88) lsr 3) lor ((v land 0x88) lsr 2) lor ((r land 0x88) lsr 1) in
  t.a <- r land 0xFF;
  setf t @@ (if r land 0x100 <> 0 then fc else 0) lor fn lor halfcarry_sub.(lookup land 7)
         lor overflow_sub.(lookup lsr 4) lor sz53.(t.a)

let and_a t v = t.a <- t.a land v; setf t @@ fh lor sz53p.(t.a)
let xor_a t v = t.a <- (t.a lxor v) land 0xFF; setf t @@ sz53p.(t.a)
let or_a t v = t.a <- (t.a lor v) land 0xFF; setf t @@ sz53p.(t.a)

let cp_a t v =
  let r = t.a - v in
  let lookup = ((t.a land 0x88) lsr 3) lor ((v land 0x88) lsr 2) lor ((r land 0x88) lsr 1) in
  setf t @@ (if r land 0x100 <> 0 then fc else if r = 0 then fz else 0) lor fn
         lor halfcarry_sub.(lookup land 7) lor overflow_sub.(lookup lsr 4)
         lor (v land (f3 lor f5)) lor (r land fs)

let alu t op v =
  match op with
  | 0 -> add_a t v | 1 -> adc_a t v | 2 -> sub_a t v | 3 -> sbc_a t v
  | 4 -> and_a t v | 5 -> xor_a t v | 6 -> or_a t v | _ -> cp_a t v

let inc8 t v =
  let v = (v + 1) land 0xFF in
  setf t @@ (t.f land fc) lor (if v = 0x80 then fv else 0)
         lor (if v land 0x0F <> 0 then 0 else fh) lor sz53.(v);
  v

let dec8 t v =
  let f = (t.f land fc) lor (if v land 0x0F <> 0 then 0 else fh) lor fn in
  let v = (v - 1) land 0xFF in
  setf t @@ f lor (if v = 0x7F then fv else 0) lor sz53.(v);
  v

(* ADD rr,rr': the result *)
let add16 t a b =
  let r = a + b in
  let lookup = ((a land 0x0800) lsr 11) lor ((b land 0x0800) lsr 10) lor ((r land 0x0800) lsr 9) in
  t.memptr <- (a + 1) land 0xFFFF;
  setf t @@ (t.f land (fv lor fz lor fs)) lor (if r land 0x10000 <> 0 then fc else 0)
         lor ((r lsr 8) land (f3 lor f5)) lor halfcarry_add.(lookup);
  r land 0xFFFF

let adc16 t v =
  let hlv = hl t in
  let r = hlv + v + (t.f land fc) in
  let lookup = ((hlv land 0x8800) lsr 11) lor ((v land 0x8800) lsr 10) lor ((r land 0x8800) lsr 9) in
  t.memptr <- (hlv + 1) land 0xFFFF;
  set_hl t (r land 0xFFFF);
  setf t @@ (if r land 0x10000 <> 0 then fc else 0) lor overflow_add.(lookup lsr 4)
         lor (t.h land (f3 lor f5 lor fs)) lor halfcarry_add.(lookup land 7)
         lor (if r land 0xFFFF = 0 then fz else 0)

let sbc16 t v =
  let hlv = hl t in
  let r = hlv - v - (t.f land fc) in
  let lookup = ((hlv land 0x8800) lsr 11) lor ((v land 0x8800) lsr 10) lor ((r land 0x8800) lsr 9) in
  t.memptr <- (hlv + 1) land 0xFFFF;
  set_hl t (r land 0xFFFF);
  setf t @@ (if r land 0x10000 <> 0 then fc else 0) lor fn lor overflow_sub.(lookup lsr 4)
         lor (t.h land (f3 lor f5 lor fs)) lor halfcarry_sub.(lookup land 7)
         lor (if r land 0xFFFF = 0 then fz else 0)

(* the CB rotations and shifts: op 0-7, the value; the flags set *)
let rot t op v =
  let r = match op with
    | 0 -> let r = ((v lsl 1) lor (v lsr 7)) land 0xFF in setf t @@ r land fc; r
    | 1 -> let r = ((v lsr 1) lor (v lsl 7)) land 0xFF in setf t @@ v land fc; r
    | 2 -> let r = ((v lsl 1) lor (t.f land fc)) land 0xFF in setf t @@ v lsr 7; r
    | 3 -> let r = ((v lsr 1) lor ((t.f land fc) lsl 7)) land 0xFF in setf t @@ v land fc; r
    | 4 -> let r = (v lsl 1) land 0xFF in setf t @@ v lsr 7; r
    | 5 -> let r = (v land 0x80) lor (v lsr 1) in setf t @@ v land fc; r
    | 6 -> let r = ((v lsl 1) lor 1) land 0xFF in setf t @@ v lsr 7; r
    | _ -> let r = v lsr 1 in setf t @@ v land fc; r in
  setf t @@ t.f lor sz53p.(r);
  r

(* BIT n: [xy] gives bits 3 and 5 (the value's, or MEMPTR's high byte) *)
let bit t n v xy =
  let f = (t.f land fc) lor fh lor (xy land (f3 lor f5)) in
  let f = if v land (1 lsl n) = 0 then f lor fp lor fz else f in
  setf t @@ (if n = 7 && v land 0x80 <> 0 then f lor fs else f)

(* ---- registers by their 3-bit field (6: none here) ---- *)

let get_r t n =
  match n with
  | 0 -> t.b | 1 -> t.c | 2 -> t.d | 3 -> t.e | 4 -> t.h | 5 -> t.l | _ -> t.a

let set_r t n v =
  match n with
  | 0 -> t.b <- v | 1 -> t.c <- v | 2 -> t.d <- v | 3 -> t.e <- v
  | 4 -> t.h <- v | 5 -> t.l <- v | _ -> t.a <- v

let get_rp t n = match n with 0 -> bc t | 1 -> de t | 2 -> hl t | _ -> t.sp
let set_rp t n v =
  match n with 0 -> set_bc t v | 1 -> set_de t v | 2 -> set_hl t v | _ -> t.sp <- v

(* the condition n (NZ Z NC C PO PE P M) *)
let cond t n =
  match n with
  | 0 -> t.f land fz = 0 | 1 -> t.f land fz <> 0
  | 2 -> t.f land fc = 0 | 3 -> t.f land fc <> 0
  | 4 -> t.f land fp = 0 | 5 -> t.f land fp <> 0
  | 6 -> t.f land fs = 0 | _ -> t.f land fs <> 0

(* ---- CB ---- *)

let exec_cb t =
  let op = fetch_op t in
  let x = op lsr 6 and y = (op lsr 3) land 7 and z = op land 7 in
  if z = 6 then begin
    let a = hl t in
    let v = rd t a in
    match x with
    | 0 -> wr t a (rot t y v); 15
    | 1 -> bit t y v (t.memptr lsr 8); 12
    | 2 -> wr t a (v land lnot (1 lsl y)); 15
    | _ -> wr t a (v lor (1 lsl y)); 15
  end else begin
    let v = get_r t z in
    (match x with
     | 0 -> set_r t z (rot t y v)
     | 1 -> bit t y v v
     | 2 -> set_r t z (v land lnot (1 lsl y))
     | _ -> set_r t z (v lor (1 lsl y)));
    8
  end

(* DDCB, FDCB: the displacement, then the opcode (reads, not fetches);
   the result also to the register z (undocumented) unless z = 6 *)
let exec_xycb t base =
  let d = disp t in
  let op = imm8 t in
  let a = (base + d) land 0xFFFF in
  t.memptr <- a;
  let x = op lsr 6 and y = (op lsr 3) land 7 and z = op land 7 in
  let v = rd t a in
  if x = 1 then begin bit t y v (a lsr 8); 20 end
  else begin
    let r = match x with
      | 0 -> rot t y v
      | 2 -> v land lnot (1 lsl y)
      | _ -> v lor (1 lsl y) in
    wr t a r;
    if z <> 6 then set_r t z r;
    23
  end

(* ---- ED ---- *)

let exec_ed t =
  let op = fetch_op t in
  match op with
  (* IN r,(C) / IN F,(C) *)
  | 0x40 | 0x48 | 0x50 | 0x58 | 0x60 | 0x68 | 0x70 | 0x78 ->
    let port = bc t in
    let v = t.input_ port land 0xFF in
    t.memptr <- (port + 1) land 0xFFFF;
    setf t @@ (t.f land fc) lor sz53p.(v);
    let n = (op lsr 3) land 7 in
    if n <> 6 then set_r t n v;
    12
  (* OUT (C),r / OUT (C),0 *)
  | 0x41 | 0x49 | 0x51 | 0x59 | 0x61 | 0x69 | 0x71 | 0x79 ->
    let port = bc t in
    let n = (op lsr 3) land 7 in
    t.output_ port (if n = 6 then 0 else get_r t n);
    t.memptr <- (port + 1) land 0xFFFF;
    12
  | 0x42 | 0x52 | 0x62 | 0x72 -> sbc16 t (get_rp t ((op lsr 4) land 3)); 15
  | 0x4A | 0x5A | 0x6A | 0x7A -> adc16 t (get_rp t ((op lsr 4) land 3)); 15
  | 0x43 | 0x53 | 0x63 | 0x73 ->
    let a = imm16 t in
    wr16 t a (get_rp t ((op lsr 4) land 3));
    t.memptr <- (a + 1) land 0xFFFF;
    20
  | 0x4B | 0x5B | 0x6B | 0x7B ->
    let a = imm16 t in
    set_rp t ((op lsr 4) land 3) (rd16 t a);
    t.memptr <- (a + 1) land 0xFFFF;
    20
  | 0x44 | 0x4C | 0x54 | 0x5C | 0x64 | 0x6C | 0x74 | 0x7C ->
    let v = t.a in t.a <- 0; sub_a t v; 8
  | 0x45 | 0x4D | 0x55 | 0x5D | 0x65 | 0x6D | 0x75 | 0x7D ->
    t.iff1 <- t.iff2;
    t.pc <- pop16 t; t.memptr <- t.pc;
    14
  | 0x46 | 0x4E | 0x66 | 0x6E -> t.im <- 0; 8
  | 0x56 | 0x76 -> t.im <- 1; 8
  | 0x5E | 0x7E -> t.im <- 2; 8
  | 0x47 -> t.i <- t.a; 9
  | 0x4F -> t.r <- t.a land 0x7F; t.r7 <- t.a land 0x80; 9
  | 0x57 ->
    t.a <- t.i;
    setf t @@ (t.f land fc) lor sz53.(t.a) lor (if t.iff2 then fv else 0);
    9
  | 0x5F ->
    t.a <- t.r lor t.r7;
    setf t @@ (t.f land fc) lor sz53.(t.a) lor (if t.iff2 then fv else 0);
    9
  | 0x67 ->                                       (* RRD *)
    let a = hl t in
    let v = rd t a in
    wr t a ((t.a lsl 4) lor (v lsr 4));
    t.a <- (t.a land 0xF0) lor (v land 0x0F);
    setf t @@ (t.f land fc) lor sz53p.(t.a);
    t.memptr <- (a + 1) land 0xFFFF;
    18
  | 0x6F ->                                       (* RLD *)
    let a = hl t in
    let v = rd t a in
    wr t a ((v lsl 4) lor (t.a land 0x0F));
    t.a <- (t.a land 0xF0) lor (v lsr 4);
    setf t @@ (t.f land fc) lor sz53p.(t.a);
    t.memptr <- (a + 1) land 0xFFFF;
    18
  (* LDI LDD LDIR LDDR *)
  | 0xA0 | 0xA8 | 0xB0 | 0xB8 ->
    let step = if op land 8 = 0 then 1 else -1 in
    let v = rd t (hl t) in
    let n = (bc t - 1) land 0xFFFF in
    set_bc t n;
    wr t (de t) v;
    set_de t ((de t + step) land 0xFFFF);
    set_hl t ((hl t + step) land 0xFFFF);
    let v = (v + t.a) land 0xFF in
    setf t @@ (t.f land (fc lor fz lor fs)) lor (if n <> 0 then fv else 0)
           lor (v land f3) lor (if v land 0x02 <> 0 then f5 else 0);
    if op >= 0xB0 && n <> 0 then begin
      t.pc <- (t.pc - 2) land 0xFFFF;
      t.memptr <- (t.pc + 1) land 0xFFFF;
      21
    end else 16
  (* CPI CPD CPIR CPDR *)
  | 0xA1 | 0xA9 | 0xB1 | 0xB9 ->
    let step = if op land 8 = 0 then 1 else -1 in
    let v = rd t (hl t) in
    let r = (t.a - v) land 0xFF in
    let lookup = ((t.a land 0x08) lsr 3) lor ((v land 0x08) lsr 2) lor ((r land 0x08) lsr 1) in
    set_hl t ((hl t + step) land 0xFFFF);
    let n = (bc t - 1) land 0xFFFF in
    set_bc t n;
    setf t @@ (t.f land fc) lor (if n <> 0 then fv lor fn else fn) lor halfcarry_sub.(lookup)
           lor (if r = 0 then fz else 0) lor (r land fs);
    let r = if t.f land fh <> 0 then (r - 1) land 0xFF else r in
    setf t @@ t.f lor (r land f3) lor (if r land 0x02 <> 0 then f5 else 0);
    t.memptr <- (t.memptr + step) land 0xFFFF;
    if op >= 0xB0 && t.f land (fv lor fz) = fv then begin
      t.pc <- (t.pc - 2) land 0xFFFF;
      t.memptr <- (t.pc + 1) land 0xFFFF;
      21
    end else 16
  (* INI IND INIR INDR *)
  | 0xA2 | 0xAA | 0xB2 | 0xBA ->
    let step = if op land 8 = 0 then 1 else -1 in
    let port = bc t in
    let v = t.input_ port land 0xFF in
    wr t (hl t) v;
    t.memptr <- (port + step) land 0xFFFF;
    t.b <- (t.b - 1) land 0xFF;
    set_hl t ((hl t + step) land 0xFFFF);
    let v2 = v + ((t.c + step) land 0xFF) in
    setf t @@ (if v land 0x80 <> 0 then fn else 0) lor (if v2 > 0xFF then fh lor fc else 0)
           lor parity.(((v2 land 0xFF) land 0x07) lxor t.b) lor sz53.(t.b);
    if op >= 0xB0 && t.b <> 0 then begin t.pc <- (t.pc - 2) land 0xFFFF; 21 end else 16
  (* OUTI OUTD OTIR OTDR *)
  | 0xA3 | 0xAB | 0xB3 | 0xBB ->
    let step = if op land 8 = 0 then 1 else -1 in
    let v = rd t (hl t) in
    t.b <- (t.b - 1) land 0xFF;
    let port = bc t in
    t.memptr <- (port + step) land 0xFFFF;
    t.output_ port v;
    set_hl t ((hl t + step) land 0xFFFF);
    let v2 = v + t.l in
    setf t @@ (if v land 0x80 <> 0 then fn else 0) lor (if v2 > 0xFF then fh lor fc else 0)
           lor parity.(((v2 land 0xFF) land 0x07) lxor t.b) lor sz53.(t.b);
    if op >= 0xB0 && t.b <> 0 then begin t.pc <- (t.pc - 2) land 0xFFFF; 21 end else 16
  | _ -> 8                                        (* a NOP of 8 T-states *)

(* ---- the unprefixed instructions; HL's place taken by IX or IY for DD
   and FD: [xy] 0 HL, 1 IX, 2 IY ---- *)

let get_xy t xy = match xy with 1 -> t.ix | _ -> t.iy
let set_xy t xy v = match xy with 1 -> t.ix <- v | _ -> t.iy <- v

(* H and L, or IXH/IXL, IYH/IYL *)
let get_rx t xy n =
  if xy = 0 || (n <> 4 && n <> 5) then get_r t n
  else let v = get_xy t xy in if n = 4 then v lsr 8 else v land 0xFF

let set_rx t xy n v =
  if xy = 0 || (n <> 4 && n <> 5) then set_r t n v
  else
    let w = get_xy t xy in
    set_xy t xy (if n = 4 then (v lsl 8) lor (w land 0xFF) else (w land 0xFF00) lor v)

(* (HL), or (IX+d) / (IY+d): the address; the displacement read here *)
let addr_m t xy =
  if xy = 0 then hl t
  else begin
    let a = (get_xy t xy + disp t) land 0xFFFF in
    t.memptr <- a;
    a
  end

let get_hlx t xy = if xy = 0 then hl t else get_xy t xy
let set_hlx t xy v = if xy = 0 then set_hl t v else set_xy t xy v

let rec exec t op xy =
  (* the 4 extra T-states of an index register's instruction: 8 for
     instructions on IXH/IXL, 8 + 11 on (IX+d) *)
  match op lsr 6 with
  | 1 ->
    if op = 0x76 then begin                       (* HALT *)
      t.halted <- true; t.pc <- (t.pc - 1) land 0xFFFF; 4
    end else begin
      let y = (op lsr 3) land 7 and z = op land 7 in
      if z = 6 then begin                         (* LD r,(HL) *)
        let a = addr_m t xy in
        set_r t y (rd t a);
        if xy = 0 then 7 else 15
      end else if y = 6 then begin                (* LD (HL),r *)
        let a = addr_m t xy in
        wr t a (get_r t z);
        if xy = 0 then 7 else 15
      end else begin
        set_rx t xy y (get_rx t xy z);
        if xy = 0 then 4 else 4
      end
    end
  | 2 ->
    let y = (op lsr 3) land 7 and z = op land 7 in
    if z = 6 then begin
      let a = addr_m t xy in
      alu t y (rd t a);
      if xy = 0 then 7 else 15
    end else begin
      alu t y (get_rx t xy z);
      4
    end
  | 0 -> exec_low t op xy
  | _ -> exec_high t op xy

and exec_low t op xy =
  match op with
  | 0x00 -> 4
  | 0x01 | 0x11 | 0x31 -> set_rp t (op lsr 4) (imm16 t); 10
  | 0x21 -> set_hlx t xy (imm16 t); 10
  | 0x02 ->
    let a = bc t in wr t a t.a; t.memptr <- ((a + 1) land 0xFF) lor (t.a lsl 8); 7
  | 0x12 ->
    let a = de t in wr t a t.a; t.memptr <- ((a + 1) land 0xFF) lor (t.a lsl 8); 7
  | 0x0A -> let a = bc t in t.a <- rd t a; t.memptr <- (a + 1) land 0xFFFF; 7
  | 0x1A -> let a = de t in t.a <- rd t a; t.memptr <- (a + 1) land 0xFFFF; 7
  | 0x03 | 0x13 | 0x33 -> let n = op lsr 4 in set_rp t n ((get_rp t n + 1) land 0xFFFF); 6
  | 0x0B | 0x1B | 0x3B -> let n = op lsr 4 in set_rp t n ((get_rp t n - 1) land 0xFFFF); 6
  | 0x23 -> set_hlx t xy ((get_hlx t xy + 1) land 0xFFFF); 6
  | 0x2B -> set_hlx t xy ((get_hlx t xy - 1) land 0xFFFF); 6
  | 0x04 | 0x0C | 0x14 | 0x1C | 0x24 | 0x2C | 0x3C ->
    let n = op lsr 3 in set_rx t xy n (inc8 t (get_rx t xy n)); 4
  | 0x05 | 0x0D | 0x15 | 0x1D | 0x25 | 0x2D | 0x3D ->
    let n = op lsr 3 in set_rx t xy n (dec8 t (get_rx t xy n)); 4
  | 0x34 -> let a = addr_m t xy in wr t a (inc8 t (rd t a)); if xy = 0 then 11 else 19
  | 0x35 -> let a = addr_m t xy in wr t a (dec8 t (rd t a)); if xy = 0 then 11 else 19
  | 0x06 | 0x0E | 0x16 | 0x1E | 0x26 | 0x2E | 0x3E ->
    let n = op lsr 3 in set_rx t xy n (imm8 t); 7
  | 0x36 ->
    let a = addr_m t xy in
    wr t a (imm8 t);
    if xy = 0 then 10 else 15
  | 0x07 ->
    t.a <- ((t.a lsl 1) lor (t.a lsr 7)) land 0xFF;
    setf t @@ (t.f land (fp lor fz lor fs)) lor (t.a land (fc lor f3 lor f5)); 4
  | 0x0F ->
    setf t @@ (t.f land (fp lor fz lor fs)) lor (t.a land fc);
    t.a <- ((t.a lsr 1) lor (t.a lsl 7)) land 0xFF;
    setf t @@ t.f lor (t.a land (f3 lor f5)); 4
  | 0x17 ->
    let old = t.a in
    t.a <- ((t.a lsl 1) lor (t.f land fc)) land 0xFF;
    setf t @@ (t.f land (fp lor fz lor fs)) lor (t.a land (f3 lor f5)) lor (old lsr 7); 4
  | 0x1F ->
    let old = t.a in
    t.a <- ((t.a lsr 1) lor ((t.f land fc) lsl 7)) land 0xFF;
    setf t @@ (t.f land (fp lor fz lor fs)) lor (t.a land (f3 lor f5)) lor (old land fc); 4
  | 0x08 ->
    let af = (t.a lsl 8) lor t.f in
    t.a <- t.af' lsr 8; t.f <- t.af' land 0xFF; t.af' <- af; 4
  | 0x09 | 0x19 | 0x29 | 0x39 ->
    let n = op lsr 4 in
    let v = if n = 2 then get_hlx t xy else get_rp t n in
    set_hlx t xy (add16 t (get_hlx t xy) v);
    11
  | 0x10 ->
    t.b <- (t.b - 1) land 0xFF;
    if t.b <> 0 then begin
      let d = disp t in
      t.pc <- (t.pc + d) land 0xFFFF; t.memptr <- t.pc; 13
    end else begin t.pc <- (t.pc + 1) land 0xFFFF; 8 end
  | 0x18 -> let d = disp t in t.pc <- (t.pc + d) land 0xFFFF; t.memptr <- t.pc; 12
  | 0x20 | 0x28 | 0x30 | 0x38 ->
    if cond t ((op lsr 3) land 3) then begin
      let d = disp t in
      t.pc <- (t.pc + d) land 0xFFFF; t.memptr <- t.pc; 12
    end else begin t.pc <- (t.pc + 1) land 0xFFFF; 7 end
  | 0x22 ->
    let a = imm16 t in
    wr16 t a (get_hlx t xy); t.memptr <- (a + 1) land 0xFFFF; 16
  | 0x2A ->
    let a = imm16 t in
    set_hlx t xy (rd16 t a); t.memptr <- (a + 1) land 0xFFFF; 16
  | 0x32 ->
    let a = imm16 t in
    wr t a t.a; t.memptr <- ((a + 1) land 0xFF) lor (t.a lsl 8); 13
  | 0x3A ->
    let a = imm16 t in
    t.a <- rd t a; t.memptr <- (a + 1) land 0xFFFF; 13
  | 0x27 ->                                        (* DAA *)
    let add = if t.f land fh <> 0 || t.a land 0x0F > 9 then 6 else 0 in
    let carry = t.f land fc in
    let add, carry =
      if carry <> 0 || t.a > 0x99 then add lor 0x60, (if t.a > 0x99 then fc else carry)
      else add, carry in
    if t.f land fn <> 0 then sub_a t add else add_a t add;
    setf t @@ (t.f land lnot (fc lor fp)) lor carry lor parity.(t.a);
    4
  | 0x2F ->
    t.a <- t.a lxor 0xFF;
    setf t @@ (t.f land (fc lor fp lor fz lor fs)) lor (t.a land (f3 lor f5)) lor fn lor fh; 4
  (* SCF, CCF: bits 3 and 5 from A, or from F too when the last
     instruction did not set the flags (Q: an NMOS Z80's) *)
  | 0x37 ->
    setf t @@ (t.f land (fp lor fz lor fs))
              lor (((t.last_q lxor t.f) lor t.a) land (f3 lor f5)) lor fc; 4
  | 0x3F ->
    setf t @@ (t.f land (fp lor fz lor fs)) lor (if t.f land fc <> 0 then fh else fc)
              lor (((t.last_q lxor t.f) lor t.a) land (f3 lor f5)); 4
  | _ -> 4

and exec_high t op xy =
  match op with
  | 0xC0 | 0xC8 | 0xD0 | 0xD8 | 0xE0 | 0xE8 | 0xF0 | 0xF8 ->
    if cond t ((op lsr 3) land 7) then begin t.pc <- pop16 t; t.memptr <- t.pc; 11 end
    else 5
  | 0xC9 -> t.pc <- pop16 t; t.memptr <- t.pc; 10
  | 0xC1 | 0xD1 -> set_rp t ((op lsr 4) land 3) (pop16 t); 10
  | 0xE1 -> set_hlx t xy (pop16 t); 10
  | 0xF1 -> let v = pop16 t in t.a <- v lsr 8; t.f <- v land 0xFF; 10
  | 0xC5 | 0xD5 -> push16 t (get_rp t ((op lsr 4) land 3)); 11
  | 0xE5 -> push16 t (get_hlx t xy); 11
  | 0xF5 -> push16 t ((t.a lsl 8) lor t.f); 11
  | 0xC2 | 0xCA | 0xD2 | 0xDA | 0xE2 | 0xEA | 0xF2 | 0xFA ->
    let a = imm16 t in
    t.memptr <- a;
    if cond t ((op lsr 3) land 7) then t.pc <- a;
    10
  | 0xC3 -> let a = imm16 t in t.pc <- a; t.memptr <- a; 10
  | 0xC4 | 0xCC | 0xD4 | 0xDC | 0xE4 | 0xEC | 0xF4 | 0xFC ->
    let a = imm16 t in
    t.memptr <- a;
    if cond t ((op lsr 3) land 7) then begin push16 t t.pc; t.pc <- a; 17 end else 10
  | 0xCD -> let a = imm16 t in t.memptr <- a; push16 t t.pc; t.pc <- a; 17
  | 0xC6 | 0xCE | 0xD6 | 0xDE | 0xE6 | 0xEE | 0xF6 | 0xFE ->
    alu t ((op lsr 3) land 7) (imm8 t); 7
  | 0xC7 | 0xCF | 0xD7 | 0xDF | 0xE7 | 0xEF | 0xF7 | 0xFF ->
    push16 t t.pc; t.pc <- op land 0x38; t.memptr <- t.pc; 11
  | 0xCB ->
    if xy = 0 then exec_cb t
    else exec_xycb t (get_xy t xy) - 4             (* (its 4 counted by [prefixed]) *)
  | 0xD3 ->
    let n = imm8 t in
    t.output_ (n lor (t.a lsl 8)) t.a;
    t.memptr <- ((n + 1) land 0xFF) lor (t.a lsl 8);
    11
  | 0xDB ->
    let port = imm8 t lor (t.a lsl 8) in
    t.a <- t.input_ port land 0xFF;
    t.memptr <- (port + 1) land 0xFFFF;
    11
  | 0xD9 ->
    let v = bc t in set_bc t t.bc'; t.bc' <- v;
    let v = de t in set_de t t.de'; t.de' <- v;
    let v = hl t in set_hl t t.hl'; t.hl' <- v;
    4
  | 0xE3 ->
    let v = rd16 t t.sp in
    wr16 t t.sp (get_hlx t xy);
    set_hlx t xy v; t.memptr <- v;
    19
  | 0xE9 -> t.pc <- get_hlx t xy; 4
  | 0xF9 -> t.sp <- get_hlx t xy; 6
  | 0xEB -> let v = de t in set_de t (hl t); set_hl t v; 4
  | 0xF3 -> t.iff1 <- false; t.iff2 <- false; 4
  | 0xFB -> t.iff1 <- true; t.iff2 <- true; t.ei_just <- true; 4
  | 0xED -> exec_ed t
  | _ -> 4                                         (* DD, FD: [step]'s *)

(* the T-states an index register adds to an instruction (the prefix's 4
   apart): 0 for the instructions it does not touch *)
let uses_index op =
  match op with
  | 0x09 | 0x19 | 0x21 | 0x22 | 0x23 | 0x24 | 0x25 | 0x26 | 0x29 | 0x2A | 0x2B
  | 0x2C | 0x2D | 0x2E | 0x34 | 0x35 | 0x36 | 0x39
  | 0xCB | 0xE1 | 0xE3 | 0xE5 | 0xE9 | 0xF9 -> true
  | _ ->
    (op >= 0x40 && op < 0xC0 && op <> 0x76 &&
     (let y = (op lsr 3) land 7 and z = op land 7 in
      (op < 0x80 && (y = 4 || y = 5 || y = 6)) || z = 4 || z = 5 || z = 6))

(* after a DD or FD: its instruction, in the same step (an interrupt never
   comes between); an instruction that uses no index register runs as
   it would alone (FUSE passes through its end_opcode again: last Q 0),
   another DD or FD prefix included *)
let rec prefixed t xy acc =
  let op = fetch_op t in
  match op with
  | 0xDD -> t.last_q <- 0; prefixed t 1 (acc + 4)
  | 0xFD -> t.last_q <- 0; prefixed t 2 (acc + 4)
  | _ when uses_index op -> acc + exec t op xy
  | _ -> t.last_q <- 0; acc + exec t op 0

let step t =
  t.ei_just <- false;
  t.last_q <- t.q;
  t.fw <- false;
  let op = fetch_op t in
  let n =
    match op with
    | 0xDD -> prefixed t 1 4
    | 0xFD -> prefixed t 2 4
    | _ -> exec t op 0 in
  t.q <- (if t.fw then t.f else 0);
  t.tstates <- t.tstates + n;
  n

let interrupt t data =
  if not t.iff1 || t.ei_just then 0
  else begin
    if t.halted then begin t.halted <- false; t.pc <- (t.pc + 1) land 0xFFFF end;
    t.iff1 <- false; t.iff2 <- false;
    inc_r t;
    push16 t t.pc;
    let n = match t.im with
      | 2 ->
        let v = ((t.i lsl 8) lor (data land 0xFF)) in
        t.pc <- rd16 t v; 19
      | 0 when data land 0xC7 = 0xC7 -> t.pc <- data land 0x38; 13
      | _ -> t.pc <- 0x38; 13 in
    t.memptr <- t.pc;
    t.tstates <- t.tstates + n;
    n
  end

let nmi t =
  if t.halted then begin t.halted <- false; t.pc <- (t.pc + 1) land 0xFFFF end;
  t.iff1 <- false;
  inc_r t;
  push16 t t.pc;
  t.pc <- 0x66; t.memptr <- t.pc;
  t.tstates <- t.tstates + 11;
  11

(* ---- registers ---- *)

type reg =
  | A | F | B | C | D | E | H | L | AF | BC | DE | HL
  | AF' | BC' | DE' | HL' | IX | IY | SP | PC | I | R
  | IM | IFF1 | IFF2 | MEMPTR

let get t = function
  | A -> t.a | F -> t.f | B -> t.b | C -> t.c | D -> t.d | E -> t.e | H -> t.h | L -> t.l
  | AF -> (t.a lsl 8) lor t.f | BC -> bc t | DE -> de t | HL -> hl t
  | AF' -> t.af' | BC' -> t.bc' | DE' -> t.de' | HL' -> t.hl'
  | IX -> t.ix | IY -> t.iy | SP -> t.sp | PC -> t.pc | I -> t.i | R -> t.r lor t.r7
  | IM -> t.im | IFF1 -> Bool.to_int t.iff1 | IFF2 -> Bool.to_int t.iff2 | MEMPTR -> t.memptr

let set t reg v =
  let b = v land 0xFF and w = v land 0xFFFF in
  match reg with
  | A -> t.a <- b | F -> t.f <- b | B -> t.b <- b | C -> t.c <- b | D -> t.d <- b
  | E -> t.e <- b | H -> t.h <- b | L -> t.l <- b
  | AF -> t.a <- w lsr 8; t.f <- w land 0xFF
  | BC -> set_bc t w | DE -> set_de t w | HL -> set_hl t w
  | AF' -> t.af' <- w | BC' -> t.bc' <- w | DE' -> t.de' <- w | HL' -> t.hl' <- w
  | IX -> t.ix <- w | IY -> t.iy <- w | SP -> t.sp <- w | PC -> t.pc <- w
  | I -> t.i <- b | R -> t.r <- b land 0x7F; t.r7 <- b land 0x80
  | IM -> t.im <- v land 3 | IFF1 -> t.iff1 <- v <> 0 | IFF2 -> t.iff2 <- v <> 0
  | MEMPTR -> t.memptr <- w

let registers t =
  List.map (fun (n, r) -> n, get t r)
    [ "AF", AF; "BC", BC; "DE", DE; "HL", HL; "AF'", AF'; "BC'", BC'; "DE'", DE';
      "HL'", HL'; "IX", IX; "IY", IY; "SP", SP; "PC", PC; "I", I; "R", R; "IM", IM;
      "IFF1", IFF1; "IFF2", IFF2; "MEMPTR", MEMPTR ]
  @ [ "HALT", Bool.to_int t.halted; "T", t.tstates ]

(* ---- decoding, shared with Z80_disasm ---- *)

type prefix = Plain | Cb | Ed | Dd | Fd | Ddcb | Fdcb

let decode read pc =
  let rd a = read (a land 0xFFFF) in
  let sx v = if v >= 128 then v - 256 else v in
  let rec go pc pre =
    let op = rd pc in
    match op with
    | 0xDD -> go (pc + 1) Dd
    | 0xFD -> go (pc + 1) Fd
    | 0xCB when pre = Plain -> Cb, rd (pc + 1), 0, (pc + 2) land 0xFFFF
    | 0xCB -> (if pre = Dd then Ddcb else Fdcb), rd (pc + 2), sx (rd (pc + 1)), (pc + 3) land 0xFFFF
    | 0xED -> Ed, rd (pc + 1), 0, (pc + 2) land 0xFFFF
    | _ when (pre = Dd || pre = Fd) && uses_index op ->
      let needs_d = op = 0x34 || op = 0x35 || op = 0x36
                    || (op >= 0x40 && op < 0xC0 && op <> 0x76 &&
                        ((op land 7) = 6 || (op < 0x80 && (op lsr 3) land 7 = 6))) in
      if needs_d then pre, op, sx (rd (pc + 1)), (pc + 2) land 0xFFFF
      else pre, op, 0, (pc + 1) land 0xFFFF
    | _ -> Plain, op, 0, (pc + 1) land 0xFFFF in
  go pc Plain

let r8 = [| "B"; "C"; "D"; "E"; "H"; "L"; "(HL)"; "A" |]
let rp = [| "BC"; "DE"; "HL"; "SP" |]
let rp2 = [| "BC"; "DE"; "HL"; "AF" |]
let cc = [| "NZ"; "Z"; "NC"; "C"; "PO"; "PE"; "P"; "M" |]
let alu = [| "ADD A,"; "ADC A,"; "SUB "; "SBC A,"; "AND "; "XOR "; "OR "; "CP " |]
let rot = [| "RLC"; "RRC"; "RL"; "RR"; "SLA"; "SRA"; "SLL"; "SRL" |]
