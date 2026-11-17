(** The display, over typed IPC with the service [display] (displayd,
    services/display; doc/decisions/gui.md). Protocol ["display/1"].

    A window's pixels are a {!Gfx.t} of its program, shared with the
    display: draw in it, then {!damage} what changed. Events come with
    {!next_event}. Module {!Gui} builds on this.

    {[
      let w = Display.window ~title:"Hello" 300 120 in
      Gfx.fill w.Display.pixels 0 0 300 120 0x2D6CA2;
      ignore (Gfx.text w.pixels 20 50 "Hello, MyNOS" 0xFFFFFF);
      Display.damage w;
      let rec loop () = match Display.next_event w with
        | Display.Close -> Display.destroy w
        | _ -> loop () in
      loop ()
    ]} *)

type event =
  | Key of string            (** typed: UTF-8, VT100 sequences for other keys *)
  | Mouse of { x : int; y : int; buttons : int }
      (** in the window; buttons: 1 left, 2 right, 4 middle *)
  | Close                    (** its close box, or the session's end *)
  | Tick                     (** no event within the timeout *)
  | Focus of bool

type _ request =
  | Info : (int * int) request
  | Create : string * int * int -> int request
  | Attach : int -> unit request
  | Damage : int * int * int * int * int -> unit request
  | Next_event : int * int -> event request
  | Destroy : int -> unit request
  | Set_title : int * string -> unit request
  | Start : unit request
  | Wait_session : unit request
  | Stop : unit request
  | Move : int * int * int -> unit request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : unit -> t
(** Waits up to 5 s for the service. *)

val call : t -> 'a request -> 'a

type window = { display : t; id : int; pixels : Gfx.t }

val window : ?display:t -> ?title:string -> int -> int -> window
(** A window of this size (its content), white until drawn. *)

val damage : ?x:int -> ?y:int -> ?w:int -> ?h:int -> window -> unit
(** Show a part of the pixels again (by default, all). *)

val next_event : ?timeout:float -> window -> event
(** The next event; [Tick] if none came within [timeout] seconds (0.:
    wait forever, the default). *)

val set_title : window -> string -> unit
val move : window -> int -> int -> unit
val destroy : window -> unit
