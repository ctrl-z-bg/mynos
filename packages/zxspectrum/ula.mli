(** The ULA's picture: 256 x 192 pixels and their attributes (ink, paper,
    BRIGHT, FLASH), inside a border of 32 x 24 whose colour is followed
    line by line through the frame. Drawn once a frame, from memory: no
    effects within a line (none of the 48K's contention either). *)

type t

val width : int
val height : int
(** 320 and 240 *)

val create : unit -> t

val border : t -> int
val set_border : t -> tstate:int -> int -> unit
(** A write to port 0xFE: the border's colour from this T-state of the
    frame. *)

val render : t -> Bytes.t -> flash:bool -> unit
(** The frame's picture, from the memory (64 KB: the screen at 0x4000,
    the attributes at 0x5800); then the border's changes forgotten, its
    colour kept for the next frame. *)

val pixels : t -> int array
(** [width * height], 0xRRGGBB, row by row. *)

val changed : t -> bool array
(** The rows [render] changed ([height]); the drawer clears them. *)
