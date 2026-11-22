(** The Game Boy's sound (DMG): its registers (0xFF10-0xFF3F) and its
    output, stereo 16-bit little-endian samples at {!rate} a second.
    Written for MyNOS: see MYNOS.md. *)

open Uints

type t

val rate : int

val create : unit -> t
val after_boot : t -> unit
(** The registers as the boot ROM leaves them. *)

val accepts : t -> uint16 -> bool
val read_byte : t -> uint16 -> uint8
val write_byte : t -> addr:uint16 -> data:uint8 -> unit

val run : t -> mcycles:int -> unit
(** The machine's cycles go by (machine cycles: 4 clocks each). *)

val take_samples : t -> string
(** The samples made since the last call. *)

val set_enabled : t -> bool -> unit
(** Off (the default): no samples, nearly no cost; the registers work. *)
