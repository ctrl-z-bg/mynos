(** The event recorder and its player (doc/decisions/tracer.md).

    While a recording is on, the kernel records every interaction between
    processes: spawns and exits, IPC connections, messages (with their
    first 56 bytes) and channels freed. This module starts and stops it,
    saves and loads recordings, and shows them: as events, as calls (a
    request and its reply, with the calls made meanwhile nested), and in
    the Chrome trace event format that Perfetto (ui.perfetto.dev) shows.

    {[
      Tracer.start ();
      ignore (Sys.readdir "/disk");
      let r = Tracer.stop_and_get () in
      Tracer.print_calls stdout r
    ]} *)

type kind =
  | Process   (** a process alive when the recording started *)
  | Spawn     (** [pid] started [peer] *)
  | Exit      (** [pid] ended, with status [arg] *)
  | Connect   (** [pid] (the client) connected to [peer] on [channel] *)
  | Send      (** [pid] sent [size] bytes to [peer] on [channel] *)
  | Recv      (** [pid] received [size] bytes from [peer] on [channel] *)
  | Free      (** [pid] freed its end of [channel] *)
  | Irq       (** interrupt [arg] for the driver [pid], interrupting [peer] *)
  | Other of int

type event = {
  seq : int;
  time : float;          (** milliseconds since the recording started *)
  kind : kind;
  pid : int;
  tid : int;
  peer : int;
  channel : int;
  size : int;
  arg : int;
  data : string;         (** the first bytes of a message; a name *)
}

type recording = {
  events : event array;
  dropped : int;         (** events lost because the buffer was full *)
  names : (int, (int * string) list) Hashtbl.t;
      (** pid -> its programs, newest first, with the [seq] from which it
          ran each (pids are reused) *)
}

(** {2 Recording} *)

val start : unit -> unit
(** Start a recording (the kernel's buffer: 8192 events). *)

val stop : unit -> unit

val read : unit -> string
(** The events recorded since the last [read], raw (96 bytes each): read
    often during long recordings, so that the buffer does not fill. *)

type info = { recording : bool; pending : int; dropped_now : int; khz : float }
val info : unit -> info
(** [khz]: the time-stamp counter's rate, measured since [start]. *)

val save : string -> raw:string -> info -> unit
(** A recording file: the raw events, the clock rate, the dropped count. *)

val load : string -> recording
val of_raw : raw:string -> info -> recording
val stop_and_get : unit -> recording
(** Stop, read what is left, and free the kernel's buffer. *)

(** {2 Playing} *)

val name : recording -> ?seq:int -> int -> string
(** ["fatfs(7)"]: the program [pid] was running at event [seq] (the
    last one by default) *)

val describe : recording -> event -> string
(** A message in words: ["block/1 Read (2061, 1)"], ["fs OPEN \"a.txt\""],
    ["Ok (512 bytes)"]... *)

val print_events : out_channel -> recording -> unit

type call = {
  client : int;
  server : int;
  start : float;
  finish : float;          (** [nan] if the reply is not in the recording *)
  request : string;
  reply : string;
  depth : int;             (** nesting: calls made by a server meanwhile *)
  client_tid : int;
  server_tid : int;
  server_start : float;    (** when the server received the request *)
  server_finish : float;   (** when it sent the reply *)
}

val calls : recording -> call list
val print_calls : out_channel -> recording -> unit

val to_json : recording -> string
(** The Chrome trace event format (Perfetto, chrome://tracing): a track
    per process, calls as boxes on the client's and the server's, arrows
    from request to handling, spawns and exits as instants. *)
