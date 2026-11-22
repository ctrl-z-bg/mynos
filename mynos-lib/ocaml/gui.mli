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
  mutable window : Display.window;
  mutable g : Gfx.t;              (** the window's pixels (new ones after a resize) *)
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
  mutable released : string list; (** let go in this frame, as they were typed *)
  mutable held : string list;     (** the keys held down now (games): typed, not yet
                                      let go; none while the window has not the focus *)
}

(** Colours *)

val background : int
val foreground : int
val muted : int
val accent : int
val panel_colour : int

(** {1 Text, which the mouse selects}

    What {!label}, {!paragraph} and {!text} draw, the user can select:
    dragging over it (within the scroll box where the drag began) or a
    double click on a word. The selection shows in blue, and is copied to
    the clipboard (module {!Clipboard}) when the button is let go, as in a
    Terminal: another program pastes it. A click elsewhere clears it. Text
    drawn with {!Gfx.text} directly (buttons, list items) is not
    selectable. *)

val label : ?colour:int -> ?bold:bool -> ui -> int -> int -> string -> unit

val paragraph : ?colour:int -> ui -> int -> int -> int -> string -> int
(** [paragraph ui x y width text]: the text, wrapped at words to the width
    (pixels): the height used. *)

val text : ?bold:bool -> ?max:int -> ui -> int -> int -> string -> int -> int
(** [text ui x y s colour]: {!Gfx.text} on the window, selectable. *)

val selectable : ?max:int -> int -> int -> string -> unit
(** [selectable x y s]: [s], drawn by the program at [(x, y)] its own
    way (cell by cell, in colours), is selectable as if {!text} drew it. *)

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

val scroll_to : ui -> int -> int -> unit
(** [scroll_to ui id offset]: the box [id] scrolled so that its content's
    pixel [offset] is at its top, at the next frame (a line found). *)
(** The box [id], scrolled to its end at the next frame (a log, a
    conversation). *)

val text_field : ui -> int -> int -> int -> int -> string -> string
(** [text_field ui id x y width value]: an editable line; [id] tells the
    fields of a window apart (a click gives the keys to one). The value,
    edited by this frame's keys. *)

val list_item : ui -> int -> int -> int -> selected:bool -> string -> bool
(** [list_item ui x y width ~selected label]: a row of a list; [true] when
    clicked. *)

(** {1 Files} *)

type entry = { name : string; is_dir : bool; size : int }

val entries : string -> entry list
(** A directory's entries: directories first, then files, by name ([] if
    it cannot be read). *)

val size_text : int -> string
(** ["512 B"], ["12 KB"], ["1.4 MB"]. *)

val parent : string -> string
val join : string -> string -> string

(** {1 The file picker}

    A panel over the window: the places ([/], [/tmp], [/disk]), the path
    (each part goes there), the entries (directories, and the files the
    filter keeps, or all of them). A click enters a directory or chooses a
    file; a second click, Open or Enter, picks it; Cancel or Escape gives
    up. While it is open, the window's other widgets get no pointer and no
    keys.

    {[
      if Gui.button ui 8 8 80 "Open..." then
        Gui.open_file_picker ~filter:(fun n -> Filename.check_suffix n ".trc") 1;
      match Gui.file_picker ui 1 with
      | Some (Gui.Picked path) -> load path
      | Some Gui.Cancelled | None -> ()
    ]}
    Draw it last, so that it is over the rest. *)

type picked = Picked of string | Cancelled

val open_file_picker :
  ?title:string -> ?dir:string -> ?filter:(string -> bool) -> int -> unit
(** Open the picker [id] at [dir] (a directory, or a file: chosen in its
    directory). *)

val file_picker : ui -> int -> picked option
(** Draw the picker [id] if it is open: [Some] once it is answered (it is
    closed then). *)

exception Quit

val run : ?title:string -> ?tick:float -> ?resizable:int * int -> ?unsaved:(unit -> bool) ->
  int -> int -> 'a -> (ui -> 'a -> 'a) -> unit
(** [run width height state frame]: a window, drawn by [frame] at every
    event (and every [tick] seconds, if given), until it is closed (its
    close box, or [frame] raising {!Quit}). Outside the graphical session
    it says so, and ends the program (exit status 2). With [~resizable:(min_w,
    min_h)] the user may resize it (its grip, a double click on its title
    to maximize): [frame] then lays out by {!width} and {!height}. With
    [~unsaved], its close box asks "Close without saving?" while
    [unsaved ()] is true. *)

val width : ui -> int
val height : ui -> int
(** The window's size now. *)

val spawn : ?args:string list -> string -> unit
(** Start a program of the RAM disk (a .byte, on ocamlrun), with these
    arguments. *)
