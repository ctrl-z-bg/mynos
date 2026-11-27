(** emu/1: an emulated machine as a typed service
    (doc/decisions/retro-emulators.md, section 5). Every emulator of MyNOS
    serves it, registered as <machine><pid> (zx1234, camlboy1234); [info]
    says which machine. Made with {!Ipc.Make}: it describes itself, so the
    Services window, scripts and the agent can use it.

    The safe requests only read. The others change the machine's state:
    the agent asks before them. *)

type space = Cpu | Ram | Vram | Rom
(** [Cpu]: memory as the CPU sees it now; [Ram], [Vram] (a VDP's own: the
    MSX's), [Rom]: each from 0. A machine without one answers an error. *)

type kind = Exec | Read | Write
(** A breakpoint on the PC (an instruction about to run: its opcode's
    fetch), or a watchpoint on reads or writes of a range (the CPU's
    reads, not its fetches of instructions). *)

type breakpoint = { id : int; kind : kind; addr : int; len : int }

type stop =
  | Running                 (** [wait]'s time ran out: it still runs *)
  | Paused of int           (** paused, at this PC *)
  | Hit of int * int * int  (** breakpoint [id], at [pc], the address
                                touched (a watchpoint's; an Exec's: [pc]);
                                the machine paused there *)

type info = {
  machine : string;         (** "ZX Spectrum 48K" *)
  rom : string;
  loaded : string;          (** what was loaded last; "" none *)
  frame : int;              (** frames run since the start *)
  fps : float;
  paused : bool;
  key_names : string;       (** the names [keys] knows, space-separated *)
}

type _ request =
  | Info : info request
      (** safe *)
  | Regs : (string * int) list request
      (** safe: the CPU's registers *)
  | Peek : space * int * int -> int list request
      (** safe: [(space, addr, len)], [len] up to 4096 *)
  | Disasm : int * int -> string request
      (** safe: [(addr, n)], [n] instructions, a line each *)
  | Screen_text : string request
      (** safe: the screen as text, a line per row; [?] where a cell is
          not a character *)
  | Screenshot : string request
      (** safe: the screen as a PNG in /tmp (<name>-<frame>.png, the
          service's name): its path. The caller chooses no path, so it
          writes nothing else *)
  | Pause : stop request
      (** [Paused pc] *)
  | Resume : unit request
  | Step : int -> stop request
      (** [n] instructions: the machine paused first if it ran *)
  | Frames : int -> stop request
      (** [n] frames as fast as it can (the clock not waited for, in a
          window or headless): paused first if it ran, paused after;
          [Hit] if a breakpoint stopped it *)
  | Break : kind * int * int -> int request
      (** [(kind, addr, len)]: its id *)
  | Unbreak : int -> unit request
  | Breaks : breakpoint list request
  | Wait : float -> stop request
      (** at most this many seconds, until a breakpoint is hit or the
          machine pauses; [Paused pc] at once if it is paused *)
  | Keys : string -> unit request
      (** keys of the machine, a group after another, each held 2 frames
          (or [:n] frames: ["CS+0:5"]), then let go for one: a group is
          names joined by +. On the Spectrum ["P 2 SS+K 2 ENTER"] types
          PRINT 2+2. Answered once the last is let go; an error
          ("paused") at once if the machine is paused *)
  | Poke : space * int * int list -> unit request
      (** [(space, addr, bytes)]; ROM: an error *)
  | Load : string -> string request
      (** a file (tape, snapshot, cartridge, by its name): what it was *)
  | Save_state : string -> unit request
  | Load_state : string -> unit request
  | Reset : unit request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
module I : module type of Ipc.Make (Protocol)

val find : string -> string list
(** The registered names made of this prefix and digits only ("zx":
    zx1234, not zxspectrum): the emulators of a machine running now. *)
