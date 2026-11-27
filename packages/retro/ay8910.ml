(* The AY-3-8910 (ay8910.mli).

   The chip divides its clock by 8 for the tone counters (a channel's
   output turns over each time its counter reaches the period: a square
   of clock / (16 x period)), by 16 for the noise (a 17-bit shift register
   stepped when its counter reaches the period) and for the envelope (one
   of its 16 levels a period). Here the chip's ticks are counted at clock
   / 8, the noise and the envelope on every other one.

   A frame's writes are kept with their T-states while the sound is on;
   [samples] then runs the chip through the frame, a write applied when
   its time comes, and makes each sample the mean of the ticks it covers
   (a box filter), less its mean over time (the output's capacitor, a
   high-pass filter), as 16 bits. *)

let rate = 22050.

(* the DAC's 16 levels, logarithmic (3 dB a step, about), 0 to 1 *)
let levels = [| 0.; 0.0137; 0.0205; 0.0291; 0.0423; 0.0618; 0.0847; 0.1369;
                0.1691; 0.2647; 0.3527; 0.4499; 0.5704; 0.6873; 0.8482; 1.0 |]

let masks = [| 0xFF; 0x0F; 0xFF; 0x0F; 0xFF; 0x0F; 0x1F; 0xFF;
               0x1F; 0x1F; 0x1F; 0xFF; 0xFF; 0x0F; 0xFF; 0xFF |]

type t = {
  regs : int array;
  mutable sel : int;
  mutable port_in : int -> int;
  mutable on : bool;
  mutable writes : (int * int * int) list;   (* (tstate, reg, value), latest first *)
  ticks_per_t : float;                        (* chip ticks (clock / 8) per T-state *)
  ticks_per_sample : float;
  (* the generator's state *)
  count : int array;                          (* the tone counters *)
  out : bool array;                           (* the tone outputs *)
  mutable noise_count : int;
  mutable lfsr : int;
  mutable noise_out : bool;
  mutable env_count : int;
  mutable env_step : int;                     (* 0 to 15 *)
  mutable env_attack : bool;                  (* rising now *)
  mutable env_hold : bool;
  mutable half : bool;                        (* the noise and the envelope: every other tick *)
  mutable carry : float;                      (* ticks of a sample begun in the last frame *)
  mutable carry_sum : float;
  mutable tick_carry : float;                 (* a tick's part, left by the last frame *)
  mutable dc : float;                         (* the high-pass filter's mean *)
  buf : Buffer.t;
}

let create ~clock ~cpu_clock =
  { regs = Array.make 16 0; sel = 0; port_in = (fun _ -> 0xFF); on = false; writes = [];
    ticks_per_t = float clock /. 8. /. float cpu_clock;
    ticks_per_sample = float clock /. 8. /. rate;
    count = Array.make 3 0; out = Array.make 3 false;
    noise_count = 0; lfsr = 1; noise_out = false;
    env_count = 0; env_step = 0; env_attack = false; env_hold = true; half = false;
    carry = 0.; carry_sum = 0.; tick_carry = 0.; dc = 0.; buf = Buffer.create 4096 }

let env_restart t =
  let shape = t.regs.(13) in
  t.env_count <- 0; t.env_step <- 0;
  t.env_attack <- shape land 4 <> 0;
  t.env_hold <- false

(* a register's value, into the generator *)
let apply t r v =
  t.regs.(r) <- v land masks.(r);
  if r = 13 then env_restart t

let reset t =
  Array.fill t.regs 0 16 0;
  t.regs.(7) <- 0xFF;
  t.sel <- 0; t.writes <- [];
  env_restart t; t.env_hold <- true; t.env_step <- 15; t.env_attack <- false

let select t r = t.sel <- r land 0xFF

let write t ~tstate v =
  if t.sel < 16 then begin
    if t.on then t.writes <- (tstate, t.sel, v) :: t.writes
    else apply t t.sel v
  end

let read t =
  match t.sel with
  | 14 -> t.port_in 0
  | 15 -> if t.regs.(7) land 0x80 <> 0 then t.regs.(15) else t.port_in 1
  | r when r < 16 -> t.regs.(r)
  | _ -> 0xFF

let set_port_in t f = t.port_in <- f
let registers t = Array.copy t.regs
let set_registers t a =
  Array.iteri (fun i v -> if i < 16 then t.regs.(i) <- v land masks.(i)) a;
  env_restart t

let on t = t.on
let set_on t v =
  (* the writes kept: applied now, in their order *)
  List.iter (fun (_, r, v) -> apply t r v) (List.rev t.writes);
  t.writes <- [];
  t.on <- v; t.carry <- 0.; t.carry_sum <- 0.; t.tick_carry <- 0.

let tone_period t c = max 1 (t.regs.(2 * c) lor (t.regs.(2 * c + 1) lsl 8))

(* one tick (clock / 8): the level of the three channels, mixed, 0 to 3 *)
let tick t =
  for c = 0 to 2 do
    let n = t.count.(c) + 1 in
    if n >= tone_period t c then begin t.count.(c) <- 0; t.out.(c) <- not t.out.(c) end
    else t.count.(c) <- n
  done;
  t.half <- not t.half;
  if t.half then begin
    let n = t.noise_count + 1 in
    if n >= max 1 t.regs.(6) then begin
      t.noise_count <- 0;
      (* 17 bits, taps 0 and 3 *)
      let bit = (t.lfsr lxor (t.lfsr lsr 3)) land 1 in
      t.lfsr <- (t.lfsr lsr 1) lor (bit lsl 16);
      t.noise_out <- t.lfsr land 1 <> 0
    end else t.noise_count <- n;
    if not t.env_hold then begin
      let n = t.env_count + 1 in
      if n >= max 1 (t.regs.(11) lor (t.regs.(12) lsl 8)) then begin
        t.env_count <- 0;
        if t.env_step < 15 then t.env_step <- t.env_step + 1
        else begin
          (* the cycle's end: CONTINUE, ATTACK, ALTERNATE, HOLD *)
          let shape = t.regs.(13) in
          if shape land 8 = 0 then begin
            t.env_hold <- true; t.env_attack <- false; t.env_step <- 15
          end else if shape land 1 <> 0 then begin
            t.env_hold <- true;
            if shape land 2 <> 0 then t.env_attack <- not t.env_attack;
            t.env_step <- 15
          end else begin
            if shape land 2 <> 0 then t.env_attack <- not t.env_attack;
            t.env_step <- 0
          end
        end
      end else t.env_count <- n
    end
  end;
  let mixer = t.regs.(7) in
  let env = if t.env_attack then t.env_step else 15 - t.env_step in
  let sum = ref 0. in
  for c = 0 to 2 do
    let tone_ok = t.out.(c) || mixer land (1 lsl c) <> 0 in
    let noise_ok = t.noise_out || mixer land (8 lsl c) <> 0 in
    if tone_ok && noise_ok then begin
      let a = t.regs.(8 + c) in
      sum := !sum +. levels.(if a land 0x10 <> 0 then env else a land 15)
    end
  done;
  !sum

let add16 b v =
  let v = max (-32768) (min 32767 v) land 0xFFFF in
  Buffer.add_char b (Char.unsafe_chr (v land 0xFF));
  Buffer.add_char b (Char.unsafe_chr (v lsr 8))

let samples t ~frame_tstates =
  if not t.on then "" else begin
    Buffer.clear t.buf;
    let writes = ref (List.rev t.writes) in
    t.writes <- [];
    let total = float frame_tstates *. t.ticks_per_t +. t.tick_carry in
    let acc = ref t.carry_sum and filled = ref t.carry in
    let n = int_of_float total in
    t.tick_carry <- total -. float n;
    for i = 0 to n - 1 do
      (* the writes due by this tick *)
      let rec due () =
        match !writes with
        | (ts, r, v) :: rest when float ts *. t.ticks_per_t <= float i ->
          apply t r v; writes := rest; due ()
        | _ -> () in
      due ();
      acc := !acc +. tick t;
      filled := !filled +. 1.;
      if !filled >= t.ticks_per_sample then begin
        let mean = !acc /. !filled in
        t.dc <- t.dc +. (mean -. t.dc) *. 0.005;
        let v = int_of_float ((mean -. t.dc) *. 9000.) in
        add16 t.buf v; add16 t.buf v;
        (* the tick's part past the sample: the next one's start (a
           sample is 10.15 ticks: dropping it would lose one in twelve) *)
        filled := !filled -. t.ticks_per_sample;
        acc := mean *. !filled
      end
    done;
    List.iter (fun (_, r, v) -> apply t r v) !writes;
    t.carry <- !filled; t.carry_sum <- !acc;
    Buffer.contents t.buf
  end
