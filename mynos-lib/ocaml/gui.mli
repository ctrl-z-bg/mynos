(** A small immediate-mode toolkit, on {!Display} and {!Gfx}
    (doc/decisions/gui.md).

    A program gives {!run} its state and a function that draws a frame
    from it, and returns the next state: widgets are drawn and answer in
    the same call ([button] returns [true] when it was clicked).

    {[
      let () =
        Gui.run ~title:"Counter" 200 90 0 (fun ui n ->
            Gui.label ui 16 16 (Printf.sprintf "Clicked %d times" n);
            if Gui.button ui 16 44 120 "Click me" then n + 1 else n)
    ]} *)

type ui = {
  window : Display.window;
  g : Gfx.t;                      (** the window's pixels *)
  mutable mx : int;               (** the pointer, in the window *)
  mutable my : int;
  mutable buttons : int;
  mutable clicked : bool;         (** the left button was released in this frame *)
  mutable press : int * int;      (** where it was pressed *)
  mutable keys : string list;     (** typed in this frame, oldest first *)
  mutable focused : bool;
  mutable tick : bool;            (** this frame is a timer's *)
  mutable field : int;            (** the text field that has the keys (-1: none) *)
  mutable wheel : int;            (** the wheel's notches in this frame (positive: down) *)
}

(** Colours *)

val background : int
val foreground : int
val muted : int
val accent : int
val panel_colour : int

val label : ?colour:int -> ?bold:bool -> ui -> int -> int -> string -> unit

val paragraph : ?colour:int -> ui -> int -> int -> int -> string -> int
(** [paragraph ui x y width text]: the text, wrapped at words to the width
    (pixels): the height used. *)

val panel : ?colour:int -> ui -> int -> int -> int -> int -> unit

val button : ?h:int -> ui -> int -> int -> int -> string -> bool
(** [button ui x y width label]: [true] in the frame where it is clicked. *)

val hovered : ui -> int -> int -> int -> int -> bool
(** The pointer is in the rectangle, and in the clip in force (a widget
    scrolled out of sight is not hovered). *)

val scroll : ?colour:int -> ui -> int -> int -> int -> int -> int -> (int -> int) -> unit
(** [scroll ui id x y w h content]: a box whose content may be taller than
    it. [content top] draws the content from [top] (the box's top, less
    how far it is scrolled), clipped to the box, and returns its height.
    The wheel over the box, and its bar (clicked or dragged), scroll it.
    [id] tells a window's boxes apart. *)

val scroll_to_end : ui -> int -> unit
(** The box [id], scrolled to its end at the next frame (a log, a
    conversation). *)

val text_field : ui -> int -> int -> int -> int -> string -> string
(** [text_field ui id x y width value]: an editable line; [id] tells the
    fields of a window apart (a click gives the keys to one). The value,
    edited by this frame's keys. *)

val list_item : ui -> int -> int -> int -> selected:bool -> string -> bool
(** [list_item ui x y width ~selected label]: a row of a list; [true] when
    clicked. *)

exception Quit

val run : ?title:string -> ?tick:float -> int -> int -> 'a -> (ui -> 'a -> 'a) -> unit
(** [run width height state frame]: a window, drawn by [frame] at every
    event (and every [tick] seconds, if given), until it is closed (its
    close box, or [frame] raising {!Quit}). *)

val spawn : string -> unit
(** Start a program of the RAM disk (a .byte, on ocamlrun). *)
