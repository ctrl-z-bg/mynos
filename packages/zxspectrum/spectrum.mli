(** A ZX Spectrum 48K (doc/decisions/retro-emulators.md, section 4): 16 KB
    of ROM, 48 KB of RAM, the ULA's screen and border, the keyboard, the
    beeper. Frames of 69,888 T-states, the interrupt at their start; no
    memory contention. *)

type t

val create : rom:string -> t
(** [rom]: its 16 KB. *)

val reset : t -> unit
val z80 : t -> Z80.t

type stop =
  | Frame_done
  | Breakpoint of int         (** at this PC, before its instruction *)
  | Watch of int * int        (** at this PC, after the instruction that
                                  touched this address *)

val run_fast : t -> stop
(** The rest of the frame, nothing checked per instruction: always
    [Frame_done]. *)

val run_checked : t -> check:(int -> bool) -> stop
(** The rest of the frame, [check pc] before each instruction (true: stop
    there, before it), and the watchpoints' hits; resumable: the next
    call goes on from there. The first instruction is run unchecked, so
    that resuming from a breakpoint does not stop on it again. *)

val step : t -> stop
(** One instruction (and the frame's end, if it reached it). *)

val set_watch : t -> (int -> bool -> bool) option -> unit
(** [Some w]: the CPU's bus becomes one that calls [w addr write] for each
    read (not fetch) and write of memory (true: stop after the
    instruction); [None]: the direct bus again, which costs nothing. *)

val frame : t -> int
(** Frames done since the start. *)

(** {2 Keys} *)

val press : t -> Keyboard.key -> bool -> unit
(** The window's keys: down or up. *)

val queue_keys : t -> (Keyboard.key list * int) list -> unit
(** emu/1's keys: each group held for its frames, then let go for one,
    by the frames that follow; besides the window's. *)

val keys_pending : t -> bool

(** {2 Memory, screen, sound} *)

val peek : t -> Emu_proto.space -> int -> int
val poke : t -> Emu_proto.space -> int -> int -> unit
(** [Cpu]: 0-0xFFFF (writes to the ROM ignored, as the machine does);
    [Ram]: 0-0xBFFF (0x4000 up); [Rom]: 0-0x3FFF, read only
    ([Failure]); [Vram]: [Failure]. *)

val screen : t -> int array
(** 320 x 240 (the border 32 and 24 around 256 x 192), 0xRRGGBB, the
    border by lines, FLASH at its 16 frames. *)

val screen_text : t -> string
(** 24 lines of 32: each 8 x 8 cell compared with the ROM's font
    (0x3D00, characters 32-127), inverse too; [?] for the others. *)

val set_audio : t -> bool -> unit
(** The beeper, off by default: then it costs nothing. *)

val audio_samples : t -> string
(** The frame's sound: 22050 Hz, 16 bits signed little-endian, stereo. *)

(** {2 Files} *)

val load : t -> string -> string
(** A .sna, .z80 (48K) or .tap, by its name: what it was. A tape's blocks
    go to the ROM's LD-BYTES at once, through a trap on 0x0556; loading
    one resets the machine and types LOAD "" when the ROM is ready. *)

val save_state : t -> string -> unit
(** A .z80 (version 3) or .sna, by its name. *)
