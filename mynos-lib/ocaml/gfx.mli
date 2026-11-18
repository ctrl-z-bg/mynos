(** Drawing on buffers of 32-bit pixels (doc/decisions/gui.md). The
    primitives are in C (mynos-runtime/gfx_stubs.c): OCaml bytecode is too
    slow for loops over pixels. Colours are [0xRRGGBB]. Text is UTF-8, in
    the Terminus 8x16 font: a character is a cell of {!char_w} x {!char_h}
    pixels.

    {[
      let g = Gfx.create 200 100 in
      Gfx.fill g 0 0 200 100 0x1B3A57;
      ignore (Gfx.text g 10 10 "Ciao, MyNOS" 0xFFFFFF)
    ]} *)

type t = private {
  pixels : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t;
  width : int;
  height : int;
}

val create : int -> int -> t
(** [create width height], white. Its pixels are page aligned, so that a
    window can share them with the display ({!Display}). *)

val char_w : int
val char_h : int

val fill : t -> int -> int -> int -> int -> int -> unit
(** [fill g x y w h colour]; clipped to the buffer. *)

val text : ?bold:bool -> ?max:int -> t -> int -> int -> string -> int -> int
(** [text g x y s colour]: [s] with its top left at [(x, y)], at most
    [max] cells: the cells written. *)

val cells : string -> int
(** The cells of a UTF-8 string (its characters). *)

val line : t -> int -> int -> int -> int -> int -> unit
(** [line g x0 y0 x1 y1 colour]. *)

val blit : t -> int -> int -> t -> int -> int -> int -> int -> unit
(** [blit src sx sy dst dx dy w h]; [src] and [dst] may be the same
    buffer (scrolling). *)

val with_clip : int -> int -> int -> int -> (unit -> 'a) -> 'a
(** [with_clip x y w h f]: [f ()], every primitive drawing only inside
    the rectangle (within the clip around it, if any). *)

val clip : unit -> (int * int * int * int) option
(** The clip in force: [(x, y, w, h)]. *)

val get : t -> int -> int -> int
(** The pixel's colour; -1 outside. *)

val rect : t -> int -> int -> int -> int -> int -> unit
(** [rect g x y w h colour]: its outline. *)

val rgb : int -> int -> int -> int
val mix : int -> int -> float -> int
(** [mix a b t]: from [a] (0.) to [b] (1.). *)

val send_shared : int -> t -> unit
(** Send the pixels on an IPC channel, shared: the receiver sees the same
    memory from then on. *)

(** {2 Masks}

    A grey image drawn as ink of one colour: black is the ink, white the
    paper (left as it was), greys in between. The same drawing serves on a
    light background and on a dark one (the MyNOS logo, /mynos-logo.pgm). *)

type mask = { mask_width : int; mask_height : int; grey : string }
(** [grey]: one byte a pixel, row by row; 0 is the ink. *)

val load_mask : string -> mask
(** A PGM file (binary, P5, 8 bits). @raise Failure if it is not one. *)

val mask_of_pgm : string -> mask

val draw_mask : ?opacity:int -> t -> int -> int -> mask -> int -> unit
(** [draw_mask g x y m colour]: the mask's top left at [(x, y)], each pixel
    taking [colour] as much as it has ink, times [opacity] (0-255, 255 by
    default); within the clip. *)

