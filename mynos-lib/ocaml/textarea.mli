(** A multi-line text box for {!Gui} windows (doc/decisions/studio.md):
    the text editor of the graphical session ([text]) and MyNOS Studio are
    made with it.

    {[
      let t = Textarea.create ~highlight:Textarea.ocaml "let x = 1\n" in
      Gui.run ~title:"Edit" ~resizable:(300, 200) 640 480 () (fun ui () ->
          Textarea.frame ui 1 t 0 0 (Gui.width ui) (Gui.height ui))
    ]}

    Text is UTF-8, in lines; a tab stays a tab, shown to the next multiple
    of 8 columns. The keys, when the box has them ([ui.Gui.field] is its
    id: a click in it gives them): the arrows, Home, End, Page Up and Page
    Down, with Shift to select; Backspace, Delete, Enter (keeping the
    line's indentation), Tab; Ctrl-A all, Ctrl-C copy, Ctrl-X cut, Ctrl-V
    paste (the system's clipboard), Ctrl-Z undo, Ctrl-Y redo. Other
    keys (Ctrl-S, Ctrl-F...) are the program's: it finds them in
    [ui.Gui.keys]. The mouse places the cursor and selects by dragging;
    the wheel and the bar at the right scroll. *)

type t

(** {1 Colours} *)

type highlighter = {
  start : int;
      (** the state before the first line (0) *)
  colour : int -> string -> (int * int * int) list * int;
      (** a state and a line as shown (tabs expanded): spans (first
          column, columns, colour), and the state after it (a comment
          left open, a string...) *)
}

val ocaml : highlighter
(** OCaml: keywords, strings and characters, comments (nested, across
    lines), numbers, capitalized names. *)

(** {1 A text box} *)

val create : ?tab:int -> ?numbers:bool -> ?highlight:highlighter -> string -> t
(** A box holding this text. [tab]: Tab inserts spaces to the next multiple
    of [tab] columns (by default it inserts a tab); [numbers]: line
    numbers at the left. *)

val frame : Gui.ui -> int -> t -> int -> int -> int -> int -> unit
(** [frame ui id t x y w h]: draws the box at this place and size, and
    takes this frame's keys (when it has them) and mouse. *)

val text : t -> string
val set_text : t -> string -> unit
(** The whole text, replaced (undo brings the old one back). *)

val modified : t -> bool
val set_modified : t -> bool -> unit
(** Changed since it was last said not to be (a file saved). *)

val version : t -> int
(** A number that changes at every change of the text. *)

val undo : t -> unit
val redo : t -> unit

(** {1 Where things are} *)

val cursor : t -> int * int
(** The cursor's line and column (from 1; the column in characters). *)

val goto : t -> int -> int -> unit
(** [goto t line column] (from 1), scrolled into view. *)

val lines : t -> int
val line : t -> int -> string
(** The line [n] (from 1), without its newline; [""] beyond the text. *)

val replace_lines : t -> int -> int -> string -> unit
(** [replace_lines t first last text]: lines [first] to [last] (from 1,
    inclusive) replaced by [text] (its lines); [last = first - 1] inserts
    before [first]. Undoable. *)

val selection : t -> string option
val insert : t -> string -> unit
(** At the cursor, over the selection if there is one. *)

val find : t -> string -> bool
(** The next occurrence after the cursor (from the start again at the
    end): selected, scrolled into view. *)

val word_before_cursor : t -> string
(** The letters, digits, [_], ['] and [.] just before the cursor:
    ["Sound.to"]; what a completion completes. *)

val cursor_xy : t -> int * int
(** Where the cursor was drawn, at the last frame: in the window. *)

(** {1 Marks: errors and warnings} *)

type mark = {
  mline : int;       (** from 1 *)
  first : int;       (** bytes in the line, [first] included... *)
  last : int;        (** ... [last] not; [first = last]: to the end *)
  message : string;
}

val set_marks : t -> mark list -> unit
(** Underlined in red; edits do not move them: set them again. *)

val mark_at_cursor : t -> mark option

(** {1 The clipboard} The system's (module {!Clipboard}): what one program
    copies, another pastes. This copy serves without the service. *)

val clipboard : string ref
