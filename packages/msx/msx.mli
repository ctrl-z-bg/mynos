(** An MSX1 or an MSX2 (doc/decisions/retro-emulators.md): a Z80 at 3.58
    MHz, the AY-3-8910 (the MSX2's YM2149, the same), the PPI (slots,
    keyboard).

    The MSX1: the TMS9918A (16 KB of VRAM), 64 KB of RAM. Slot 0: the
    BIOS (C-BIOS, or a real one), slot 1: a cartridge, slot 2: empty,
    slot 3: the RAM; no expanded slots.

    The MSX2: the V9938 (128 KB of VRAM), a memory mapper of 512 KB, the
    RP5C01 clock. Slot 0: the BIOS; slot 1: a cartridge; slot 2: empty;
    slot 3 expanded, 3-0 the SUB-ROM, 3-2 the mapper's RAM (as openMSX's
    C-BIOS MSX2).

    Frames of 59,736 T-states (262 lines of 228, 60 a second): the VDP
    draws each line as it begins, the picture's first (192 or 212); its
    interrupt at the picture's end, and on the MSX2 at the line register
    19 names. No cassette, no disk. *)

type t

val create : ?sub:string -> ?clock:(unit -> float) -> bios:string -> ?logo:string -> unit -> t
(** [bios]: 32 KB at 0x0000 of slot 0; [logo]: C-BIOS's 16 KB at 0x8000
    there (its picture at start), none for a real BIOS. With [sub] (16 KB,
    the SUB-ROM) an MSX2, whose clock reads [clock] (seconds since 1970;
    0 by default). *)

val msx2 : t -> bool

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
(** [Cpu]: as the slots are now; [Ram]: the 64 KB of slot 3 (MSX2: the
    mapper's 512 KB, segment after segment); [Vram]: the VDP's 16 KB (128);
    [Rom]: the BIOS (C-BIOS's logo from 0x8000; the MSX2's SUB-ROM from
    0xC000), read only. *)

val screen : t -> int array
(** The VDP's picture ({!Vdp.width} x {!Vdp.height}), 0xRRGGBB. *)

val set_draw : t -> bool -> unit
(** {!Vdp.set_draw}: whether the lines are drawn as they go (a window
    looks), or the picture made only when {!screen} asks. *)

val changed : t -> bool array
val screen_text : t -> string
(** The text modes' screen (40, 80 or 32 columns, 24 lines), the names'
    table's characters; [Failure] in the other modes, where there are no
    characters to read. *)

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
