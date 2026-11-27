(** Pictures, over typed IPC with the service [image] (imaged,
    services/image, in C with stb_image and NanoSVG): JPEG, PNG, GIF (the
    first frame), BMP and SVG decoded, at their own size or scaled. Protocol
    ["image/1"]. The pixels come as {!Gfx.draw_image} draws them.

    {[
      let p = Images.decode (In_channel.with_open_bin "/disk/a.png" In_channel.input_all) in
      Gfx.draw_image g 10 10 p.Images.image
    ]} *)

type _ request =
  | Decode : string * int * int -> ((int * int) * (int * int * string)) request
      (** [(data, width, height)] (0, 0: its own size): its own size, then
          the pixels' width, height and bytes *)
  | Size : string -> (int * int) request
      (** a picture's own size, without decoding it *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : unit -> t
(** The picture service; [Mynos.Error] if there is none. *)

val call : t -> 'a request -> 'a

type picture = {
  natural_width : int;
  natural_height : int;   (** the picture's own size *)
  image : Gfx.image;      (** its pixels, at the size asked for *)
}

val decode : ?images:t -> ?width:int -> ?height:int -> string -> picture
(** A picture's bytes decoded, at [width] x [height] (by default its own
    size). [Ipc.Remote_error] if it is not a picture imaged reads. *)

val size : ?images:t -> string -> int * int
(** A picture's own size, without decoding it. *)
