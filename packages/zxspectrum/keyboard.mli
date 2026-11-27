(** The 48K's keyboard: 40 keys in 8 half-rows of 5, read on port 0xFE,
    the address's high byte choosing the half-rows (a 0 bit each). *)

type key =
  | Caps_shift | Symbol_shift | Enter | Space
  | Digit of int        (** 0-9 *)
  | Letter of char      (** 'A'-'Z' *)

type t

val create : unit -> t
val set : t -> key -> bool -> unit
(** [set k key down] *)

val read : t -> int -> int
(** [read k high]: bits 0-4 of port 0xFE for the half-rows whose bit in
    [high] is 0 (a key down: its bit 0), the others 1. *)

val names : string
(** The names [parse] knows: "A".."Z" "0".."9" "ENTER" "SPACE" "CS" "SS". *)

val parse : string -> (key list * int) list
(** emu/1's notation: ["P 2 SS+K 2 ENTER"]: groups of names joined by +,
    each followed by the frames it is held (2 if not said). Raises
    [Failure] on a name it does not know. *)
