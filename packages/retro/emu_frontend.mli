(** What an emulated Z80 machine needs around it: a window (its picture
    doubled, its keys, its sound), the service emu/1 (<name><pid>), a
    mode without a window and a benchmark; the command line. The
    machine gives a frame at a time ({!MACHINE}); this does the rest, as
    zxspectrum's main does by hand (it came first).

    {[
      msx [FILE|GAME]               a window
      msx --headless [FILE|GAME]    no window: the machine and its service
      msx --bench N [--no-service] [FILE|GAME]
    ]}

    A GAME is one of the package's (/disk/pkg/<program>/games), named
    without its directory or extension. Page Up pauses, Page Down turns
    the sound on and off, Escape quits. *)

type stop = Frame_done | Breakpoint of int | Watch of int * int
(** As the machines' own: a frame done, a breakpoint (before the
    instruction at this PC), a watchpoint (at this PC, this address). *)

module type MACHINE = sig
  type t
  type key

  val program : string
  (** The command's name: its games in /disk/pkg/[program]/games. *)

  val service : string
  (** The service's prefix: "msx" makes msx<pid>. *)

  val title : string
  (** The window's. *)

  val hz : float
  (** Frames a second. *)

  val width : int
  val height : int
  (** The picture, before it is doubled. *)

  val game_exts : string list
  (** The extensions a game of the package's may have: [".rom"]. *)

  val create : unit -> t
  (** The machine, its ROMs found; [Failure] says what is missing. *)

  val machine : t -> string
  (** emu/1's [info]: "MSX1". *)

  val rom_name : t -> string
  val z80 : t -> Z80.t
  val frame : t -> int
  val run_fast : t -> stop
  val run_checked : t -> check:(int -> bool) -> stop
  val step : t -> stop
  val set_watch : t -> (int -> bool -> bool) option -> unit

  val press : t -> key -> bool -> unit
  val keys_of : string -> key list option
  (** A key the window gives ([Gui]'s held keys: "a", "\027[A"...), as
      the machine's keys; [None]: none of its. *)

  val queue_keys : t -> string -> unit
  (** emu/1's notation; [Failure] for a name it does not know. *)

  val keys_pending : t -> bool
  val key_names : string

  val peek : t -> Emu_proto.space -> int -> int
  val poke : t -> Emu_proto.space -> int -> int -> unit
  val screen : t -> int array
  val changed : t -> bool array
  val screen_text : t -> string
  val set_audio : t -> bool -> unit
  val audio_samples : t -> string
  val load : t -> string -> string
  val save_state : t -> string -> unit
  val reset : t -> unit
end

module Make (M : MACHINE) : sig
  val main : unit -> unit
  (** The command line ({!Sys.argv}), then the window, the headless loop
      or the benchmark; it does not return. *)
end
