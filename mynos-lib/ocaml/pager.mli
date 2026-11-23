(** Memory from the external pager (mynos-vzp, appendix B.14): files
    mapped into memory, and memory that may go to the disk. The kernel
    gives a mapping's pages to a service in user space, [pagerd]
    (services/pager), which provides each one the first time it is
    touched; a page fault becomes a request to that service. Protocol
    ["pager/1"].

    {[
      let m = Pager.map_file "/disk/docs/big.bin" in
      print_char (Char.chr m.{0});      (* the first page read now *)
      let a = Pager.alloc 1000 in       (* 4 MB, kept to the budget's size in RAM *)
      a.{0} <- 42
    ]}

    [pagerd] keeps at most a budget of its pages in memory (in all its
    mappings): past it, it takes a page back (the least recently used, by
    the clock algorithm) and keeps it on the disk: memory of {!alloc} and
    a {!Private} mapping's changes in [/disk/swap], a {!Shared} mapping's
    changes in its file. A page is read when first touched. The bytes
    stay valid until {!unmap}; after it, touching them ends the program. *)

type mapping = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

(** How a file is mapped. *)
type mode =
  | Read_only
  | Shared          (** writable: the changes go to the file ({!sync}, {!unmap}) *)
  | Private         (** writable: the changes are the program's alone *)

type stats = {
  regions : int;        (** mappings and allocations open *)
  given : int;          (** pages provided, since pagerd started *)
  refused : int;        (** pages refused (a file that could not be read) *)
  resident : int;       (** its pages in memory now *)
  budget : int;         (** at most this many *)
  swapped_out : int;    (** pages written to the swap *)
  swapped_in : int;     (** pages read back from it *)
  written : int;        (** pages written back to their files *)
}

val map_file : ?offset:int -> ?length:int -> ?mode:mode -> string -> mapping
(** [map_file path]: the file from [offset] (a multiple of 4096, default
    0), [length] bytes (default: to its end). Raises [Failure] without
    the service, {!Ipc.Remote_error} for a file it cannot map. *)

val alloc : int -> mapping
(** [alloc pages]: memory of that many pages (4 KB), zeros, which may go
    to the swap. *)

val sync : mapping -> unit
(** A {!Shared} mapping's changes written to its file now. *)

val unmap : mapping -> unit
(** Give a mapping back ({!Shared}: its changes written first). *)

val set_budget : int -> unit
(** The most pages pagerd keeps in memory (at least 4). *)

val stats : unit -> stats

(** {2 The protocol} *)

type _ request =
  | Map : string * int * int * mode -> (int * int) request
      (** path, offset, length (0: to the end), mode: the first page's number, the length *)
  | Unmap : int -> unit request                (** a mapping's first page *)
  | Stats : stats request
  | Alloc : int -> int request                 (** pages: the first page's number *)
  | Sync : int -> unit request                 (** a mapping's first page *)
  | Budget : int -> unit request

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

val query : pid:int -> page:int -> int
(** A page given: 0 if it is not there any more, else 1, or 2 if it was
    used since the last query, or 4 if written since the last {!copy}. *)

val evict : pid:int -> page:int -> token:int -> writable:bool -> string
(** A page given, taken back: its next use faults to the pager again
    (with [token]). Its bytes. *)

val copy : pid:int -> page:int -> string
(** A page given, copied, its writes forgotten. Its bytes. *)
