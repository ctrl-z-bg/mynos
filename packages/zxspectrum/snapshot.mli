(** Snapshots of a 48K: .sna and .z80 (versions 1, 2 and 3, 48K only). The
    memory is the machine's 64 KB (the RAM at 0x4000-0xFFFF); the border's
    colour comes back. *)

val load_sna : string -> Z80.t -> Bytes.t -> int
(** A .sna's contents: the registers set, the RAM written, then the RETN
    its PC is on the stack for; the border. [Failure] if not one. *)

val load_z80 : string -> Z80.t -> Bytes.t -> int
(** A .z80's contents (compressed or not); the border. [Failure] if not
    one, or not a 48K's. *)

val save_sna : Z80.t -> Bytes.t -> border:int -> string
(** The machine as a .sna (its PC put on the stack of the copy, not of the
    machine). *)

val save_z80 : Z80.t -> Bytes.t -> border:int -> string
(** The machine as a .z80, version 3, its pages compressed. *)
