(* zexdoc and zexall (Frank D. Cringle's Z80 exercisers, GPL), CP/M
   programs, on packages/retro/z80.ml: the program at 0x100, a trap on
   BDOS (0x0005: C = 2 prints E, C = 9 the string at DE up to '$'), the
   top of memory at 0x0006, the end at a jump to 0x0000. Prints what the
   program prints, then the T-states and the time taken.

     cpm zexdoc.com     (exit status 0 if it printed no "ERROR") *)

let () =
  let file = Sys.argv.(1) in
  let ic = open_in_bin file in
  let prog = really_input_string ic (in_channel_length ic) in
  close_in ic;
  let mem = Bytes.make 0x10000 '\000' in
  Bytes.blit_string prog 0 mem 0x100 (String.length prog);
  Bytes.set mem 5 '\xC9';                        (* RET: BDOS answered by the trap *)
  Bytes.set mem 6 '\x00'; Bytes.set mem 7 '\xF0';    (* the top of memory: 0xF000 *)
  let peek a = Char.code (Bytes.unsafe_get mem a) in
  let bus = Z80.{ fetch = peek; read = peek;
                  write = (fun a v -> Bytes.unsafe_set mem a (Char.unsafe_chr v));
                  input = (fun _ -> 0xFF); output = (fun _ _ -> ()) } in
  let z = Z80.create bus in
  Z80.set z Z80.PC 0x100;
  Z80.set z Z80.SP 0xF000;
  let out = Buffer.create 4096 in
  let print c = print_char c; flush stdout; Buffer.add_char out c in
  let t0 = Unix.gettimeofday () in
  let total = ref 0. in
  let running = ref true in
  while !running do
    let pc = Z80.get z Z80.PC in
    if pc = 0 then running := false
    else begin
      if pc = 5 then begin
        match Z80.get z Z80.C with
        | 2 -> print (Char.chr (Z80.get z Z80.E))
        | 9 ->
          let rec go a = let c = peek a in if c <> Char.code '$' then (print (Char.chr c); go ((a + 1) land 0xFFFF)) in
          go (Z80.get z Z80.DE)
        | _ -> ()
      end;
      let n = Z80.step z in
      total := !total +. float n;
      if Z80.tstates z > 1_000_000_000 then Z80.set_tstates z 0
    end
  done;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "\ncpm: %s: %.0f T-states in %.0f s (%.1f MHz)\n" file !total dt
    (!total /. dt /. 1e6);
  let s = Buffer.contents out in
  let has sub = let n = String.length sub in
    let rec f i = i + n <= String.length s && (String.sub s i n = sub || f (i + 1)) in f 0 in
  exit (if has "ERROR" then 1 else 0)
