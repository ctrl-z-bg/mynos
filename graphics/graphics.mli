(** OCaml's portable graphics library, on MyNOS (mynos-0rn).

    The interface of the [graphics] package (OCaml's [Graphics] module,
    which left the distribution in 4.09), written again in OCaml on top of
    {!Display} and {!Gfx}: no C stubs, so programs written for
    [Graphics] compile unchanged against [graphics.cma]. It works only in
    the graphical session ([gui]).

    The coordinates are [Graphics]': the origin is the bottom left corner
    of the window, y grows upwards. Colours are [0xRRGGBB].

    Differences from the X11 implementation:
    - one font (Terminus 8x16): [set_font] and [set_text_size] do nothing;
    - [sound] does nothing;
    - the drawing reaches the screen in batches: at every call that reads
      the mouse or the keys, at [synchronize], and at most 20 ms after
      it was drawn if the program keeps drawing;
    - the window's close box ends the program ([exit 0]);
    - keys that are not characters (arrows, function keys) are not
      reported; characters are Latin-1, as with X11. *)

exception Graphic_failure of string
(** Raised by the functions below when they fail, or when the window is
    not open. *)

(** {1 Initializations} *)

val open_graph : string -> unit
(** Open the window. The argument is X11's geometry: [""] (600 x 450) or
    [" WxH"], for example [" 640x480"]; a position after it is ignored. *)

val close_graph : unit -> unit
val set_window_title : string -> unit
val resize_window : int -> int -> unit
(** The window is made again at the new size; its content is kept, as
    much as fits. *)

val clear_graph : unit -> unit
(** The whole window in the background colour (white). *)

val size_x : unit -> int
val size_y : unit -> int

(** {1 Colours} *)

type color = int

val rgb : int -> int -> int -> color
val set_color : color -> unit
val background : color
val foreground : color
val black : color
val white : color
val red : color
val green : color
val blue : color
val yellow : color
val cyan : color
val magenta : color

(** {1 Points and lines} *)

val plot : int -> int -> unit
val plots : (int * int) array -> unit
val point_color : int -> int -> color
(** The colour of a pixel, or -1 outside the window. *)

val moveto : int -> int -> unit
val rmoveto : int -> int -> unit
val current_x : unit -> int
val current_y : unit -> int
val current_point : unit -> int * int
val lineto : int -> int -> unit
val rlineto : int -> int -> unit
val curveto : int * int -> int * int -> int * int -> unit
(** A cubic Bézier curve from the current point, through two control
    points, to the third; the current point moves there. *)

val draw_rect : int -> int -> int -> int -> unit
val draw_poly_line : (int * int) array -> unit
val draw_poly : (int * int) array -> unit
val draw_segments : (int * int * int * int) array -> unit
val draw_arc : int -> int -> int -> int -> int -> int -> unit
(** [draw_arc x y rx ry a1 a2]: from angle [a1] to [a2], in degrees,
    counter-clockwise. *)

val draw_ellipse : int -> int -> int -> int -> unit
val draw_circle : int -> int -> int -> unit
val set_line_width : int -> unit

(** {1 Text} *)

val draw_char : char -> unit
val draw_string : string -> unit
(** At the current point (the text's bottom left), which then moves to
    the text's end. The string is UTF-8. *)

val set_font : string -> unit
val set_text_size : int -> unit
val text_size : string -> int * int

(** {1 Filling} *)

val fill_rect : int -> int -> int -> int -> unit
val fill_poly : (int * int) array -> unit
val fill_arc : int -> int -> int -> int -> int -> int -> unit
val fill_ellipse : int -> int -> int -> int -> unit
val fill_circle : int -> int -> int -> unit

(** {1 Images} *)

type image

val transp : color
(** In an image, a pixel left as it was. *)

val make_image : color array array -> image
val dump_image : image -> color array array
val draw_image : image -> int -> int -> unit
val get_image : int -> int -> int -> int -> image
val create_image : int -> int -> image
val blit_image : image -> int -> int -> unit

(** {1 Mouse and keyboard} *)

type status = {
  mouse_x : int;
  mouse_y : int;
  button : bool;
  keypressed : bool;
  key : char;
}

type event = Button_down | Button_up | Key_pressed | Mouse_motion | Poll

val wait_next_event : event list -> status
val loop_at_exit : event list -> (status -> unit) -> unit
(** At the program's end, [f] on every event of the list, until [f]
    raises [Exit]. *)

val mouse_pos : unit -> int * int
val button_down : unit -> bool
val read_key : unit -> char
val key_pressed : unit -> bool

(** {1 Sound} *)

val sound : int -> int -> unit

(** {1 Double buffering} *)

val auto_synchronize : bool -> unit
(** [false]: drawing goes to a buffer only, shown by {!synchronize};
    [true] (the default): shown as it is drawn. *)

val synchronize : unit -> unit
val display_mode : bool -> unit
val remember_mode : bool -> unit
