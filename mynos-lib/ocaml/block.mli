(** Block devices (disk drivers such as [ata0]): sectors of 512 bytes,
    over typed IPC ({!Ipc}, protocol ["block/1"]).

    From the toplevel:
    {[
      let d = Block.connect ();;
      Block.call d Block.Info;;             (* - : int = 131072 *)
      Block.call d (Block.Read (0, 1));;    (* the first sector *)
    ]} *)

val sector : int
(** 512 *)

val max_count : int
(** Sectors per request (32): {!read} and {!write} split larger ones. *)

(** {2 The protocol} *)

type _ request =
  | Info : int request
      (** the size of the device, in sectors *)
  | Read : int * int -> string request
      (** [Read (lba, count)]: [count] sectors (1 to [max_count]) *)
  | Write : int * string -> unit request
      (** [Write (lba, bytes)]: a whole number of sectors, at most
          [max_count] *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

(** {2 Clients} *)

type t
(** A block device. *)

val connect : ?service:string -> unit -> t
(** The device served by [service] (["ata0"] by default). *)

val call : t -> 'a request -> 'a
(** One request. Raises {!Ipc.Remote_error} when the driver refuses it. *)

val sectors : t -> int
(** Its size, in sectors. *)

val read : t -> int -> int -> string
(** [read dev lba count], in requests of at most [max_count] sectors.
    Raises [Failure] when the driver refuses a request. *)

val write : t -> int -> string -> unit
(** [write dev lba bytes]: [bytes] is a whole number of sectors. *)

(** {2 Drivers} *)

type handler = { handle : 'a. 'a request -> 'a }

val serve : string -> handler -> 'b
(** Register a block service under this name and answer its requests. *)

val answer : handler -> string -> string
(** For tests: the reply to a request message. *)

val request_message : 'a request -> string
val read_reply : string -> 'a request -> 'a
