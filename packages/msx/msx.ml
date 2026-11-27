(* An MSX1 or an MSX2 (msx.mli).

   Memory: eight blocks of 8 KB, each the slot its page (16 KB) has
   selected (the PPI's port A, 0xA8: two bits a page; on the MSX2, slot
   3 expanded: 0xFFFF, when page 3 is in slot 3, selects its secondary
   slots, and reads back their complement). For speed the bus keeps, for
   each block, the bytes it reads from and an offset, and what a write
   does there (nothing, the RAM, the cartridge's mapper); they are worked
   out again when a slot, a MegaROM's bank or the memory mapper's
   segment changes.

   Ports (the low 8 bits): 0x98-0x99 the VDP (MSX2: 0x9A the palette,
   0x9B its registers); 0xA0 the PSG's register,
   0xA1 a write, 0xA2 a read; 0xA8 port A (the slots), 0xA9 port B (the
   keyboard's row), 0xAA port C (bits 0-3 the row; the cassette, the
   CAPS lamp, the click: not emulated), 0xAB the PPI's control (a bit of
   port C set or cleared). The PSG's port A: the joysticks (none held),
   bit 6 the international keyboard. MSX2: 0xB4-0xB5 the clock, 0xFC-0xFF
   the memory mapper's segments of pages 0-3 (read back with the high
   bits set). *)

let frame_t = 59736
let line_t = 228
let cpu_clock = 3579545

type stop =
  | Frame_done
  | Breakpoint of int
  | Watch of int * int

type t = {
  msx2 : bool;
  bios : Bytes.t;                       (* slot 0: 32 KB, C-BIOS's logo (16); MSX2: the SUB-ROM at 0xC000 *)
  has_logo : bool;
  ram : Bytes.t;                        (* MSX1: slot 3's 64 KB; MSX2: the mapper's 512 KB *)
  empty : Bytes.t;                      (* 8 KB of 0xFF *)
  mutable cart : Cartridge.t option;
  mutable cart_name : string;
  mutable cart_digest : string;
  rbuf : Bytes.t array;
  roff : int array;
  wmode : int array;                    (* 0 nothing, 1 RAM (rbuf, roff), 2 the cartridge *)
  mutable pslot : int;
  mutable sslot : int;                  (* MSX2: slot 3's secondary slots (0xFFFF) *)
  mapper : int array;                   (* MSX2: the segment of each page (ports 0xFC-0xFF) *)
  mutable port_c : int;
  vdp : Vdp.t;
  psg : Ay8910.t;
  rtc : Rtc.t;
  z : Z80.t;
  mutable direct : Z80.bus;
  kb : Msx_keys.t;
  kq : Msx_keys.t;
  keys_queue : (Msx_keys.key list * int) Queue.t;
  mutable key_now : (Msx_keys.key list * int) option;
  mutable key_gap : int;
  mutable ft : int;
  mutable line : int;                   (* the frame's next line, 0-262 *)
  mutable line_at : int;                (* the T-state it begins at *)
  mutable frame : int;
  mutable watch_hit : int;
}

let segments = 32                       (* the MSX2's 512 KB, 16 KB a segment *)

(* each 8 KB block: what it reads and where, what a write does there *)
let remap t =
  for i = 0 to 7 do
    let page = i lsr 1 in
    let slot = (t.pslot lsr (page * 2)) land 3 in
    let buf, off, w =
      match slot with
      | 0 ->
        if i < 4 then t.bios, i * 0x2000, 0
        else if i < 6 && t.has_logo then t.bios, i * 0x2000, 0
        else t.empty, 0, 0
      | 1 ->
        (match t.cart with
         | Some c ->
           (match Cartridge.block c i with
            | Some (b, o) -> b, o, 2
            | None -> t.empty, 0, 2)
         | None -> t.empty, 0, 0)
      | 3 when not t.msx2 -> t.ram, i * 0x2000, 1
      | 3 ->
        (match (t.sslot lsr (page * 2)) land 3 with
         | 0 when page = 0 -> t.bios, 0xC000 + (i land 1) * 0x2000, 0      (* 3-0: the SUB-ROM *)
         | 2 -> t.ram, (t.mapper.(page) land (segments - 1)) * 0x4000 + (i land 1) * 0x2000, 1
         | _ -> t.empty, 0, 0)
      | _ -> t.empty, 0, 0 in
    t.rbuf.(i) <- buf; t.roff.(i) <- off; t.wmode.(i) <- w
  done

(* is 0xFFFF slot 3's secondary slot register now? (page 3 in slot 3) *)
let at_ffff t = t.msx2 && t.pslot lsr 6 = 3

let make_bus t =
  let rd a =
    let i = a lsr 13 in
    Char.code (Bytes.unsafe_get (Array.unsafe_get t.rbuf i) (Array.unsafe_get t.roff i + (a land 0x1FFF))) in
  let rd = if not t.msx2 then rd
    else fun a -> if a = 0xFFFF && at_ffff t then (lnot t.sslot) land 0xFF else rd a in
  let wr a v =
    let i = a lsr 13 in
    match Array.unsafe_get t.wmode i with
    | 1 ->
      if a = 0xFFFF && at_ffff t then begin t.sslot <- v; remap t end
      else Bytes.unsafe_set (Array.unsafe_get t.rbuf i) (Array.unsafe_get t.roff i + (a land 0x1FFF))
          (Char.unsafe_chr v)
    | 2 -> (match t.cart with Some c -> if Cartridge.write c a v then remap t | None -> ())
    | _ -> if a = 0xFFFF && at_ffff t then begin t.sslot <- v; remap t end in
  let input port =
    match port land 0xFF with
    | 0x98 -> Vdp.read_data t.vdp
    | 0x99 -> Vdp.read_status t.vdp
    | 0xA2 -> Ay8910.read t.psg
    | 0xA8 -> t.pslot
    | 0xA9 ->
      let row = t.port_c land 15 in
      Msx_keys.read t.kb row land Msx_keys.read t.kq row
    | 0xAA -> t.port_c
    | 0xB5 when t.msx2 -> Rtc.read t.rtc
    | p when t.msx2 && p >= 0xFC -> t.mapper.(p - 0xFC) lor (0xFF land lnot (segments - 1))
    | _ -> 0xFF in
  let output port v =
    match port land 0xFF with
    | 0x98 -> Vdp.write_data t.vdp v
    | 0x99 -> Vdp.write_ctrl t.vdp v
    | 0x9A -> Vdp.write_palette t.vdp v
    | 0x9B -> Vdp.write_indirect t.vdp v
    | 0xA0 -> Ay8910.select t.psg v
    | 0xA1 -> Ay8910.write t.psg ~tstate:t.ft v
    | 0xA8 -> t.pslot <- v; remap t
    | 0xAA -> t.port_c <- v
    | 0xAB ->
      if v land 0x80 = 0 then begin
        let bit = 1 lsl ((v lsr 1) land 7) in
        t.port_c <- (if v land 1 <> 0 then t.port_c lor bit else t.port_c land lnot bit)
      end
    | 0xB4 when t.msx2 -> Rtc.select t.rtc v
    | 0xB5 when t.msx2 -> Rtc.write t.rtc v
    | p when t.msx2 && p >= 0xFC -> t.mapper.(p - 0xFC) <- v land (segments - 1); remap t
    | _ -> () in
  Z80.{ fetch = rd; read = rd; write = wr; input; output }

let dummy_bus = Z80.{ fetch = (fun _ -> 0xFF); read = (fun _ -> 0xFF); write = (fun _ _ -> ());
                      input = (fun _ -> 0xFF); output = (fun _ _ -> ()) }

let create ?sub ?(clock = fun () -> 0.) ~bios ?logo () =
  if String.length bios <> 0x8000 then invalid_arg "Msx: a BIOS's main ROM is 32 KB";
  let msx2 = sub <> None in
  let b = Bytes.make (if msx2 then 0x10000 else 0xC000) '\xFF' in
  Bytes.blit_string bios 0 b 0 0x8000;
  (match logo with
   | Some l ->
     if String.length l <> 0x4000 then invalid_arg "Msx: C-BIOS's logo is 16 KB";
     Bytes.blit_string l 0 b 0x8000 0x4000
   | None -> ());
  (match sub with
   | Some s ->
     if String.length s <> 0x4000 then invalid_arg "Msx: an MSX2's SUB-ROM is 16 KB";
     Bytes.blit_string s 0 b 0xC000 0x4000
   | None -> ());
  let psg = Ay8910.create ~clock:(cpu_clock / 2) ~cpu_clock in
  (* the joysticks: nothing held (bits 0-5), the international layout (6) *)
  Ay8910.set_port_in psg (fun p -> if p = 0 then 0x7F else 0xFF);
  let t = { msx2; bios = b; has_logo = logo <> None;
            ram = Bytes.make (if msx2 then segments * 0x4000 else 0x10000) '\000';
            empty = Bytes.make 0x2000 '\xFF'; cart = None; cart_name = ""; cart_digest = "";
            rbuf = Array.make 8 (Bytes.create 0); roff = Array.make 8 0; wmode = Array.make 8 0;
            pslot = 0; sslot = 0; mapper = [| 3; 2; 1; 0 |]; port_c = 0;
            vdp = Vdp.create ~v9938:msx2 (); psg; rtc = Rtc.create ~clock; z = Z80.create dummy_bus;
            direct = dummy_bus; kb = Msx_keys.create (); kq = Msx_keys.create ();
            keys_queue = Queue.create (); key_now = None; key_gap = 0; ft = 0; line = 0; line_at = 0;
            frame = 0; watch_hit = -1 } in
  t.direct <- make_bus t;
  Z80.set_bus t.z t.direct;
  Vdp.set_clock t.vdp (fun () -> if t.line = 0 then 0 else t.ft - (t.line - 1) * line_t);
  remap t;
  Ay8910.reset psg;
  Rtc.reset t.rtc;
  t

let reset t =
  Bytes.fill t.ram 0 (Bytes.length t.ram) '\000';
  t.pslot <- 0; t.sslot <- 0; t.port_c <- 0;
  Array.blit [| 3; 2; 1; 0 |] 0 t.mapper 0 4;
  Option.iter Cartridge.reset t.cart;
  remap t;
  Vdp.reset t.vdp;
  Ay8910.reset t.psg;
  Rtc.reset t.rtc;
  Z80.reset t.z;
  t.ft <- 0; t.line <- 0; t.line_at <- 0;
  Queue.clear t.keys_queue; t.key_now <- None; t.key_gap <- 0;
  Msx_keys.clear t.kq

let msx2 t = t.msx2
let set_draw t b = Vdp.set_draw t.vdp b
let z80 t = t.z
let frame t = t.frame
let cartridge t = t.cart_name

(* ---- keys: emu/1's, a group at a time, by frames (as the Spectrum's) ---- *)

let press t key down = Msx_keys.set t.kb key down
let queue_keys t groups = List.iter (fun g -> Queue.push g t.keys_queue) groups
let keys_pending t = t.key_now <> None || t.key_gap > 0 || not (Queue.is_empty t.keys_queue)

let keys_frame t =
  match t.key_now with
  | Some (keys, n) ->
    if n <= 1 then begin
      List.iter (fun k -> Msx_keys.set t.kq k false) keys;
      t.key_now <- None;
      t.key_gap <-
        (match Queue.peek_opt t.keys_queue with
         | Some (next, _) when List.exists (fun k -> List.mem k keys) next -> 6
         | _ -> 1)
    end else t.key_now <- Some (keys, n - 1)
  | None ->
    if t.key_gap > 0 then t.key_gap <- t.key_gap - 1
    else if not (Queue.is_empty t.keys_queue) then begin
      let keys, n = Queue.pop t.keys_queue in
      List.iter (fun k -> Msx_keys.set t.kq k true) keys;
      t.key_now <- Some (keys, n)
    end

(* ---- running ---- *)

(* a frame is 262 lines of 228 T-states; line 0 is the picture's first
   (the VDP's interrupt comes at its end, 192 or 212) *)

(* the lines begun by now: the VDP draws them *)
let lines t =
  while t.ft >= t.line_at && t.line < 262 do
    Vdp.line t.vdp t.line;
    t.line <- t.line + 1;
    t.line_at <- t.line_at + line_t
  done

(* the frame's end, the next one begun *)
let end_frame t =
  t.ft <- t.ft - frame_t;
  t.line <- 0; t.line_at <- 0;
  t.frame <- t.frame + 1;
  keys_frame t;
  lines t

(* one instruction, or the VDP's interrupt taken (while its line is held):
   the handler's first instruction is the next step, so that a
   breakpoint on 0x0038 sees it *)
let one t =
  let z = t.z in
  let n = if Vdp.irq t.vdp then Z80.interrupt z 0xFF else 0 in
  t.ft <- t.ft + (if n > 0 then n else Z80.step z);
  if t.ft >= t.line_at then lines t

let run_fast t =
  while t.ft < frame_t do one t done;
  end_frame t;
  Frame_done

let run_checked t ~check =
  let rec go first =
    if t.ft >= frame_t then begin end_frame t; Frame_done end
    else
      let pc = Z80.get t.z Z80.PC in
      if not first && check pc then Breakpoint pc
      else begin
        t.watch_hit <- -1;
        one t;
        if t.watch_hit >= 0 then Watch (Z80.get t.z Z80.PC, t.watch_hit) else go false
      end in
  go true

let step t =
  t.watch_hit <- -1;
  one t;
  if t.watch_hit >= 0 then Watch (Z80.get t.z Z80.PC, t.watch_hit)
  else if t.ft >= frame_t then begin end_frame t; Frame_done end
  else Frame_done

let set_watch t w =
  match w with
  | None -> Z80.set_bus t.z t.direct
  | Some f ->
    let d = t.direct in
    Z80.set_bus t.z
      { d with Z80.read = (fun a -> if f a false then t.watch_hit <- a; d.Z80.read a);
               Z80.write = (fun a v -> if f a true then t.watch_hit <- a; d.Z80.write a v) }

(* ---- memory, screen, sound ---- *)

let rom_size t = if t.msx2 then 0x10000 else if t.has_logo then 0xC000 else 0x8000

let check what a size =
  if a < 0 || a >= size then failwith (Printf.sprintf "%s: 0 to 0x%X" what (size - 1))

let peek t space a =
  match space with
  | Emu_proto.Cpu -> t.direct.Z80.read (a land 0xFFFF)
  | Emu_proto.Ram -> check "ram" a (Bytes.length t.ram); Char.code (Bytes.get t.ram a)
  | Emu_proto.Vram ->
    let v = Vdp.vram t.vdp in
    check "vram" a (Bytes.length v); Char.code (Bytes.get v a)
  | Emu_proto.Rom -> check "rom" a (rom_size t); Char.code (Bytes.get t.bios a)

let poke t space a v =
  let v = v land 0xFF in
  match space with
  | Emu_proto.Cpu -> t.direct.Z80.write (a land 0xFFFF) v
  | Emu_proto.Ram -> check "ram" a (Bytes.length t.ram); Bytes.set t.ram a (Char.chr v)
  | Emu_proto.Vram ->
    let m = Vdp.vram t.vdp in
    check "vram" a (Bytes.length m); Bytes.set m a (Char.chr v)
  | Emu_proto.Rom -> failwith "the rom is read only"

let screen t = Vdp.pixels t.vdp
let changed t = Vdp.changed t.vdp

let screen_text t =
  let v = Vdp.vram t.vdp in
  let cols, nt = match Vdp.mode t.vdp with
    | Vdp.Text -> 40, Vdp.name_table t.vdp
    | Vdp.Graphics1 -> 32, Vdp.name_table t.vdp
    | Vdp.Text2 -> 80, (Vdp.register t.vdp 2 land 0x7C) lsl 10
    | Vdp.Graphics2 | Vdp.Graphics3 ->
      failwith "a mode of patterns (SCREEN 2, 4): no characters to read; use screenshot"
    | Vdp.Multicolor -> failwith "multicolor (SCREEN 3): no characters to read; use screenshot"
    | _ -> failwith "a bitmap mode (SCREEN 5-8): no characters to read; use screenshot" in
  let b = Buffer.create (81 * 24) in
  for row = 0 to 23 do
    for col = 0 to cols - 1 do
      let c = Char.code (Bytes.get v ((nt + row * cols + col) land (Bytes.length v - 1))) in
      Buffer.add_char b (if c >= 32 && c < 127 then Char.chr c else '?')
    done;
    Buffer.add_char b '\n'
  done;
  Buffer.contents b

let set_audio t on = Ay8910.set_on t.psg on
let audio_samples t = Ay8910.samples t.psg ~frame_tstates:frame_t

(* ---- files ---- *)

let read_file f =
  let ic = open_in_bin f in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let ext f = String.lowercase_ascii (Filename.extension f)

(* a state: a line naming it (the MSX1's or the MSX2's), then the
   cartridge's digest (16 bytes, or zeros), the CPU's registers (2 bytes
   each, [regs]' order), T-states into the frame (4), port A, port C,
   the PSG's latch and registers (17), the banks (4), on the MSX2 slot 3's
   secondary slots (1), the mapper's segments (4) and the clock
   ([Rtc.state_size]), the RAM, the VDP's state *)
let magic t = if t.msx2 then "MyNOS MSX2 state 1\n" else "MyNOS MSX1 state 1\n"
let regs = Z80.[ AF; BC; DE; HL; AF'; BC'; DE'; HL'; IX; IY; SP; PC; I; R; IM; IFF1; IFF2; MEMPTR ]

let save_state t file =
  if ext file <> ".state" then failwith "a state is a .state";
  let b = Buffer.create (Bytes.length t.ram + Vdp.state_size t.vdp + 256) in
  Buffer.add_string b (magic t);
  Buffer.add_string b (if t.cart_digest = "" then String.make 16 '\000' else t.cart_digest);
  let byte v = Buffer.add_char b (Char.chr (v land 0xFF)) in
  let add16 v = byte v; byte (v lsr 8) in
  List.iter (fun r -> add16 (Z80.get t.z r)) regs;
  add16 t.ft; add16 (t.ft lsr 16);
  byte t.pslot; byte t.port_c; byte 0;
  Array.iter byte (Ay8910.registers t.psg);
  Array.iter byte (match t.cart with Some c -> Cartridge.banks c | None -> [| 0; 0; 0; 0 |]);
  if t.msx2 then begin
    byte t.sslot; Array.iter byte t.mapper;
    Buffer.add_string b (Rtc.save t.rtc)
  end;
  Buffer.add_bytes b t.ram;
  Buffer.add_string b (Vdp.save t.vdp);
  let oc = open_out_bin file in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> Buffer.output_buffer oc b)

let load_state t s =
  let magic = magic t in
  let m = String.length magic in
  let regs_at = m + 16 in
  let after_regs = regs_at + 2 * List.length regs in
  let extra_at = after_regs + 4 + 2 + 1 + 16 + 4 in
  let ram_at = extra_at + (if t.msx2 then 1 + 4 + Rtc.state_size else 0) in
  let ram_size = Bytes.length t.ram in
  if String.length s <> ram_at + ram_size + Vdp.state_size t.vdp || String.sub s 0 m <> magic then
    failwith (if t.msx2 then "not a state of this MSX2" else "not a state of this MSX");
  let digest = String.sub s m 16 in
  if digest <> (if t.cart_digest = "" then String.make 16 '\000' else t.cart_digest) then
    failwith "a state of another cartridge: load that cartridge first";
  let w i = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8) in
  List.iteri (fun k r -> Z80.set t.z r (w (regs_at + 2 * k))) regs;
  t.ft <- w after_regs lor (w (after_regs + 2) lsl 16);
  (* the lines begun by then: the next one's *)
  t.line <- min 262 (t.ft / line_t + 1); t.line_at <- t.line * line_t;
  t.pslot <- Char.code s.[after_regs + 4];
  t.port_c <- Char.code s.[after_regs + 5];
  Ay8910.set_registers t.psg (Array.init 16 (fun i -> Char.code s.[after_regs + 7 + i]));
  (match t.cart with
   | Some c -> Cartridge.set_banks c (Array.init 4 (fun i -> Char.code s.[after_regs + 23 + i]))
   | None -> ());
  if t.msx2 then begin
    t.sslot <- Char.code s.[extra_at];
    for i = 0 to 3 do t.mapper.(i) <- Char.code s.[extra_at + 1 + i] done;
    Rtc.restore t.rtc (String.sub s (extra_at + 5) Rtc.state_size)
  end;
  Bytes.blit_string s ram_at t.ram 0 ram_size;
  Vdp.restore t.vdp (String.sub s (ram_at + ram_size) (Vdp.state_size t.vdp));
  remap t

let load t file =
  let data = read_file file in
  match ext file with
  | ".rom" | ".mx1" | ".mx2" ->
    let c = Cartridge.of_string data in
    t.cart <- Some c;
    t.cart_name <- Filename.basename file;
    t.cart_digest <- Digest.string data;
    reset t;
    Printf.sprintf "cartridge %s, %s" (Filename.basename file) (Cartridge.describe c)
  | ".state" ->
    load_state t data;
    Printf.sprintf "state %s" (Filename.basename file)
  | e -> failwith ("not a cartridge (.rom, .mx1, .mx2) nor a .state: " ^ e)
