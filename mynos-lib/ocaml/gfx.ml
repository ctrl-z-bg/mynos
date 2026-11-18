(* Drawing on buffers of 32-bit pixels: see gfx.mli. *)

type t = {
  pixels : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t;
  width : int;
  height : int;
}

external alloc : int -> int -> (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t
  = "caml_gfx_alloc"
external fill : t -> int -> int -> int -> int -> int -> unit = "caml_gfx_fill_byte" "caml_gfx_fill"
external text_raw : t -> int -> int -> string -> int -> bool -> int -> int
  = "caml_gfx_text_byte" "caml_gfx_text"
external line : t -> int -> int -> int -> int -> int -> unit = "caml_gfx_line_byte" "caml_gfx_line"
external blit : t -> int -> int -> t -> int -> int -> int -> int -> unit
  = "caml_gfx_blit_byte" "caml_gfx_blit"
external get : t -> int -> int -> int = "caml_gfx_get"
external send_shared : int -> t -> unit = "caml_gfx_send_shared"
external set_clip : int -> int -> int -> int -> unit = "caml_gfx_set_clip"
external no_clip : unit -> unit = "caml_gfx_no_clip"

(* the clips in force, innermost first: each the intersection with the
   one around it *)
let clips : (int * int * int * int) list ref = ref []

let apply () = match !clips with
  | [] -> no_clip ()
  | (x, y, w, h) :: _ -> set_clip x y w h

let with_clip x y w h f =
  let x0, y0, x1, y1 = match !clips with
    | [] -> (x, y, x + w, y + h)
    | (cx, cy, cw, ch) :: _ ->
      (max x cx, max y cy, min (x + w) (cx + cw), min (y + h) (cy + ch)) in
  clips := (x0, y0, max 0 (x1 - x0), max 0 (y1 - y0)) :: !clips;
  apply ();
  Fun.protect ~finally:(fun () -> clips := List.tl !clips; apply ()) f

let clip () = match !clips with [] -> None | c :: _ -> Some c

let create width height = { pixels = alloc width height; width; height }

let char_w = 8
let char_h = 16

let text ?(bold = false) ?(max = max_int / 2) g x y s colour = text_raw g x y s colour bold max

let cells s = String.fold_left (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0 s

let rect g x y w h c =
  fill g x y w 1 c; fill g x (y + h - 1) w 1 c;
  fill g x y 1 h c; fill g (x + w - 1) y 1 h c

let rgb r g b = (r lsl 16) lor (g lsl 8) lor b

let mix a b t =
  let ch c s = (c lsr s) land 255 in
  let m s = int_of_float (float (ch a s) *. (1. -. t) +. float (ch b s) *. t) in
  rgb (m 16) (m 8) (m 0)
