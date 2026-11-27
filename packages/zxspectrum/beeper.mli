(** The beeper: port 0xFE's bit 4 (EAR), a speaker's level, sampled at
    22050 Hz. Off: it records nothing, it costs nothing. *)

type t

val create : unit -> t
val set_on : t -> bool -> unit
val on : t -> bool

val level : t -> tstate:int -> bool -> unit
(** The speaker's level from this T-state of the frame. *)

val samples : t -> frame_tstates:int -> string
(** The frame's sound (its [frame_tstates] T-states), 16-bit signed
    little-endian, stereo; [""] when off. *)
