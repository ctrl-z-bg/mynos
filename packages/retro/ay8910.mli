(** The General Instrument AY-3-8910 (and Yamaha's YM2149, the same to a
    program): three square-wave channels, a noise generator, an envelope,
    and two 8-bit ports; the MSX's PSG, the Spectrum 128K's sound. Its
    sixteen registers are written and read through the machine's ports;
    its sound is made at 22050 Hz, a frame at a time, the writes placed
    at the T-states they came at. Off, it keeps its registers and makes
    no sound: it costs nothing. *)

type t

val create : clock:int -> cpu_clock:int -> t
(** [clock]: the chip's (the MSX: 1789772 Hz, the CPU's half); [cpu_clock]:
    the CPU's, for the T-states of the writes (3579545). *)

val reset : t -> unit

val select : t -> int -> unit
(** The register latch (the MSX's port 0xA0). *)

val write : t -> tstate:int -> int -> unit
(** The selected register (port 0xA1), at this T-state of the frame. *)

val read : t -> int
(** The selected register (port 0xA2): registers 14 and 15 are the ports,
    read through [port_in]. *)

val set_port_in : t -> (int -> int) -> unit
(** [f 0] or [f 1]: what the chip's port A or B reads (the MSX's
    joysticks on A). By default 0xFF. *)

val registers : t -> int array
(** The sixteen, as written: for a state saved. *)

val set_registers : t -> int array -> unit

val set_on : t -> bool -> unit
val on : t -> bool

val samples : t -> frame_tstates:int -> string
(** The frame's sound (its [frame_tstates] T-states), 16-bit signed
    little-endian, stereo, the three channels mixed; [""] when off. *)
