(** The V9938's command engine: copies, fills, lines, a search, between
    the VRAM and the CPU, on the bitmap modes' pixels or bytes (registers
    32 to 46). A command is done at once (CE stays clear); HMMC, LMMC and
    LMCM move a byte or a pixel each time the CPU writes register 44 or
    reads status register 7, TR set while they go. The mode is given as
    its number: 4 to 7 (Graphics 4 to 7; the others' VRAM as 7's). *)

type t

val create : Bytes.t -> t
(** The engine over this VRAM. *)

val reset : t -> unit

val start : t -> int array -> int array -> int -> unit
(** Register 46 written: [start t regs status mode]. *)

val colour_written : t -> int array -> int -> int array -> int -> unit
(** Register 44 written ([regs], the value, [status], [mode]): the next
    unit of an HMMC or LMMC. *)

val read_colour : t -> int array -> int array -> int -> int
(** Status register 7 read: the colour there; LMCM's next fetched. *)

val status2 : t -> int
(** Status register 2's bits of the engine's: TR (7), BD (4), CE (0). *)

val state_size : int
val save : t -> string
val restore : t -> string -> unit
