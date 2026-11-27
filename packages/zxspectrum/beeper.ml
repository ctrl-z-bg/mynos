(* The beeper (beeper.mli). The CPU's clock, 3,500,000 T-states a second,
   at 22050 samples a second: 158.73 T-states a sample; a frame's share
   kept as a fraction, so that the samples come out at the right rate.
   Each sample is the speaker's mean level over its T-states (a box
   filter), then a high-pass filter (the output's capacitor), then 16
   bits. *)

let clock = 3_500_000.
let rate = 22050.
let per_sample = clock /. rate

type t = {
  mutable on : bool;
  mutable lvl : bool;                   (* now *)
  mutable changes : (int * bool) list;  (* this frame's, latest first *)
  mutable carry : float;                (* T-states of a sample begun in the last frame *)
  mutable carry_sum : float;            (* its level so far *)
  mutable prev_in : float;              (* the high-pass filter's state *)
  mutable prev_out : float;
  buf : Buffer.t;
}

let create () =
  { on = false; lvl = false; changes = []; carry = 0.; carry_sum = 0.;
    prev_in = 0.; prev_out = 0.; buf = Buffer.create 2048 }

let on t = t.on
let set_on t v = t.on <- v; t.changes <- []; t.carry <- 0.; t.carry_sum <- 0.

let level t ~tstate v =
  if t.on && v <> t.lvl then t.changes <- (tstate, v) :: t.changes;
  t.lvl <- v

let add16 b v =
  let v = max (-32768) (min 32767 v) land 0xFFFF in
  Buffer.add_char b (Char.unsafe_chr (v land 0xFF));
  Buffer.add_char b (Char.unsafe_chr (v lsr 8))

let samples t ~frame_tstates =
  if not t.on then "" else begin
    Buffer.clear t.buf;
    let changes = ref (List.rev t.changes) in
    t.changes <- [];
    (* the level at the frame's start: the opposite of the first change's
       if any, else the level now *)
    let lvl = ref (match !changes with (_, v) :: _ -> not v | [] -> t.lvl) in
    let pos = ref 0. and acc = ref t.carry_sum and filled = ref t.carry in
    let ft = float frame_tstates in
    let emit mean =
      (* high-pass: y = x - x' + 0.995 y' *)
      let y = mean -. t.prev_in +. 0.995 *. t.prev_out in
      t.prev_in <- mean; t.prev_out <- y;
      let v = int_of_float (y *. 9000.) in
      add16 t.buf v; add16 t.buf v in
    while !pos < ft do
      let next_change = match !changes with (ts, _) :: _ -> float ts | [] -> ft in
      let sample_end = !pos +. (per_sample -. !filled) in
      let upto = min ft (min next_change sample_end) in
      let span = upto -. !pos in
      if !lvl then acc := !acc +. span;
      filled := !filled +. span;
      pos := upto;
      if !filled >= per_sample -. 1e-9 then begin
        emit (!acc /. per_sample);
        acc := 0.; filled := 0.
      end;
      (match !changes with
       | (ts, v) :: r when float ts <= !pos -> lvl := v; changes := r
       | _ -> ())
    done;
    t.carry <- !filled; t.carry_sum <- !acc;
    Buffer.contents t.buf
  end
