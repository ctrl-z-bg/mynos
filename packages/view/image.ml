(* Image: a picture in memory, as view and paint use it: its pixels are
   0xRRGGBB, row by row. *)

type t = { width : int; height : int; pixels : int array }

let create width height colour = { width; height; pixels = Array.make (width * height) colour }

exception Bad of string
let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt
