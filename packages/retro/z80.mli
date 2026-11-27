(** A Zilog Z80, an instruction at a time, its T-states counted
    (doc/decisions/retro-emulators.md). Pure OCaml, [int] only: every byte
    masked ([land 0xFF]), every word ([land 0xFFFF]), the same on 31 and
    63 bits. All the prefixes (CB, ED, DD, FD, DDCB, FDCB), the
    undocumented instructions and flags (bits 3 and 5), MEMPTR, as FUSE
    has them. *)

type bus = {
  fetch : int -> int;            (** an opcode's read (an M1 cycle): address
                                     0..0xFFFF -> 0..0xFF *)
  read : int -> int;             (** any other read of memory *)
  write : int -> int -> unit;
  input : int -> int;            (** a port: its whole 16 bits (BC, or A and n) *)
  output : int -> int -> unit;
}
(** Memory and ports. [fetch] is apart from [read] for the machines that
    need it (contention, paging on M1) and for watchpoints, which look at
    [read] only: the instructions' fetches are breakpoints' business. The
    bytes of an instruction after its opcode (operands, displacements)
    are [read]s. *)

type t

val create : bus -> t
(** Reset: PC 0, interrupts off, IM 0, AF and SP 0xFFFF. *)

val set_bus : t -> bus -> unit
(** Watchpoints: a bus that checks, put in only while there are some. *)

val bus : t -> bus
val reset : t -> unit

val step : t -> int
(** One instruction, all its prefixes (a run of DD and FD: each but the
    last a 4-T-state NOP, as the chip); in HALT, 4 T-states. Its
    T-states, also added to [tstates]. *)

val interrupt : t -> int -> int
(** /INT, this byte on the data bus (IM 2's vector, IM 0's instruction:
    RST only): the T-states of its acceptance; 0 if not accepted (IFF1
    off, or just after EI): the machine asks again while its /INT lasts.
    Leaves HALT. *)

val nmi : t -> int
val halted : t -> bool

val tstates : t -> int
val set_tstates : t -> int -> unit

type reg =
  | A | F | B | C | D | E | H | L | AF | BC | DE | HL
  | AF' | BC' | DE' | HL' | IX | IY | SP | PC | I | R
  | IM | IFF1 | IFF2 | MEMPTR

val get : t -> reg -> int
val set : t -> reg -> int -> unit
(** Values masked to the register's width. *)

val registers : t -> (string * int) list
(** All of them, named: emu/1's [regs]. *)

(** {2 Decoding: the core's rules, shared with Z80_disasm} *)

type prefix = Plain | Cb | Ed | Dd | Fd | Ddcb | Fdcb

val decode : (int -> int) -> int -> prefix * int * int * int
(** [decode read pc]: the prefix, the opcode, its displacement (DD, FD,
    DDCB, FDCB: signed; else 0), the address after the opcode (and, for
    DDCB and FDCB, after the displacement and the opcode, which come in
    that order). A run of DD and FD counts as its last one, as [step]
    takes it. *)

val r8 : string array
(** "B" "C" "D" "E" "H" "L" "(HL)" "A": the 3-bit register field's names *)

val rp : string array     (** "BC" "DE" "HL" "SP" *)
val rp2 : string array    (** "BC" "DE" "HL" "AF" *)
val cc : string array     (** "NZ" "Z" "NC" "C" "PO" "PE" "P" "M" *)
val alu : string array    (** "ADD A," "ADC A," "SUB " "SBC A," "AND " "XOR " "OR " "CP " *)
val rot : string array    (** "RLC" "RRC" "RL" "RR" "SLA" "SRA" "SLL" "SRL" *)
