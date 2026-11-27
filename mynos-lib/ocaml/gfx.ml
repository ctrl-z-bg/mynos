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
external draw_mask_raw : t -> int -> int -> string -> int -> int -> int -> int -> unit
  = "caml_gfx_draw_mask_byte" "caml_gfx_draw_mask"
external draw_image_raw : t -> int -> int -> string -> int -> int -> int -> unit
  = "caml_gfx_draw_image_byte" "caml_gfx_draw_image"
external set_clip : int -> int -> int -> int -> unit = "caml_gfx_set_clip"
external no_clip : unit -> unit = "caml_gfx_no_clip"

(* the clips in force, innermost first: each the intersection with the
   one around it. Each domain has its own (as the C side has, per thread):
   a domain drawing a window does not clip another's drawing *)
let clips_key : (int * int * int * int) list ref Domain.DLS.key =
  Domain.DLS.new_key (fun () -> ref [])

let apply () = let clips = Domain.DLS.get clips_key in match !clips with
  | [] -> no_clip ()
  | (x, y, w, h) :: _ -> set_clip x y w h

let with_clip x y w h f =
  let clips = Domain.DLS.get clips_key in
  let x0, y0, x1, y1 = match !clips with
    | [] -> (x, y, x + w, y + h)
    | (cx, cy, cw, ch) :: _ ->
      (max x cx, max y cy, min (x + w) (cx + cw), min (y + h) (cy + ch)) in
  clips := (x0, y0, max 0 (x1 - x0), max 0 (y1 - y0)) :: !clips;
  apply ();
  Fun.protect ~finally:(fun () -> clips := List.tl !clips; apply ()) f

let clip () = match !(Domain.DLS.get clips_key) with [] -> None | c :: _ -> Some c

let create width height = { pixels = alloc width height; width; height }

let char_w = 8
let char_h = 16

(* a tab, to the next multiple of 8 cells from the string's start (the
   font has no glyph for it: it showed as a diamond, mynos-1cz) *)
let expand_tabs s =
  if not (String.contains s '\t') then s
  else begin
    let b = Buffer.create (String.length s + 16) and col = ref 0 in
    String.iter (fun c ->
        if c = '\t' then begin
          let n = 8 - !col mod 8 in
          Buffer.add_string b (String.make n ' '); col := !col + n
        end else begin
          Buffer.add_char b c;
          if Char.code c land 0xC0 <> 0x80 then incr col
        end) s;
    Buffer.contents b
  end

let text ?(bold = false) ?(max = max_int / 2) g x y s colour =
  text_raw g x y (expand_tabs s) colour bold max

let cells s =
  String.fold_left (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0
    (expand_tabs s)

let rect g x y w h c =
  fill g x y w 1 c; fill g x (y + h - 1) w 1 c;
  fill g x y 1 h c; fill g (x + w - 1) y 1 h c

let rgb r g b = (r lsl 16) lor (g lsl 8) lor b

let mix a b t =
  let ch c s = (c lsr s) land 255 in
  let m s = int_of_float (float (ch a s) *. (1. -. t) +. float (ch b s) *. t) in
  rgb (m 16) (m 8) (m 0)

(* masks: grey images, drawn as ink of one colour *)
type mask = { mask_width : int; mask_height : int; grey : string }

let mask_of_pgm data =
  (* P5, then width, height and the maximum (255), each after blanks or
     comments, then one byte a pixel *)
  let n = String.length data in
  let pos = ref 2 in
  let rec blank () =
    if !pos < n then
      match data.[!pos] with
      | ' ' | '\t' | '\n' | '\r' -> incr pos; blank ()
      | '#' -> while !pos < n && data.[!pos] <> '\n' do incr pos done; blank ()
      | _ -> () in
  let number () =
    blank ();
    let start = !pos in
    while !pos < n && data.[!pos] >= '0' && data.[!pos] <= '9' do incr pos done;
    match int_of_string_opt (String.sub data start (!pos - start)) with
    | Some v -> v
    | None -> failwith "Gfx.load_mask: not a PGM" in
  if n < 2 || String.sub data 0 2 <> "P5" then failwith "Gfx.load_mask: not a PGM (P5)";
  let w = number () in
  let h = number () in
  if number () <> 255 then failwith "Gfx.load_mask: not 8 bits";
  incr pos;                                   (* the one blank after it *)
  if n - !pos < w * h then failwith "Gfx.load_mask: cut";
  { mask_width = w; mask_height = h; grey = String.sub data !pos (w * h) }

let load_mask path = mask_of_pgm (In_channel.with_open_bin path In_channel.input_all)

let draw_mask ?(opacity = 255) g x y m colour =
  draw_mask_raw g x y m.grey m.mask_width m.mask_height colour (max 0 (min 255 opacity))


(* pictures: 4 bytes a pixel, blue, green, red, alpha *)
type image = { image_width : int; image_height : int; bgra : string }

let draw_image ?(opacity = 255) g x y i =
  draw_image_raw g x y i.bgra i.image_width i.image_height (max 0 (min 255 opacity))
