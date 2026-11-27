(* Pictures over typed IPC: see images.mli. The service is imaged
   (services/image/imaged.c), which follows the case numbers below. *)

type _ request =
  | Decode : string * int * int -> ((int * int) * (int * int * string)) request
  | Size : string -> (int * int) request

let decode_args = Wire.(triple (field "data" string) (field "width" int) (field "height" int))
let decode_reply = Wire.(pair (pair (field "natural_width" int) (field "natural_height" int))
                          (triple (field "width" int) (field "height" int) (field "pixels" string)))
let size_reply = Wire.(pair (field "width" int) (field "height" int))
let data_f = Wire.(field "data" string)

module Protocol = struct
  let id = "image/1"
  let summary =
    "Pictures (imaged, in C, with stb_image and NanoSVG): JPEG, PNG, GIF, BMP and SVG decoded \
     and scaled, for Ariadne and any program."
  let requests = Ipc.[
      request ~safe:true 0 "decode"
        "A picture (JPEG, PNG, GIF, BMP, SVG) decoded at width x height (0 x 0: its own size; an \
         SVG drawn at it): its own size, and the pixels, 4 bytes each (blue, green, red, alpha)."
        decode_args decode_reply;
      request ~safe:true 1 "size" "A picture's own size, without decoding it." data_f size_reply ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Decode (d, x, y) -> Wire.write w Wire.int 0; Wire.write w decode_args (d, x, y)
    | Size d -> Wire.write w Wire.int 1; Wire.write w data_f d

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let d, x, y = Wire.read r decode_args in Request (Decode (d, x, y))
    | 1 -> Request (Size (Wire.read r data_f))
    | n -> raise (Wire.Error (Printf.sprintf "image: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Decode _ -> decode_reply
    | Size _ -> size_reply
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect () = I.connect "image"
let call = I.call

type picture = { natural_width : int; natural_height : int; image : Gfx.image }

let get = function Some c -> c | None -> connect ()

let size ?images data = call (get images) (Size data)

let decode ?images ?(width = 0) ?(height = 0) data =
  let c = match images with Some c -> c | None -> connect () in
  let (natural_width, natural_height), (w, h, px) = call c (Decode (data, width, height)) in
  { natural_width; natural_height; image = { Gfx.image_width = w; image_height = h; bgra = px } }
