(* Apu: the Game Boy's sound (DMG), written for MyNOS (not CAMLBOY's:
   see MYNOS.md). Two square channels (the first with a frequency sweep),
   a wave channel playing 32 samples of 4 bits, a noise channel (a
   linear feedback shift register); a frame sequencer at 512 Hz clocks
   the lengths, the sweep and the volume envelopes. The registers are
   0xFF10-0xFF26, the wave's samples 0xFF30-0xFF3F.

   The channels advance by whole samples (22050 a second, 4194304 / 22050
   cycles each): what a register write changes takes effect at most one
   sample (45 us) late. The output is stereo 16-bit little-endian
   samples, taken by the program that plays them. Disabled, [run] does
   nothing but count, and the registers still read and write. *)

open Uints

let clock = 4194304
let rate = 22050

type square = {
  mutable on : bool;
  mutable dac : bool;
  mutable duty : int;
  mutable pos : int;
  mutable timer : int;
  mutable freq : int;
  mutable length : int;
  mutable length_on : bool;
  mutable vol : int;
  mutable env_init : int;
  mutable env_up : bool;
  mutable env_period : int;
  mutable env_timer : int;
  (* the sweep (channel 1 only) *)
  mutable sw_period : int;
  mutable sw_neg : bool;
  mutable sw_shift : int;
  mutable sw_timer : int;
  mutable sw_on : bool;
  mutable shadow : int;
}

type wave = {
  mutable w_on : bool;
  mutable w_dac : bool;
  mutable w_freq : int;
  mutable w_timer : int;
  mutable w_pos : int;
  mutable w_length : int;
  mutable w_length_on : bool;
  mutable w_vol : int;               (* 0 mute, 1 full, 2 half, 3 a quarter *)
}

type noise = {
  mutable n_on : bool;
  mutable n_dac : bool;
  mutable n_length : int;
  mutable n_length_on : bool;
  mutable n_vol : int;
  mutable n_env_init : int;
  mutable n_env_up : bool;
  mutable n_env_period : int;
  mutable n_env_timer : int;
  mutable n_shift : int;
  mutable n_width7 : bool;
  mutable n_div : int;
  mutable n_timer : int;
  mutable lfsr : int;
}

type t = {
  regs : int array;                  (* 0xFF10-0xFF3F as written *)
  sq1 : square;
  sq2 : square;
  wave : wave;
  noise : noise;
  mutable power : bool;
  mutable fs_timer : int;
  mutable fs_step : int;
  mutable pending : int;             (* cycles not yet applied to the channels *)
  mutable acc : int;                 (* cycles x rate, towards the next sample *)
  mutable enabled : bool;
  out : Buffer.t;
  mutable cap_l : float;             (* the output's capacitors: no DC *)
  mutable cap_r : float;
}

let square () = {
  on = false; dac = false; duty = 0; pos = 0; timer = 0; freq = 0; length = 0;
  length_on = false; vol = 0; env_init = 0; env_up = false; env_period = 0; env_timer = 0;
  sw_period = 0; sw_neg = false; sw_shift = 0; sw_timer = 0; sw_on = false; shadow = 0 }

let create () = {
  regs = Array.make 0x30 0;
  sq1 = square (); sq2 = square ();
  wave = { w_on = false; w_dac = false; w_freq = 0; w_timer = 0; w_pos = 0; w_length = 0;
           w_length_on = false; w_vol = 0 };
  noise = { n_on = false; n_dac = false; n_length = 0; n_length_on = false; n_vol = 0;
            n_env_init = 0; n_env_up = false; n_env_period = 0; n_env_timer = 0; n_shift = 0;
            n_width7 = false; n_div = 0; n_timer = 0; lfsr = 0x7FFF };
  power = true; fs_timer = 8192; fs_step = 0; pending = 0; acc = 0; enabled = false;
  out = Buffer.create 8192; cap_l = 0.; cap_r = 0. }

(* the Game Boy's high-pass filter, a capacitor charging at 0.999958 a
   clock: at 22050 samples a second, 0.999958 ** 190.2 *)
let charge = 0.999958 ** (float clock /. float rate)

let accepts _ addr = let a = Uint16.to_int addr in a >= 0xFF10 && a <= 0xFF3F

(* ---- the channels' parts ---- *)

let duty_table = [| 0b00000001; 0b10000001; 0b10000111; 0b01111110 |]

let square_period s = (2048 - s.freq) * 4
let wave_period w = (2048 - w.w_freq) * 2
let noise_period n = (if n.n_div = 0 then 8 else n.n_div * 16) lsl n.n_shift

let sweep_calc s =
  let d = s.shadow lsr s.sw_shift in
  let f = if s.sw_neg then s.shadow - d else s.shadow + d in
  if f > 2047 then s.on <- false;
  f

let clock_length_sq s =
  if s.length_on && s.length > 0 then begin
    s.length <- s.length - 1;
    if s.length = 0 then s.on <- false
  end

let clock_envelope_sq s =
  if s.env_period > 0 then begin
    s.env_timer <- s.env_timer - 1;
    if s.env_timer <= 0 then begin
      s.env_timer <- s.env_period;
      if s.env_up && s.vol < 15 then s.vol <- s.vol + 1
      else if (not s.env_up) && s.vol > 0 then s.vol <- s.vol - 1
    end
  end

let clock_sweep t =
  let s = t.sq1 in
  s.sw_timer <- s.sw_timer - 1;
  if s.sw_timer <= 0 then begin
    s.sw_timer <- (if s.sw_period > 0 then s.sw_period else 8);
    if s.sw_on && s.sw_period > 0 then begin
      let f = sweep_calc s in
      if f <= 2047 && s.sw_shift > 0 then begin
        s.shadow <- f; s.freq <- f;
        ignore (sweep_calc s)
      end
    end
  end

let frame_step t =
  let st = t.fs_step in
  if st land 1 = 0 then begin
    clock_length_sq t.sq1; clock_length_sq t.sq2;
    let w = t.wave in
    if w.w_length_on && w.w_length > 0 then begin
      w.w_length <- w.w_length - 1; if w.w_length = 0 then w.w_on <- false
    end;
    let n = t.noise in
    if n.n_length_on && n.n_length > 0 then begin
      n.n_length <- n.n_length - 1; if n.n_length = 0 then n.n_on <- false
    end
  end;
  if st = 2 || st = 6 then clock_sweep t;
  if st = 7 then begin
    clock_envelope_sq t.sq1; clock_envelope_sq t.sq2;
    let n = t.noise in
    if n.n_env_period > 0 then begin
      n.n_env_timer <- n.n_env_timer - 1;
      if n.n_env_timer <= 0 then begin
        n.n_env_timer <- n.n_env_period;
        if n.n_env_up && n.n_vol < 15 then n.n_vol <- n.n_vol + 1
        else if (not n.n_env_up) && n.n_vol > 0 then n.n_vol <- n.n_vol - 1
      end
    end
  end;
  t.fs_step <- (st + 1) land 7

(* [cycles] go by: the frame sequencer, and each channel's position *)
let advance t cycles =
  if cycles > 0 && t.power then begin
    t.fs_timer <- t.fs_timer - cycles;
    while t.fs_timer <= 0 do t.fs_timer <- t.fs_timer + 8192; frame_step t done;
    let sq s =
      if s.on then begin
        s.timer <- s.timer - cycles;
        if s.timer <= 0 then begin
          let p = square_period s in
          let k = (- s.timer) / p + 1 in
          s.timer <- s.timer + k * p;
          s.pos <- (s.pos + k) land 7
        end
      end in
    sq t.sq1; sq t.sq2;
    let w = t.wave in
    if w.w_on then begin
      w.w_timer <- w.w_timer - cycles;
      if w.w_timer <= 0 then begin
        let p = wave_period w in
        let k = (- w.w_timer) / p + 1 in
        w.w_timer <- w.w_timer + k * p;
        w.w_pos <- (w.w_pos + k) land 31
      end
    end;
    let n = t.noise in
    if n.n_on && n.n_shift < 14 then begin
      n.n_timer <- n.n_timer - cycles;
      if n.n_timer <= 0 then begin
        let p = noise_period n in
        let k = (- n.n_timer) / p + 1 in
        n.n_timer <- n.n_timer + k * p;
        for _ = 1 to min k 64 do
          let x = (n.lfsr lxor (n.lfsr lsr 1)) land 1 in
          n.lfsr <- (n.lfsr lsr 1) lor (x lsl 14);
          if n.n_width7 then n.lfsr <- (n.lfsr land (lnot 0x40)) lor (x lsl 6)
        done
      end
    end
  end

let catch_up t = advance t t.pending; t.pending <- 0

(* ---- the output ---- *)

let sample t =
  let nr50 = t.regs.(0x14) and nr51 = t.regs.(0x15) in
  (* each channel's DAC: 0..15 to -15..15; a channel off adds nothing *)
  let analog on d = if on then 2 * d - 15 else 0 in
  (* a square above 11025 Hz (131072 / (2048 - freq)), which games use to
     be silent, would alias into a whistle: its average instead, as an
     ear hears the real one *)
  let duty_avg = [| 1; 2; 4; 6 |] in
  let sq s =
    if not s.on then 0
    else if 2048 - s.freq < 12 then duty_avg.(s.duty) * s.vol / 8
    else (duty_table.(s.duty) lsr (7 - s.pos)) land 1 * s.vol in
  let s1 = sq t.sq1 and s2 = sq t.sq2 in
  let w = t.wave in
  let s3 =
    if w.w_on && w.w_vol > 0 then begin
      let b = t.regs.(0x20 + w.w_pos / 2) in
      let nib = if w.w_pos land 1 = 0 then b lsr 4 else b land 15 in
      nib lsr (w.w_vol - 1)
    end else 0 in
  let s4 = if t.noise.n_on then ((lnot t.noise.lfsr) land 1) * t.noise.n_vol else 0 in
  let ch = [| analog (t.sq1.on && t.sq1.dac) s1; analog (t.sq2.on && t.sq2.dac) s2;
              analog (w.w_on && w.w_dac) s3; analog (t.noise.n_on && t.noise.n_dac) s4 |] in
  let mix bits = let v = ref 0 in
    for i = 0 to 3 do if (nr51 lsr (i + bits)) land 1 = 1 then v := !v + ch.(i) done; !v in
  let l = if t.power then float (mix 4 * (((nr50 lsr 4) land 7) + 1) * 60) else 0. in
  let r = if t.power then float (mix 0 * ((nr50 land 7) + 1) * 60) else 0. in
  let hp x cap = let y = x -. cap in (y, x -. y *. charge) in
  let l, cl = hp l t.cap_l and r, cr = hp r t.cap_r in
  t.cap_l <- cl; t.cap_r <- cr;
  let clamp v = max (-32768) (min 32767 (truncate v)) in
  Buffer.add_int16_le t.out (clamp l);
  Buffer.add_int16_le t.out (clamp r)

let run t ~mcycles =
  if t.enabled then begin
    let cycles = mcycles * 4 in
    t.pending <- t.pending + cycles;
    t.acc <- t.acc + cycles * rate;
    while t.acc >= clock do
      t.acc <- t.acc - clock;
      catch_up t;
      sample t
    done
  end

let take_samples t = let s = Buffer.contents t.out in Buffer.clear t.out; s

let set_enabled t b =
  t.enabled <- b;
  if not b then begin Buffer.clear t.out; t.pending <- 0 end

(* ---- the registers ---- *)

let masks = [|
  0x80; 0x3F; 0x00; 0xFF; 0xBF;            (* NR10-NR14 *)
  0xFF; 0x3F; 0x00; 0xFF; 0xBF;            (* -, NR21-NR24 *)
  0x7F; 0xFF; 0x9F; 0xFF; 0xBF;            (* NR30-NR34 *)
  0xFF; 0xFF; 0x00; 0x00; 0xBF;            (* -, NR41-NR44 *)
  0x00; 0x00; 0x70;                        (* NR50, NR51, NR52 *)
  0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF; 0xFF |]

let read_byte t addr =
  let a = Uint16.to_int addr - 0xFF10 in
  let v =
    if a >= 0x20 then t.regs.(a)
    else if a = 0x16 then
      (if t.power then 0x80 else 0) lor 0x70
      lor (if t.sq1.on then 1 else 0) lor (if t.sq2.on then 2 else 0)
      lor (if t.wave.w_on then 4 else 0) lor (if t.noise.n_on then 8 else 0)
    else t.regs.(a) lor masks.(a) in
  Uint8.of_int (v land 0xFF)

let trigger_square t s ~first =
  s.on <- s.dac;
  if s.length = 0 then s.length <- 64;
  s.timer <- square_period s;
  s.vol <- s.env_init; s.env_timer <- s.env_period;
  if first then begin
    s.shadow <- s.freq;
    s.sw_timer <- (if s.sw_period > 0 then s.sw_period else 8);
    s.sw_on <- s.sw_period > 0 || s.sw_shift > 0;
    if s.sw_shift > 0 then ignore (sweep_calc s)
  end;
  ignore t

let write_square t s base a v =
  match a - base with
  | 0 -> s.sw_period <- (v lsr 4) land 7; s.sw_neg <- v land 8 <> 0; s.sw_shift <- v land 7
  | 1 -> s.duty <- v lsr 6; s.length <- 64 - (v land 63)
  | 2 ->
    s.env_init <- v lsr 4; s.env_up <- v land 8 <> 0; s.env_period <- v land 7;
    s.dac <- v land 0xF8 <> 0; if not s.dac then s.on <- false
  | 3 -> s.freq <- (s.freq land 0x700) lor v
  | 4 ->
    s.freq <- (s.freq land 0xFF) lor ((v land 7) lsl 8);
    s.length_on <- v land 0x40 <> 0;
    if v land 0x80 <> 0 then trigger_square t s ~first:(base = 0)
  | _ -> ()

let write_byte t ~addr ~data =
  let a = Uint16.to_int addr - 0xFF10 and v = Uint8.to_int data in
  catch_up t;
  if a >= 0x20 then t.regs.(a) <- v                      (* the wave's samples *)
  else if a = 0x16 then begin                            (* NR52: the power *)
    let on = v land 0x80 <> 0 in
    if t.power && not on then begin
      for i = 0 to 0x15 do t.regs.(i) <- 0 done;
      List.iter (fun s -> s.on <- false; s.dac <- false) [ t.sq1; t.sq2 ];
      t.wave.w_on <- false; t.wave.w_dac <- false; t.noise.n_on <- false; t.noise.n_dac <- false
    end else if on && not t.power then begin t.fs_step <- 0; t.fs_timer <- 8192 end;
    t.power <- on
  end
  else if t.power then begin
    t.regs.(a) <- v;
    if a <= 0x04 then write_square t t.sq1 0 a v
    else if a >= 0x05 && a <= 0x09 then write_square t t.sq2 0x05 a v
    else begin
      let w = t.wave and n = t.noise in
      match a with
      | 0x0A -> w.w_dac <- v land 0x80 <> 0; if not w.w_dac then w.w_on <- false
      | 0x0B -> w.w_length <- 256 - v
      | 0x0C -> w.w_vol <- (v lsr 5) land 3
      | 0x0D -> w.w_freq <- (w.w_freq land 0x700) lor v
      | 0x0E ->
        w.w_freq <- (w.w_freq land 0xFF) lor ((v land 7) lsl 8);
        w.w_length_on <- v land 0x40 <> 0;
        if v land 0x80 <> 0 then begin
          w.w_on <- w.w_dac;
          if w.w_length = 0 then w.w_length <- 256;
          w.w_timer <- wave_period w; w.w_pos <- 0
        end
      | 0x10 -> n.n_length <- 64 - (v land 63)
      | 0x11 ->
        n.n_env_init <- v lsr 4; n.n_env_up <- v land 8 <> 0; n.n_env_period <- v land 7;
        n.n_dac <- v land 0xF8 <> 0; if not n.n_dac then n.n_on <- false
      | 0x12 -> n.n_shift <- v lsr 4; n.n_width7 <- v land 8 <> 0; n.n_div <- v land 7
      | 0x13 ->
        n.n_length_on <- v land 0x40 <> 0;
        if v land 0x80 <> 0 then begin
          n.n_on <- n.n_dac;
          if n.n_length = 0 then n.n_length <- 64;
          n.n_timer <- noise_period n;
          n.n_vol <- n.n_env_init; n.n_env_timer <- n.n_env_period;
          n.lfsr <- 0x7FFF
        end
      | _ -> ()
    end
  end

(* the registers as the boot ROM leaves them: written without triggering *)
let after_boot t =
  List.iter (fun (a, v) -> t.regs.(a - 0xFF10) <- v)
    [ (0xFF10, 0x80); (0xFF11, 0xBF); (0xFF12, 0xF3); (0xFF14, 0xBF); (0xFF16, 0x3F);
      (0xFF19, 0xBF); (0xFF1A, 0x7F); (0xFF1B, 0xFF); (0xFF1C, 0x9F); (0xFF1E, 0xBF);
      (0xFF20, 0xFF); (0xFF23, 0xBF); (0xFF24, 0x77); (0xFF25, 0xF3) ];
  t.sq1.duty <- 2; t.sq1.env_init <- 15; t.sq1.env_period <- 3; t.sq1.dac <- true;
  t.power <- true
