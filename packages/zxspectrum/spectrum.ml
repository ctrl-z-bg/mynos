(* A ZX Spectrum 48K (spectrum.mli). Memory: 64 KB, the ROM in the first
   16 (writes there ignored). Port 0xFE (any even port): the keyboard's
   half-rows and EAR in, the border, MIC and the beeper out. Port 0x1F: a
   Kempston joystick, none held. Others read 0xFF (the floating bus is
   not followed: no game here needs it).

   A frame: 69,888 T-states; /INT for its first 32: asked again after
   each instruction while it lasts and the CPU has not taken it (EI just
   done). [ft]: the T-states into the frame. *)

let frame_t = 69888
let int_len = 32

type stop =
  | Frame_done
  | Breakpoint of int
  | Watch of int * int

type t = {
  mem : Bytes.t;
  z : Z80.t;
  direct : Z80.bus;
  ula : Ula.t;
  beeper : Beeper.t;
  kb : Keyboard.t;                      (* the window's keys *)
  kq : Keyboard.t;                      (* emu/1's, from [keys_queue] *)
  keys_queue : (Keyboard.key list * int) Queue.t;
  mutable key_now : (Keyboard.key list * int) option;   (* held, frames left *)
  mutable key_gap : int;                (* frames let go after a group *)
  mutable ft : int;
  mutable int_taken : bool;             (* this frame's interrupt *)
  mutable frame : int;
  mutable ear_out : int;                (* bit 4 last written: EAR read back *)
  mutable tape : Tape.t option;
  mutable watch_hit : int;              (* an address a watchpoint saw, -1 none *)
  font : (string, string) Hashtbl.t;    (* the ROM's characters, as cells *)
}

let peek_b t a = Char.code (Bytes.unsafe_get t.mem a)

(* the bus: memory at once; the ports through the machine, which is made
   after it ([t_ref] set then) *)
let make_bus t_ref mem =
  let rd a = Char.code (Bytes.unsafe_get mem a) in
  let wr a v = if a >= 0x4000 then Bytes.unsafe_set mem a (Char.unsafe_chr v) in
  let input port =
    match !t_ref with
    | None -> 0xFF
    | Some t ->
    if port land 1 = 0 then
      (Keyboard.read t.kb (port lsr 8) land Keyboard.read t.kq (port lsr 8))
      lor 0xA0 lor (if t.ear_out <> 0 then 0x40 else 0)
    else if port land 0xFF = 0x1F then 0
    else 0xFF in
  let output port v =
    match !t_ref with
    | None -> ()
    | Some t ->
    if port land 1 = 0 then begin
      Ula.set_border t.ula ~tstate:t.ft (v land 7);
      t.ear_out <- v land 0x10;
      Beeper.level t.beeper ~tstate:t.ft (v land 0x10 <> 0)
    end in
  Z80.{ fetch = rd; read = rd; write = wr; input; output }

(* the ROM's font (0x3D00: characters 32 to 127, 8 bytes each), as the
   cells of the screen show them, plain or inverse; in UTF-8, the
   Spectrum's own three (its 94, 96 and 127: an arrow, the pound, the
   copyright sign) *)
let font_of rom =
  let h = Hashtbl.create 256 in
  for c = 127 downto 32 do
    let cell = String.sub rom (0x3D00 + (c - 32) * 8) 8 in
    let text = match c with 94 -> "\u{2191}" | 96 -> "\u{a3}" | 127 -> "\u{a9}" | _ -> String.make 1 (Char.chr c) in
    Hashtbl.replace h cell text;
    Hashtbl.replace h (String.map (fun x -> Char.chr (Char.code x lxor 0xFF)) cell) text
  done;
  Hashtbl.replace h (String.make 8 '\000') " ";
  h

let create ~rom =
  if String.length rom <> 16384 then invalid_arg "Spectrum: a 48K's ROM is 16 KB";
  let mem = Bytes.make 0x10000 '\000' in
  Bytes.blit_string rom 0 mem 0 16384;
  let t_ref = ref None in
  let direct = make_bus t_ref mem in
  let t = { mem; z = Z80.create direct; direct; ula = Ula.create (); beeper = Beeper.create ();
            kb = Keyboard.create (); kq = Keyboard.create (); keys_queue = Queue.create ();
            key_now = None; key_gap = 0; ft = 0; int_taken = false; frame = 0; ear_out = 0;
            tape = None; watch_hit = -1; font = font_of rom } in
  t_ref := Some t;
  t

let reset t =
  Bytes.fill t.mem 0x4000 0xC000 '\000';
  Z80.reset t.z;
  t.ft <- 0; t.int_taken <- false; t.tape <- None;
  Queue.clear t.keys_queue; t.key_now <- None; t.key_gap <- 0;
  Keyboard.clear t.kq

let z80 t = t.z
let frame t = t.frame

(* ---- keys: emu/1's, a group at a time, by frames ---- *)

let press t key down = Keyboard.set t.kb key down

let queue_keys t groups = List.iter (fun g -> Queue.push g t.keys_queue) groups

let keys_pending t = t.key_now <> None || t.key_gap > 0 || not (Queue.is_empty t.keys_queue)

let keys_frame t =
  match t.key_now with
  | Some (keys, n) ->
    if n <= 1 then begin
      List.iter (fun k -> Keyboard.set t.kq k false) keys;
      t.key_now <- None;
      (* let go a frame; six if the next group presses one of these keys
         again (the ROM takes a key again once it was up for a while) *)
      t.key_gap <-
        (match Queue.peek_opt t.keys_queue with
         | Some (next, _) when List.exists (fun k -> List.mem k keys) next -> 6
         | _ -> 1)
    end else t.key_now <- Some (keys, n - 1)
  | None ->
    if t.key_gap > 0 then t.key_gap <- t.key_gap - 1
    else if not (Queue.is_empty t.keys_queue) then begin
      let keys, n = Queue.pop t.keys_queue in
      List.iter (fun k -> Keyboard.set t.kq k true) keys;
      t.key_now <- Some (keys, n)
    end

(* ---- running ---- *)

(* the frame's end: its picture, the next frame begun *)
let end_frame t =
  t.ft <- t.ft - frame_t;
  t.frame <- t.frame + 1;
  t.int_taken <- false;
  keys_frame t

let render t = Ula.render t.ula t.mem ~flash:(t.frame land 16 <> 0)

(* one instruction, and what comes with it: the tape's trap; or the
   interrupt taken while /INT lasts, alone: the handler's first
   instruction is the next step, so that a breakpoint on 0x0038 sees it *)
let one t =
  let z = t.z in
  let n = if not t.int_taken && t.ft < int_len then Z80.interrupt z 0xFF else 0 in
  if n > 0 then begin t.int_taken <- true; t.ft <- t.ft + n end
  else (match t.tape with
   | Some tape when Z80.get z Z80.PC = 0x0556 ->
     if Tape.trap tape z (fun a v -> if a >= 0x4000 then Bytes.unsafe_set t.mem a (Char.unsafe_chr v))
     then t.ft <- t.ft + 10
     else t.ft <- t.ft + Z80.step z
   | _ -> t.ft <- t.ft + Z80.step z)

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

let peek t space a =
  match space with
  | Emu_proto.Cpu -> peek_b t (a land 0xFFFF)
  | Emu_proto.Ram -> if a < 0 || a >= 0xC000 then failwith "ram: 0 to 0xBFFF" else peek_b t (0x4000 + a)
  | Emu_proto.Rom -> if a < 0 || a >= 0x4000 then failwith "rom: 0 to 0x3FFF" else peek_b t a
  | Emu_proto.Vram -> failwith "a Spectrum has no vram (its screen is in ram, from 0)"

let poke t space a v =
  let v = Char.unsafe_chr (v land 0xFF) in
  match space with
  | Emu_proto.Cpu -> let a = a land 0xFFFF in if a >= 0x4000 then Bytes.set t.mem a v
  | Emu_proto.Ram -> if a < 0 || a >= 0xC000 then failwith "ram: 0 to 0xBFFF" else Bytes.set t.mem (0x4000 + a) v
  | Emu_proto.Rom -> failwith "the rom is read only"
  | Emu_proto.Vram -> failwith "a Spectrum has no vram"

let screen t = render t; Ula.pixels t.ula
let changed t = Ula.changed t.ula

let screen_text t =
  let b = Buffer.create (33 * 24) in
  let cell = Bytes.create 8 in
  for row = 0 to 23 do
    for col = 0 to 31 do
      for k = 0 to 7 do
        let y = row * 8 + k in
        let a = 0x4000 lor ((y land 0xC0) lsl 5) lor ((y land 7) lsl 8) lor ((y land 0x38) lsl 2) in
        Bytes.set cell k (Bytes.get t.mem (a + col))
      done;
      Buffer.add_string b (try Hashtbl.find t.font (Bytes.to_string cell) with Not_found -> "?")
    done;
    Buffer.add_char b '\n'
  done;
  Buffer.contents b

let set_audio t on = Beeper.set_on t.beeper on
let audio_samples t = Beeper.samples t.beeper ~frame_tstates:frame_t

(* ---- files ---- *)

let read_file f =
  let ic = open_in_bin f in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let ext f = String.lowercase_ascii (Filename.extension f)

let load t file =
  let data = read_file file in
  match ext file with
  | ".sna" ->
    let border = Snapshot.load_sna data t.z t.mem in
    Ula.set_border t.ula ~tstate:0 border; t.ft <- 0; t.int_taken <- true;
    Printf.sprintf "snapshot %s (.sna)" (Filename.basename file)
  | ".z80" ->
    let border = Snapshot.load_z80 data t.z t.mem in
    Ula.set_border t.ula ~tstate:0 border; t.ft <- 0; t.int_taken <- true;
    Printf.sprintf "snapshot %s (.z80)" (Filename.basename file)
  | ".tap" ->
    let tape = Tape.of_string data in
    reset t;
    t.tape <- Some tape;
    (* the ROM ready (its tests of memory, its message), then LOAD "" *)
    queue_keys t (([], 110) :: Keyboard.parse "J SS+P SS+P ENTER");
    Printf.sprintf "tape %s, %d blocks" (Filename.basename file) (Tape.blocks tape)
  | e -> failwith ("not a .sna, .z80 or .tap: " ^ e)

let save_state t file =
  let border = Ula.border t.ula in
  let data = match ext file with
    | ".sna" -> Snapshot.save_sna t.z t.mem ~border
    | ".z80" -> Snapshot.save_z80 t.z t.mem ~border
    | e -> failwith ("a state is a .z80 or .sna: " ^ e) in
  let oc = open_out_bin file in
  output_string oc data;
  close_out oc
