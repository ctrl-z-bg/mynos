(** The MSX's keyboard (international layout): a matrix of 11 rows of 8
    keys, a row chosen by the PPI's port C (bits 0-3), read on its port
    B (0xA9), a key down a 0 bit. Rows 0-8 are the main keys; 9 and 10,
    the numeric keypad, are not here. *)

type key = int
(** row * 8 + bit *)

type t

val create : unit -> t
val set : t -> key -> bool -> unit
val clear : t -> unit

val read : t -> int -> int
(** [read k row]: port B for that row. *)

val of_name : string -> key
(** "A", "7", "ENTER", "SHIFT", "LEFT"... ([names]); [Failure] for others. *)

val names : string
(** "A-Z 0-9 ENTER SPACE SHIFT CTRL GRAPH CAPS CODE ESC TAB STOP BS SELECT
    HOME INS DEL UP DOWN LEFT RIGHT F1-F5", and the punctuation's keys:
    MINUS EQUAL BSLASH LBRACKET RBRACKET SEMICOLON QUOTE BACKQUOTE COMMA
    PERIOD SLASH DEAD. *)

val of_char : char -> key list option
(** A character typed on a PC, as the MSX's keys: [Some [shift; '2']]
    for '@'. *)

val parse : string -> (key list * int) list
(** emu/1's notation, as the Spectrum's: groups separated by spaces, names
    joined by +, held 2 frames or [:n]. *)
