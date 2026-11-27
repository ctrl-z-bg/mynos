(** The MSX2's clock, a Ricoh RP5C01: port 0xB4 selects a register (0 to
    15), port 0xB5 writes or reads it, four bits. Register 13 picks one
    of four blocks of 13: 0 the time (seconds to years, in decimal
    digits), 1 the alarm and the 12/24 hours setting, 2 and 3 a RAM the
    BIOS keeps its settings in. The time is the host's, read when it is
    read; writing it changes nothing. The RAM is not kept across runs. *)

type t

val create : clock:(unit -> float) -> t
(** [clock]: seconds since 1970, UTC. *)

val reset : t -> unit
val select : t -> int -> unit
val write : t -> int -> unit
val read : t -> int
(** The selected register: its four bits, the high four set. *)

val save : t -> string
val restore : t -> string -> unit
val state_size : int
