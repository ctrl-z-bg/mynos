(** A .tap file: blocks (a length, then the block: its flag, the data, a
    checksum), given to the ROM's LD-BYTES at once: a trap on 0x0556, its
    entry, when the tape has a block left. *)

type t

val of_string : string -> t
(** [Failure] if it is not a .tap. *)

val blocks : t -> int
val left : t -> int

val trap : t -> Z80.t -> (int -> int -> unit) -> bool
(** At LD-BYTES's entry (PC 0x0556: A the flag wanted, the carry set to
    load, clear to verify, IX where, DE how many): the next block, its
    bytes written with [poke] (loaded) or compared (verified), the carry
    set if all went well, then LD-BYTES's RET. [false] (nothing done)
    when the tape is at its end: the ROM then waits for a tape, as the
    machine would. *)
