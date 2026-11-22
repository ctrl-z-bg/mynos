(** fs/1, the protocol of the file services (mynos-lib/include/mynos_fs.h):
    memrofs (the RAM disk, [/], read-only), tmpfs ([/tmp]), fatfs
    ([/disk]). Programs use files through the standard library (libmynos
    speaks this protocol for them); this module speaks it typed, for the
    services and for programs that want to.

    {[
      let c = Fs.connect "fatfs" in
      Fs.call c (Fs.List "docs")        (* [("a.txt", 12); ("old", -1)] *)
    ]}
    Paths are inside the service: ["docs/a.txt"], no leading slash. A
    descriptor belongs to the process that opened it. *)

type _ request =
  | Open : string * int -> int request      (** path, flags: a descriptor *)
  | Close : int -> unit request
  | Read : int * int -> string request      (** fd, max: [""] at the end *)
  | Write : int * string -> int request     (** fd, data: bytes written *)
  | Seek : int * int * int -> int request   (** fd, offset, whence (0 1 2) *)
  | List : string -> (string * int) list request
      (** a directory's entries: name, size ([-1]: a directory) *)
  | Remove : string -> unit request
  | Mkdir : string -> unit request
  | Rmdir : string -> unit request
  | Rename : string * string -> unit request
  | Space : (int * int) request
      (** the file system's size and its space free, in KB *)

(** Open flags *)

val o_write : int
val o_creat : int
val o_trunc : int
val o_append : int
val o_excl : int
(** With [o_creat]: the open fails ([exists]) if the file is there. *)

val io_max : int
(** The largest Read or Write: 16384. *)

(** Errors: an Error reply's message starts with its name. *)

val ok : int
val not_found : int
val too_many : int
val denied : int
val not_open : int
val invalid : int
val read_only : int
val no_space : int
val is_dir : int
val not_empty : int
val exists : int
val not_dir : int

val error_name : int -> string
val error_of : string -> int
(** The error of a message ("not_found: ..."): {!invalid} if none fits. *)

val fail : int -> 'a
(** In a service: answer with this error. *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

(** {1 Clients} *)

type client
val connect : string -> client
(** The file service registered under this name: "memrofs", "tmpfs",
    "fatfs". *)

val call : client -> 'a request -> 'a
(** @raise Ipc.Remote_error with the error's message. *)

(** {1 Services} *)

type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : string -> handler -> 'b
(** Register under this name and answer requests, one at a time. *)
