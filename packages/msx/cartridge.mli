(** A cartridge in the MSX's slot 1: a ROM of up to 64 KB put where its
    header says (the "AB" at 0x4000 or 0x8000 of the address space), or a
    MegaROM, larger, whose banks of 8 or 16 KB a program changes by
    writing to the cartridge: Konami's (with and without the SCC, whose
    sound is not emulated), ASCII's of 8 and 16 KB. The kind is guessed
    from the writes its code makes (the [LD (nnnn),A] it has), as
    emulators do. *)

type kind = Plain of int   (** the address of its first byte *)
          | Konami | Konami_scc | Ascii8 | Ascii16

type t

val of_string : string -> t
(** [Failure] if it is no MSX ROM (no "AB" where one should be, an empty
    file). *)

val kind : t -> kind
val describe : t -> string
(** "48 KB at 0x0000", "MegaROM ASCII8, 256 KB". *)

val block : t -> int -> (Bytes.t * int) option
(** The 8 KB at the CPU's address [i * 0x2000] (i 0-7), the slot being
    selected there: where they are (the bytes and an offset); [None]
    where the cartridge has nothing (it reads 0xFF). The machine keeps
    these, and asks again when [write] says the banks changed. *)

val write : t -> int -> int -> bool
(** A write into the slot: [true] if a MegaROM's bank changed. *)

val reset : t -> unit
(** The banks as at power on. *)

val banks : t -> int array
val set_banks : t -> int array -> unit
(** The banks now (four of 8 KB, at 0x4000, 0x6000, 0x8000, 0xA000), for a
    saved state. *)
