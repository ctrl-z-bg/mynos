(** The MSX's video chip: the Texas Instruments TMS9918A (the MSX1's) or
    the Yamaha V9938 (the MSX2's).

    The TMS9918A: 16 KB of VRAM of its own, reached through two ports
    (0x98 the data, 0x99 the registers and the address); four modes (text
    of 40 columns, Graphics I and II, multicolor), 32 sprites of 8 or 16
    pixels, four on a line, their collisions; an interrupt at the
    picture's end.

    The V9938 has those and: 128 KB of VRAM, a palette of 16 colours out
    of 512 (port 0x9A), registers written through port 0x9B too, status
    registers 0 to 9, text of 80 columns, Graphics 3 (SCREEN 4) and the
    bitmaps of Graphics 4 to 7 (SCREEN 5 to 8), sprites of mode 2 (eight
    on a line, a colour a line), 212 lines, the vertical scroll, a line
    interrupt, and a command engine (copies, fills, lines: {!Vdp_cmd}).

    The picture is drawn a line at a time as the beam reaches it
    ({!line}), with the VRAM and the registers of that moment: a split
    screen shows as it would. The sprites' status (the fifth or ninth
    sprite on a line, collisions) is found as each line is reached. *)

type t

val create : ?v9938:bool -> unit -> t
(** A TMS9918A, or with [~v9938:true] a V9938. *)

val width : t -> int
val height : t -> int
(** The picture: a TMS9918A's 256 x 192 and a border (the backdrop)
    around, 288 x 216; a V9938's 512 x 212 (its 256 columns doubled) and
    a border, 576 x 228. *)

val is_v9938 : t -> bool
val reset : t -> unit

val write_data : t -> int -> unit
(** Port 0x98: a byte into the VRAM at the address, which goes on. *)

val read_data : t -> int
(** Port 0x98: the byte read ahead; the next one read. *)

val write_ctrl : t -> int -> unit
(** Port 0x99: two bytes, an address (bit 6 of the second: for writing;
    else a read ahead) or a register (bit 7: the second's low bits say
    which, the first is the value). *)

val write_palette : t -> int -> unit
(** Port 0x9A (V9938): a palette entry, two bytes (0RRR0BBB, 00000GGG),
    register 16's; it goes on. *)

val write_indirect : t -> int -> unit
(** Port 0x9B (V9938): the register register 17 names. *)

val read_status : t -> int
(** Port 0x99: the status register (V9938: register 15's). S0: F (bit 7,
    the frame's end), 5S (bit 6, a fifth sprite on a line; mode 2: a
    ninth), C (bit 5, a collision), that sprite's number; F, 5S and C
    cleared, and the interrupt with F. S1: FH (bit 0, the line interrupt),
    cleared. S2: TR, VR, HR, BD, CE. S7: a colour of the command engine's;
    S8, S9: SRCH's X. *)

val irq : t -> bool
(** The interrupt line: F and the interrupts enabled (register 1, bit 5);
    on the V9938, FH and register 0's bit 4 too. *)

val set_clock : t -> (unit -> int) -> unit
(** How the chip knows the T-states into the line now (S2's HR). *)

val line : t -> int -> unit
(** The frame's line [y] begins (0 to 261, the machine calls each): the
    picture's lines (192, or the V9938's 212) are drawn, then at the
    first after them the frame's picture is done and F set. *)

val set_draw : t -> bool -> unit
(** Whether the lines are drawn (true at first): with nobody looking (no
    window), false; the lines then find only their sprites' status, and
    {!pixels} draws the picture whole from the VRAM of now. *)

val register : t -> int -> int
val vram : t -> Bytes.t

type mode = Graphics1 | Graphics2 | Multicolor | Text | Graphics3 | Graphics4 | Graphics5
          | Graphics6 | Graphics7 | Text2

val mode : t -> mode
val name_table : t -> int

val pixels : t -> int array
(** The picture ([width] x [height], 0xRRGGBB). *)

val changed : t -> bool array
(** The rows changed since the drawer cleared them ([height]): it clears
    them as it draws them. *)

val save : t -> string
val restore : t -> string -> unit
(** The chip's state (registers, address, palette, VRAM...), as a string
    of known length ([state_size]). *)

val state_size : t -> int
