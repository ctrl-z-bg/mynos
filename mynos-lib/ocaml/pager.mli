(** Files mapped into memory, read only when touched: the external pager
    (mynos-vzp, appendix B.14). The kernel gives the pages of a mapping to
    a service in user space, [pagerd] (services/pager), which reads each
    one from the file the first time it is touched; a page fault becomes
    a request to that service. Protocol ["pager/1"].

    {[
      let m = Pager.map_file "/disk/docs/big.bin" in
      print_char (Char.chr m.{0})       (* the first page read now *)
    ]}

    A mapping is read-only, and a page is read when first touched: what
    the file holds then. The bytes stay valid until {!unmap}; after it,
    touching them ends the program. *)

type mapping = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

type stats = {
  regions : int;     (** mappings open *)
  given : int;       (** pages read and given, since pagerd started *)
  refused : int;     (** pages refused (a file that could not be read) *)
}

val map_file : ?offset:int -> ?length:int -> string -> mapping
(** [map_file path]: the file from [offset] (a multiple of 4096, default
    0), [length] bytes (default: to its end). Raises [Failure] without
    the service, {!Ipc.Remote_error} for a file it cannot map. *)

val unmap : mapping -> unit
(** Give a mapping back. *)

val stats : unit -> stats

(** {2 The protocol} *)

type _ request =
  | Map : string * int * int -> (int * int) request
      (** path, offset, length (0: to the end): the first page's number, the length *)
  | Unmap : int -> unit request                (** a mapping's first page *)
  | Stats : stats request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : string -> handler -> 'b

(** {2 The pager's side (pagerd)} *)

type fault = {
  pid : int;         (** the process that waits *)
  page : int;        (** the page it waits for, as a page number *)
  token : int;       (** its region's token, plus its index in the region *)
  write : bool;
}

val register : unit -> int
(** Become the pager (the io privilege): a semaphore for {!wait}. *)

val region : pid:int -> pages:int -> token:int -> writable:bool -> int
(** [pages] of [pid]'s memory, waiting for the pager, with tokens from
    [token] on: the first page's number. *)

val wait : int -> fault
(** The next page waited for (blocks this thread only). *)

val supply : fault -> string -> unit
(** Give the page: these bytes (at most 4096, then zeros). *)

val refuse : fault -> unit
(** No page: the process that waits ends. *)
