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

val version : unit -> string
(** The system's version: the year and month it was built, and the commit
    (["2026.11-71dc1d2"]), as the kernel's uname says. *)

val log_position : unit -> int
(** The kernel's log (its messages and the services', since boot) is a
    sequence of bytes: how many have been logged so far. The kernel keeps
    the last 64 KB of them. *)

val log_read : int -> int -> string
(** [log_read from max]: the logged bytes from position [from] (or from
    the oldest kept, if [from] is older), at most [max]. The position after
    them is [from] plus their length, if [from] was still kept. *)

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

val registered : unit -> (string * int * int) list
(** The registry's names, with their ports and the processes that
    registered them (only live ones). *)

(** {1 Starting programs} *)

type status =
  | Exited of int     (** the program called [exit] with this code *)
  | Signaled of int   (** killed: 11 for an invalid memory access *)

val spawn : ?env:string array -> ?io:bool -> string -> string array -> int
(** [spawn path argv] starts the ELF program in file [path] as a child
    process with arguments [argv] ([argv.(0)] is by convention the program
    name) and returns its pid. A name without [/] is looked for at the root
    of the RAM disk, then in the current directory. The child starts in
    the current directory, with environment [env] (without [~env], ours;
    [~env:[||]], none). A bytecode program is
    started through the runtime:
    [spawn "ocamlrun" [| "ocamlrun"; "prog.byte"; "arg" |]].
    [~io:true] gives the child the [io] privilege (port I/O, IRQs: a
    driver), which only a process that has it can give. *)

val channel_peer : int -> int
(** The pid of the process at the other end of one of our channels: who
    calls a service (doc/decisions/identity-and-permissions.md). *)

type process_info = { alive : bool; io : bool }

val process_info : int -> process_info option
(** [None]: no such process (it ended and was collected). Pids are not
    reused: when a process's slot is taken again, the new one has another
    pid. *)

type process = {
  p_pid : int;
  parent : int;
  p_io : bool;          (** the io privilege: a driver *)
  threads : int;
  name : string;        (** the program's base name ("fatfs", "sh") *)
  bytecode : bool;      (** an OCaml program, run by ocamlrun; else native (C) *)
}

val processes : unit -> process list
(** The live processes, by slot. *)

val kill : int -> unit
(** End a process, as killed (its parent's [wait] sees [Signaled 9]).
    Not init, and not a process with privileges the caller lacks (only a
    driver ends a driver); raises {!Error} otherwise, or if there is no
    such process. *)

val environment : unit -> string array
(** Our environment, as ["NAME=value"] strings. A child gets it unless
    {!spawn} is given another one; [PWD] is set to the current directory,
    and [MYNOS_STDIN], [MYNOS_STDOUT] ([">>path"] to append) and
    [MYNOS_STDERR] redirect its standard input and output to files. *)

val wait : int -> status
(** Wait for the end of this child process. *)

val wait_any : unit -> int * status
(** Wait for the end of any child process: its pid and status. *)

(** {1 Drivers}

    Processes with the [io] privilege (drivers: the [driver] lines of
    init.rc) may use the I/O ports directly (the processor runs them with
    I/O privilege level 3), and receive interrupts as [V]s on a semaphore;
    in any other process an [inb] or [outb] ends the program. *)

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
    one). The kernel acknowledges the interrupt controllers; [enable_irq]
    unmasks the line, once. *)

val enable_irq : int -> unit

(** {1 Console} *)

val console_mode :
  canon:bool -> echo:bool -> ?isig:bool -> ?vmin:int -> ?vtime:int -> unit -> unit
(** The console's input mode, as termios: [canon] for line editing (else
    keys come one by one, the arrows and editing keys as VT100 sequences),
    [echo] to show typed characters; for raw input, [vmin] and [vtime] as
    termios VMIN and VTIME; [isig:false] makes Ctrl-C a key instead of an
    interrupt (editors), [isig:true] an interrupt again (unchanged if
    omitted). The raw mode ends when another process reads the console.
    The screen is 80x25 and understands VT100 sequences. *)

val console_foreground : int -> unit
(** The program this process started and now waits for (0: none): Ctrl-C
    on the console ends it, unless its console mode turned interrupts off
    (termios without ISIG: editors). sh says it for each command. *)
