(** Client of the block services (disk drivers such as [ata0]): sectors of
    512 bytes, read and written over IPC. Protocol:
    [mynos-lib/include/mynos_block.h]. Errors raise {!Mynos.Error}, or
    [Failure] when the driver refuses a request. *)

val sector : int
(** 512 *)

val max_count : int
(** Sectors per request (32): larger transfers are split. *)

type t
(** A block device. *)

val connect : ?service:string -> unit -> t
(** The device served by [service] (["ata0"] by default). *)

val sectors : t -> int
(** Its size, in sectors. *)

val read : t -> int -> int -> string
(** [read dev lba count] *)

val write : t -> int -> string -> unit
(** [write dev lba bytes]: [bytes] is a whole number of sectors. *)
