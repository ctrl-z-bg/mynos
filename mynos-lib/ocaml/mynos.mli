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

val log : string -> unit
(** Write a line to the kernel log: the serial log port, and not the screen
    once the system has started. For services' messages. *)

val uptime : unit -> float
(** Seconds since boot. *)

val time : unit -> float
(** Seconds since 1970 (UTC), from the clock read at boot. *)

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

(** {1 Drivers}

    MyNOS processes may use the I/O ports directly (the processor runs them
    with I/O privilege level 3), and receive interrupts as [V]s on a
    semaphore. *)

val inb : int -> int
val outb : int -> int -> unit
(** [outb port byte] *)

val inw : int -> int
val outw : int -> int -> unit

val insw : int -> int -> string
(** [insw port n] reads [n] 16-bit words from [port]: [2 n] bytes, the
    first byte of each word first (a disk sector is [insw port 256]). *)

val outsw : int -> string -> unit
(** Write the bytes of a string to a port, 16 bits at a time. *)

val driver_register : string -> int -> int
(** [driver_register name irq] makes this process the driver of [irq]:
    returns a semaphore that is [V]ed at each interrupt ({!sem_p} waits for
    one). The process acknowledges the interrupt controller itself. *)

val enable_irq : int -> unit
