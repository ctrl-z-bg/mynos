(** An MSX1 (doc/decisions/retro-emulators.md): a Z80 at 3.58 MHz, the
    TMS9918A (16 KB of VRAM), the AY-3-8910, the PPI (slots, keyboard),
    64 KB of RAM. Slot 0: the BIOS (C-BIOS, or a real one), slot 1: a
    cartridge, slot 2: empty, slot 3: the RAM; no expanded slots. Frames
    of 59,736 T-states (262 lines of 228, 60 a second), the VDP's
    interrupt at their end. No cassette, no disk. *)

type t

val create : bios:string -> ?logo:string -> unit -> t
(** [bios]: 32 KB at 0x0000 of slot 0; [logo]: C-BIOS's 16 KB at 0x8000
    there (its picture at start), none for a real BIOS. *)

val reset : t -> unit
(** Power off and on: the RAM cleared, the cartridge kept. *)

val z80 : t -> Z80.t

type stop =
  | Frame_done
  | Breakpoint of int
  | Watch of int * int
(** As {!Spectrum}'s: [Breakpoint pc] before its instruction, [Watch (pc,
    addr)] after the one that touched [addr]. *)

val run_fast : t -> stop
val run_checked : t -> check:(int -> bool) -> stop
val step : t -> stop
val set_watch : t -> (int -> bool -> bool) option -> unit
(** As the Spectrum's ([Spectrum.run_fast] and the others). *)

val frame : t -> int

(** {2 Keys} *)

val press : t -> Msx_keys.key -> bool -> unit
val queue_keys : t -> (Msx_keys.key list * int) list -> unit
val keys_pending : t -> bool

(** {2 Memory, screen, sound} *)

val peek : t -> Emu_proto.space -> int -> int
val poke : t -> Emu_proto.space -> int -> int -> unit
(** [Cpu]: as the slots are now; [Ram]: the 64 KB of slot 3; [Vram]: the
    VDP's 16 KB; [Rom]: the BIOS (and C-BIOS's logo from 0x8000), read
    only. *)

val screen : t -> int array
(** [Vdp.width] x [Vdp.height], 0xRRGGBB. *)

val changed : t -> bool array
val screen_text : t -> string
(** The text modes' screen (40 or 32 columns, 24 lines), the names'
    table's characters; [Failure] in Graphics II and multicolor, where
    there are no characters to read. *)

val set_audio : t -> bool -> unit
val audio_samples : t -> string
(** The PSG's sound, as the Spectrum's beeper's. *)

(** {2 Files} *)

val load : t -> string -> string
(** A cartridge (.rom, .mx1, .mx2: put in slot 1, the machine reset) or a
    state (.state): what it was. *)

val save_state : t -> string -> unit
(** A .state: MyNOS's own format (the CPU, RAM, VRAM, chips, slots and
    banks); the cartridge is not in it, only its digest, checked when
    the state is loaded. *)

val cartridge : t -> string
(** What is in slot 1: "" for nothing. *)
