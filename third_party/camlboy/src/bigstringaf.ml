(* the part of Bigstringaf that CAMLBOY uses *)
open Bigarray
type t = (char, int8_unsigned_elt, c_layout) Array1.t
let create n = Array1.create char c_layout n
let unsafe_get (b : t) i = Array1.unsafe_get b i
let unsafe_set (b : t) i c = Array1.unsafe_set b i c
