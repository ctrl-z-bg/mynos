(** JSON (RFC 8259), for the web's APIs ({!Http}).

    {[
      let v = Json.of_string {|{"name": "MyNOS", "year": 2002}|};;
      Json.(member "year" v |> to_int);;          (* 2002 *)
      Json.to_string (Json.Object [ "ok", Json.Bool true ]);;
    ]}

    Strings are UTF-8; [\u] escapes are decoded to UTF-8. *)

type t =
  | Null
  | Bool of bool
  | Number of float
  | String of string
  | Array of t list
  | Object of (string * t) list

exception Error of string
(** Malformed text, or a value of another kind than asked. *)

val of_string : string -> t
val to_string : t -> string
(** Compact: no spaces. Integral numbers are written without a fraction. *)

val member : string -> t -> t
(** A field of an object; [Null] when it is not there.
    @raise Error if the value is not an object. *)

val index : int -> t -> t
(** An element of an array. @raise Error when there is none. *)

val to_string_value : t -> string
val to_int : t -> int
val to_float : t -> float
val to_bool : t -> bool
val to_list : t -> t list
(** The value of a [String], a [Number], a [Bool], an [Array].
    @raise Error for another kind of value. *)
