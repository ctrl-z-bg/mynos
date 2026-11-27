(* An MSX1 (msx.mli).

   Memory: eight blocks of 8 KB, each the slot its page (16 KB) has
   selected (the PPI's port A, 0xA8: two bits a page). For speed the bus
   keeps, for each block, the bytes it reads from and an offset, and
   what a write does there (nothing, the RAM, the cartridge's mapper);
   they are worked out again when port A or a MegaROM's bank changes.

   Ports (the low 8 bits): 0x98-0x99 the VDP; 0xA0 the PSG's register,
   0xA1 a write, 0xA2 a read; 0xA8 port A (the slots), 0xA9 port B (the
   keyboard's row), 0xAA port C (bits 0-3 the row; the cassette, the
   CAPS lamp, the click: not emulated), 0xAB the PPI's control (a bit of
   port C set or cleared). The PSG's port A: the joysticks (none held),
   bit 6 the international keyboard. *)

let frame_t = 59736
let cpu_clock = 3579545

type stop =
  | Frame_done
  | Breakpoint of int
  | Watch of int * int

type t = {
  bios : Bytes.t;                       (* slot 0: 32 KB, then C-BIOS's logo, 16 *)
  has_logo : bool;
  ram : Bytes.t;                        (* slot 3 *)
  empty : Bytes.t;                      (* 8 KB of 0xFF *)
  mutable cart : Cartridge.t option;
  mutable cart_name : string;
  mutable cart_digest : string;
  rbuf : Bytes.t array;
  roff : int array;
  wmode : int array;                    (* 0 nothing, 1 RAM, 2 the cartridge *)
  mutable pslot : int;
  mutable port_c : int;
  vdp : Vdp.t;
  psg : Ay8910.t;
  z : Z80.t;
  mutable direct : Z80.bus;
  kb : Msx_keys.t;
  kq : Msx_keys.t;
  keys_queue : (Msx_keys.key list * int) Queue.t;
  mutable key_now : (Msx_keys.key list * int) option;
  mutable key_gap : int;
  mutable ft : int;
  mutable frame : int;
  mutable watch_hit : int;
}

let remap t =
  for i = 0 to 7 do
    let slot = (t.pslot lsr ((i lsr 1) * 2)) land 3 in
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
      | 3 -> t.ram, i * 0x2000, 1
      | _ -> t.empty, 0, 0 in
    t.rbuf.(i) <- buf; t.roff.(i) <- off; t.wmode.(i) <- w
  done

let make_bus t =
  let rd a =
    let i = a lsr 13 in
    Char.code (Bytes.unsafe_get (Array.unsafe_get t.rbuf i) (Array.unsafe_get t.roff i + (a land 0x1FFF))) in
  let wr a v =
    let i = a lsr 13 in
    match Array.unsafe_get t.wmode i with
    | 1 -> Bytes.unsafe_set t.ram a (Char.unsafe_chr v)
    | 2 -> (match t.cart with Some c -> if Cartridge.write c a v then remap t | None -> ())
    | _ -> () in
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
    | _ -> 0xFF in
  let output port v =
    match port land 0xFF with
    | 0x98 -> Vdp.write_data t.vdp v
    | 0x99 -> Vdp.write_ctrl t.vdp v
    | 0xA0 -> Ay8910.select t.psg v
    | 0xA1 -> Ay8910.write t.psg ~tstate:t.ft v
    | 0xA8 -> t.pslot <- v; remap t
    | 0xAA -> t.port_c <- v
    | 0xAB ->
      if v land 0x80 = 0 then begin
        let bit = 1 lsl ((v lsr 1) land 7) in
        t.port_c <- (if v land 1 <> 0 then t.port_c lor bit else t.port_c land lnot bit)
      end
    | _ -> () in
  Z80.{ fetch = rd; read = rd; write = wr; input; output }

let dummy_bus = Z80.{ fetch = (fun _ -> 0xFF); read = (fun _ -> 0xFF); write = (fun _ _ -> ());
                      input = (fun _ -> 0xFF); output = (fun _ _ -> ()) }

let create ~bios ?logo () =
  if String.length bios <> 0x8000 then invalid_arg "Msx: an MSX1's BIOS is 32 KB";
  let b = Bytes.make 0xC000 '\xFF' in
  Bytes.blit_string bios 0 b 0 0x8000;
  (match logo with
   | Some l ->
     if String.length l <> 0x4000 then invalid_arg "Msx: C-BIOS's logo is 16 KB";
     Bytes.blit_string l 0 b 0x8000 0x4000
   | None -> ());
  let psg = Ay8910.create ~clock:(cpu_clock / 2) ~cpu_clock in
  (* the joysticks: nothing held (bits 0-5), the international layout (6) *)
  Ay8910.set_port_in psg (fun p -> if p = 0 then 0x7F else 0xFF);
  let t = { bios = b; has_logo = logo <> None; ram = Bytes.make 0x10000 '\000';
            empty = Bytes.make 0x2000 '\xFF'; cart = None; cart_name = ""; cart_digest = "";
            rbuf = Array.make 8 (Bytes.create 0); roff = Array.make 8 0; wmode = Array.make 8 0;
            pslot = 0; port_c = 0; vdp = Vdp.create (); psg; z = Z80.create dummy_bus;
            direct = dummy_bus; kb = Msx_keys.create (); kq = Msx_keys.create ();
            keys_queue = Queue.create (); key_now = None; key_gap = 0; ft = 0; frame = 0;
            watch_hit = -1 } in
  t.direct <- make_bus t;
  Z80.set_bus t.z t.direct;
  remap t;
  Ay8910.reset psg;
  t

let reset t =
  Bytes.fill t.ram 0 0x10000 '\000';
  t.pslot <- 0; t.port_c <- 0;
  Option.iter Cartridge.reset t.cart;
  remap t;
  Vdp.reset t.vdp;
  Ay8910.reset t.psg;
  Z80.reset t.z;
  t.ft <- 0;
  Queue.clear t.keys_queue; t.key_now <- None; t.key_gap <- 0;
  Msx_keys.clear t.kq

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

(* the frame's end: the VDP's vertical blanking (its interrupt), the
   next frame begun *)
let end_frame t =
  t.ft <- t.ft - frame_t;
  t.frame <- t.frame + 1;
  Vdp.frame_end t.vdp;
  keys_frame t

(* one instruction, or the VDP's interrupt taken (while its line is held):
   the handler's first instruction is the next step, so that a
   breakpoint on 0x0038 sees it *)
let one t =
  let z = t.z in
  let n = if Vdp.irq t.vdp then Z80.interrupt z 0xFF else 0 in
  t.ft <- t.ft + (if n > 0 then n else Z80.step z)

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

let rom_size t = if t.has_logo then 0xC000 else 0x8000

let peek t space a =
  match space with
  | Emu_proto.Cpu -> t.direct.Z80.read (a land 0xFFFF)
  | Emu_proto.Ram -> if a < 0 || a > 0xFFFF then failwith "ram: 0 to 0xFFFF" else Char.code (Bytes.get t.ram a)
  | Emu_proto.Vram -> if a < 0 || a > 0x3FFF then failwith "vram: 0 to 0x3FFF" else Char.code (Bytes.get (Vdp.vram t.vdp) a)
  | Emu_proto.Rom ->
    if a < 0 || a >= rom_size t then failwith (Printf.sprintf "rom: 0 to 0x%X" (rom_size t - 1))
    else Char.code (Bytes.get t.bios a)

let poke t space a v =
  let v = v land 0xFF in
  match space with
  | Emu_proto.Cpu -> t.direct.Z80.write (a land 0xFFFF) v
  | Emu_proto.Ram -> if a < 0 || a > 0xFFFF then failwith "ram: 0 to 0xFFFF" else Bytes.set t.ram a (Char.chr v)
  | Emu_proto.Vram -> if a < 0 || a > 0x3FFF then failwith "vram: 0 to 0x3FFF" else Bytes.set (Vdp.vram t.vdp) a (Char.chr v)
  | Emu_proto.Rom -> failwith "the rom is read only"

let screen t = Vdp.pixels t.vdp
let changed t = Vdp.changed t.vdp

let screen_text t =
  let cols = match Vdp.mode t.vdp with
    | Vdp.Text -> 40
    | Vdp.Graphics1 -> 32
    | Vdp.Graphics2 -> failwith "Graphics II (SCREEN 2): no characters to read; use screenshot"
    | Vdp.Multicolor -> failwith "multicolor (SCREEN 3): no characters to read; use screenshot" in
  let v = Vdp.vram t.vdp and nt = Vdp.name_table t.vdp in
  let b = Buffer.create (41 * 24) in
  for row = 0 to 23 do
    for col = 0 to cols - 1 do
      let c = Char.code (Bytes.get v ((nt + row * cols + col) land 0x3FFF)) in
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

(* a state: a line naming it, then the cartridge's digest (16 bytes, or
   zeros), the CPU's registers (2 bytes each, [regs]' order), T-states
   into the frame (4), port A, port C, the PSG's latch and registers
   (17), the banks (4), the RAM, the VDP's state *)
let magic = "MyNOS MSX1 state 1\n"
let regs = Z80.[ AF; BC; DE; HL; AF'; BC'; DE'; HL'; IX; IY; SP; PC; I; R; IM; IFF1; IFF2; MEMPTR ]

let save_state t file =
  if ext file <> ".state" then failwith "a state is a .state";
  let b = Buffer.create 0x15000 in
  Buffer.add_string b magic;
  Buffer.add_string b (if t.cart_digest = "" then String.make 16 '\000' else t.cart_digest);
  let add16 v = Buffer.add_char b (Char.chr (v land 0xFF)); Buffer.add_char b (Char.chr ((v lsr 8) land 0xFF)) in
  List.iter (fun r -> add16 (Z80.get t.z r)) regs;
  add16 t.ft; add16 (t.ft lsr 16);
  Buffer.add_char b (Char.chr t.pslot);
  Buffer.add_char b (Char.chr (t.port_c land 0xFF));
  Buffer.add_char b (Char.chr 0);
  Array.iter (fun v -> Buffer.add_char b (Char.chr v)) (Ay8910.registers t.psg);
  let banks = match t.cart with Some c -> Cartridge.banks c | None -> [| 0; 0; 0; 0 |] in
  Array.iter (fun v -> Buffer.add_char b (Char.chr (v land 0xFF))) banks;
  Buffer.add_bytes b t.ram;
  Buffer.add_string b (Vdp.save t.vdp);
  let oc = open_out_bin file in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> Buffer.output_buffer oc b)

let load_state t s =
  let m = String.length magic in
  let regs_at = m + 16 in
  let after_regs = regs_at + 2 * List.length regs in
  let ram_at = after_regs + 4 + 2 + 1 + 16 + 4 in
  if String.length s <> ram_at + 0x10000 + Vdp.state_size || String.sub s 0 m <> magic then
    failwith "not a state of this MSX";
  let digest = String.sub s m 16 in
  if digest <> (if t.cart_digest = "" then String.make 16 '\000' else t.cart_digest) then
    failwith "a state of another cartridge: load that cartridge first";
  let w i = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8) in
  List.iteri (fun k r -> Z80.set t.z r (w (regs_at + 2 * k))) regs;
  t.ft <- w after_regs lor (w (after_regs + 2) lsl 16);
  t.pslot <- Char.code s.[after_regs + 4];
  t.port_c <- Char.code s.[after_regs + 5];
  Ay8910.set_registers t.psg (Array.init 16 (fun i -> Char.code s.[after_regs + 7 + i]));
  (match t.cart with
   | Some c -> Cartridge.set_banks c (Array.init 4 (fun i -> Char.code s.[after_regs + 23 + i]))
   | None -> ());
  Bytes.blit_string s ram_at t.ram 0 0x10000;
  Vdp.restore t.vdp (String.sub s (ram_at + 0x10000) Vdp.state_size);
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
