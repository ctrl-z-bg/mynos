(** The MyNOS system interface for OCaml programs.

    Thin bindings to the native MyNOS calls (libmynos): IPC channels and
    ports, semaphores, sleeping, the service registry. They need the MyNOS
    runtime ([mynos-runtime/ocamlrun]); compile with
    [ocamlc -use-prims mynos-runtime/primitives -I mynos-lib/ocaml mynos.cma].

    Errors raise {!Error} with the function name and the MyNOS error code
    (see {!error_name}). *)

exception Error of string * int

val error_name : int -> string
(** ["full"], ["busy"], ["invalid"], ["deny"], ["broken"], ["expired"]. *)

(** {1 Processes and time} *)

val getpid : unit -> int

val sleep : float -> unit
(** Block for at least this many seconds (10 ms resolution). *)

type stats = {
  processes : int;
  threads : int;
  pid : int;
  ppid : int;
  free_pages : int;   (** free physical pages, 4 KB each *)
}

val stats : unit -> stats

(** {1 Ports and channels}

    A server allocates a port and listens on it; each [listen] returns a new
    channel to one client, which got its end with [connect]. Messages are
    byte strings. *)

val alloc_port : unit -> int
val listen : int -> int
val connect : int -> int
val free_port : int -> unit
val change_port_owner : int -> int -> unit

val send : int -> string -> unit
val recv : ?timeout:float -> int -> string
(** Wait for the next message on a channel. With [timeout] (seconds), raise
    [Error ("recv", c)] with [error_name c = "expired"] if none arrives. *)

val free_channel : int -> unit

(** {1 Semaphores} *)

val sem_create : int -> int
val sem_p : int -> unit
val sem_try_p : int -> bool
val sem_v : int -> unit
val sem_free : int -> unit

(** {1 Service registry} *)

val register : string -> int
(** Register a service name; return the port allocated for it. *)

val lookup : string -> int
(** The port of a registered service. *)

(** {1 Starting programs} *)

type status =
  | Exited of int     (** the program called [exit] with this code *)
  | Signaled of int   (** killed: 11 for an invalid memory access *)

val spawn : ?env:string array -> string -> string array -> int
(** [spawn path argv] starts the ELF program in file [path] (on the RAM
    disk) as a child process with arguments [argv] ([argv.(0)] is by
    convention the program name) and returns its pid. A bytecode program is
    started through the runtime:
    [spawn "ocamlrun" [| "ocamlrun"; "prog.byte"; "arg" |]]. *)

val wait : int -> status
(** Wait for the end of this child process. *)

val wait_any : unit -> int * status
(** Wait for the end of any child process: its pid and status. *)
