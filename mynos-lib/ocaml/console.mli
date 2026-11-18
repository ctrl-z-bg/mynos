(** console/1, the protocol of the consoles (mynos-lib/include/
    mynos_console.h): consoled, the text console, and the console service
    of each terminal window (gui/terminal.ml). Programs use them through the
    standard library (libmynos speaks it for them: read on fd 0, write on
    fds 1 and 2 of a terminal window, termios, Ctrl-C). *)

type _ request =
  | Read : int -> string request
      (** max: a line (line mode), keys (raw mode); [""] at the end *)
  | Mode : int * int * int -> unit request
      (** mode ({!canon}, {!echo}, {!nosig}), VMIN, VTIME *)
  | Keymap : int -> int request
      (** {!layout_us}, {!layout_it}, or -1: the layout in use *)
  | Write : string -> unit request
  | Foreground : int -> unit request
      (** the program the caller waits for: Ctrl-C ends it (0: none) *)

val canon : int
val echo : int
val nosig : int
val layout_us : int
val layout_it : int

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type client
val connect : ?service:string -> unit -> client
(** "console" by default (consoled). *)

val call : client -> 'a request -> 'a

(** {1 Services that answer later} (a read waits for keys) *)

val decode : string -> (Protocol.packed, string) result
val reply : 'a request -> 'a -> string
val error_reply : string -> string
