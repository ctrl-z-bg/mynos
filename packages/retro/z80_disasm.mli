(** The Z80's instructions as text (emu/1's [disasm]), decoded by
    {!Z80.decode} and named with its tables: what is shown is what the core
    runs. Undocumented instructions by their usual names (SLL, IXH, IN F,
    (C), OUT (C),0); an ED or DDCB opcode that does nothing as [DB]. *)

val disasm : (int -> int) -> int -> string * int
(** [disasm read pc]: the instruction at [pc] (["LD A,(IX+5)"]), and its
    length in bytes. *)

val lines : (int -> int) -> int -> int -> string
(** [lines read pc n]: [n] instructions from [pc], a line each:
    ["8000  DD 7E 05     LD A,(IX+5)"]. *)
