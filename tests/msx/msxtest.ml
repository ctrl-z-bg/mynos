(* The MSX's modules on the host (tests/msx/run.sh), without MyNOS: the
   VDP through its ports, the cartridges' mappers on made-up MegaROMs,
   the PSG's pitch, C-BIOS started without a cartridge (its message read
   from the screen), Westen House started (Graphics II, sprites), a state
   saved and loaded. A line per check, "msx: ... ok". *)

let read f = let ic = open_in_bin f in let s = really_input_string ic (in_channel_length ic) in close_in ic; s
let all = ref true
let ok n b = Printf.printf "msx: %-56s %s\n%!" n (if b then "ok" else "FAIL"); if not b then all := false

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0

(* a MegaROM of [banks] banks of 8 KB, "AB" at its start, bank i's first
   byte i, and [writes] LD (nnnn),A in its code: their addresses *)
let megarom banks writes =
  let b = Bytes.make (banks * 0x2000) '\000' in
  Bytes.blit_string "AB\x10\x40" 0 b 0 4;
  List.iteri (fun i a ->
      Bytes.set b (16 + 3 * i) '\x32';
      Bytes.set b (17 + 3 * i) (Char.chr (a land 0xFF));
      Bytes.set b (18 + 3 * i) (Char.chr (a lsr 8))) writes;
  for i = 1 to banks - 1 do Bytes.set b (i * 0x2000) (Char.chr i) done;
  Bytes.to_string b

let first c i = match Cartridge.block c i with Some (b, o) -> Char.code (Bytes.get b o) | None -> -1

let () =
  let dir = Sys.argv.(1) in
  (* the VDP *)
  let v = Vdp.create () in
  Vdp.write_ctrl v 0x00; Vdp.write_ctrl v (0x40 lor 0x18);      (* write at 0x1800 *)
  List.iter (Vdp.write_data v) [ 1; 2; 3 ];
  Vdp.write_ctrl v 0x00; Vdp.write_ctrl v 0x18;               (* read from 0x1800 *)
  let r = List.init 3 (fun _ -> Vdp.read_data v) in
  ok "vdp: three bytes written at 0x1800, read back" (r = [ 1; 2; 3 ]);
  Vdp.write_ctrl v 0xF4; Vdp.write_ctrl v 0x87;               (* register 7 *)
  ok "vdp: register 7 written" (Vdp.register v 7 = 0xF4);
  Vdp.write_ctrl v 0x20; Vdp.write_ctrl v 0x81;               (* interrupts on *)
  Vdp.frame_end v;
  ok "vdp: the frame's end, the interrupt" (Vdp.irq v);
  ok "vdp: status read: F, then cleared" (Vdp.read_status v land 0x80 <> 0 && not (Vdp.irq v));
  (* the mappers *)
  let c = Cartridge.of_string (megarom 16 [ 0x6000; 0x6800; 0x7000; 0x7800 ]) in
  ok ("ascii8 guessed: " ^ Cartridge.describe c) (Cartridge.kind c = Cartridge.Ascii8);
  ignore (Cartridge.write c 0x7000 5);
  ok "ascii8: bank 5 at 0x8000" (first c 4 = 5);
  let c = Cartridge.of_string (megarom 16 [ 0x5000; 0x7000; 0x9000; 0xB000 ]) in
  ok ("konami scc guessed: " ^ Cartridge.describe c) (Cartridge.kind c = Cartridge.Konami_scc);
  ignore (Cartridge.write c 0x9000 7);
  ok "konami scc: bank 7 at 0x8000, 3 at 0xA000" (first c 4 = 7 && first c 5 = 3);
  let c = Cartridge.of_string (megarom 16 [ 0x6000; 0x7000; 0x77FF; 0x77FF ]) in
  ok ("ascii16 guessed: " ^ Cartridge.describe c) (Cartridge.kind c = Cartridge.Ascii16);
  ignore (Cartridge.write c 0x7000 3);
  ok "ascii16: bank 3 (16 KB) at 0x8000" (first c 4 = 6 && first c 5 = 7);
  let c = Cartridge.of_string (megarom 16 [ 0x8000; 0xA000; 0x8000 ]) in
  ok ("konami guessed: " ^ Cartridge.describe c) (Cartridge.kind c = Cartridge.Konami);
  ignore (Cartridge.write c 0x4000 9);
  ok "konami: 0x4000 fixed, a write there changes nothing" (first c 2 = Char.code 'A');
  (* the PSG: register 0 at 254, a square of 1789772 / (16 x 254) *)
  let a = Ay8910.create ~clock:1789772 ~cpu_clock:3579545 in
  Ay8910.reset a; Ay8910.set_on a true;
  let w r x = Ay8910.select a r; Ay8910.write a ~tstate:0 x in
  w 0 254; w 1 0; w 7 0b111110; w 8 15;
  let b = Buffer.create 200000 in
  for _ = 1 to 120 do Buffer.add_string b (Ay8910.samples a ~frame_tstates:59736) done;
  let s = Buffer.contents b in
  let n = String.length s / 4 in
  let sample i = let x = Char.code s.[4 * i] lor (Char.code s.[4 * i + 1] lsl 8) in
    if x >= 32768 then x - 65536 else x in
  let cross = ref 0 in
  for i = 1 to n - 1 do if sample (i - 1) < 0 && sample i >= 0 then incr cross done;
  let hz = float !cross /. (float n /. 22050.) in
  ok (Printf.sprintf "psg: 120 frames, %d samples, %.1f Hz (440.4)" n hz)
    (abs (n - 44156) < 3 && abs_float (hz -. 440.4) < 2.);
  (* C-BIOS without a cartridge *)
  let bios = read (Filename.concat dir "third_party/cbios/cbios_main_msx1.rom")
  and logo = read (Filename.concat dir "third_party/cbios/cbios_logo_msx1.rom") in
  let m = Msx.create ~bios ~logo () in
  for _ = 1 to 300 do ignore (Msx.run_fast m) done;
  ok "c-bios, no cartridge: \"No cartridge found.\" on the screen"
    (contains (Msx.screen_text m) "No cartridge found.");
  (* Westen House *)
  let m = Msx.create ~bios ~logo () in
  let what = Msx.load m (Filename.concat dir "third_party/westen/westen.rom") in
  ok ("westen: " ^ what) (what = "cartridge westen.rom, 48 KB at 0x0000");
  let t0 = Sys.time () in
  for _ = 1 to 1500 do ignore (Msx.run_fast m) done;
  let dt = Sys.time () -. t0 in
  ok "westen, 1500 frames: Graphics II, sprites on"
    ((match Msx.screen_text m with _ -> false | exception Failure _ -> true)
     && List.exists (fun a -> Msx.peek m Emu_proto.Vram a <> 0) (List.init 128 (fun i -> 0x1B00 + i)));
  Printf.printf "msx: (%.0f frames a second, bytecode)\n" (1500. /. dt);
  let png = Filename.concat (Sys.getcwd ()) "westen.png" in
  Png.save png ~width:Vdp.width ~height:Vdp.height (Msx.screen m);
  (* a state *)
  let st = Filename.concat (Sys.getcwd ()) "westen.state" in
  Msx.save_state m st;
  let ram () = List.init 0x10000 (Msx.peek m Emu_proto.Ram)
  and vram () = List.init 0x4000 (Msx.peek m Emu_proto.Vram) in
  let r0 = ram () and v0 = vram () and pc0 = Z80.get (Msx.z80 m) Z80.PC in
  for _ = 1 to 60 do ignore (Msx.run_fast m) done;
  ignore (Msx.load m st);
  ok "state saved, 60 frames, loaded: RAM, VRAM, PC back"
    (ram () = r0 && vram () = v0 && Z80.get (Msx.z80 m) Z80.PC = pc0);
  print_endline (if !all then "msx: all checks passed" else "msx: some checks FAILED");
  exit (if !all then 0 else 1)
