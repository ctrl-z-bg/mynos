(** The Texas Instruments TMS9918A, the MSX1's video chip: 16 KB of VRAM
    of its own, reached through two ports (0x98 the data, 0x99 the
    registers and the address); four modes (Graphics I and II, text of
    40 columns, multicolor), 32 sprites of 8 or 16 pixels, four on a
    line, their collisions; an interrupt at each frame's end (vertical
    blanking).

    The picture is drawn whole when asked for, from the VRAM as it is at
    the frame's end: changes in the middle of a frame (a split screen)
    are not followed. The sprites' status (the fifth sprite on a line,
    collisions) is worked out at each frame's end, as the chip would
    have found it while drawing. *)

type t

val width : int
val height : int
(** The picture: 256 x 192 and a border (the backdrop) around: 288 x 216. *)

val create : unit -> t
val reset : t -> unit

val write_data : t -> int -> unit
(** Port 0x98: a byte into the VRAM at the address, which goes on. *)

val read_data : t -> int
(** Port 0x98: the byte read ahead; the next one read. *)

val write_ctrl : t -> int -> unit
(** Port 0x99: two bytes, an address (bit 6 of the second: for writing;
    else a read ahead) or a register (bit 7: the second's low 3 bits
    say which, the first is the value). *)

val read_status : t -> int
(** Port 0x99: F (bit 7, the frame's end), 5S (bit 6, a fifth sprite on a
    line), C (bit 5, a collision), the fifth sprite's number; F, 5S and C
    cleared, and the interrupt with F. *)

val irq : t -> bool
(** The interrupt line: F, and the interrupts enabled (register 1, bit 5). *)

val frame_end : t -> unit
(** The frame's end: the sprites' status, F set. *)

val register : t -> int -> int
val vram : t -> Bytes.t

type mode = Graphics1 | Graphics2 | Multicolor | Text

val mode : t -> mode
val name_table : t -> int

val pixels : t -> int array
(** The picture ([width] x [height], 0xRRGGBB), drawn now. *)

val changed : t -> bool array
(** The rows [pixels]'s last call changed ([height]): the drawer clears
    them as it draws them. *)

val save : t -> string
val restore : t -> string -> unit
(** The chip's state (registers, address, VRAM...), as a string of known
    length ([state_size]). *)

val state_size : int
