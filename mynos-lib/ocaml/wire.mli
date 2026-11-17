(** The wire format of typed IPC ({!Ipc}; doc/decisions/typed-ipc.md).

    A codec ['a t] both writes and reads values of type ['a]. Codecs are
    built from the ones below; reading checks everything, so a malformed
    message raises {!Error} and nothing else.

    The format, for other languages (C: [mynos_wire.h]):
    - [int]: zigzag, then LEB128 (7 bits a byte, low first, high bit set
      on all bytes but the last); a value out of range of the reader's
      [int] is an error;
    - [bool]: one byte, 0 or 1; [unit]: nothing;
    - [string]: its length as an [int], then its bytes;
    - [float]: IEEE 754 double, 8 bytes little endian;
    - [option]: a [bool], then the value if present;
    - [list], [array]: the count as an [int], then the elements;
    - tuples: their components in order;
    - variants ({!variant}): the case number as an [int], then its value;
    - [result]: case 0 [Ok], case 1 [Error]. *)

exception Error of string
(** A malformed message. *)

type 'a t
(** A codec. *)

val unit : unit t
val bool : bool t
val int : int t
val string : string t
val float : float t
val option : 'a t -> 'a option t
val list : 'a t -> 'a list t
val array : 'a t -> 'a array t
val pair : 'a t -> 'b t -> ('a * 'b) t
val triple : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
val result : 'a t -> 'b t -> ('a, 'b) result t

val conv : ('a -> 'b) -> ('b -> 'a) -> 'b t -> 'a t
(** [conv to_b of_b codec]: values of type ['a] written as ['b] (records
    as tuples, for instance). [of_b] may raise {!Error}. *)

val field : string -> 'a t -> 'a t
(** The same codec, with a name: a component of a tuple, an argument of a
    request. Only descriptions see it ({!shape}). *)

type 'a case
val case : ?name:string -> int -> 'b t -> ('b -> 'a) -> ('a -> 'b option) -> 'a case
(** [case n codec inject project]: the case number [n] of a variant, its
    value written with [codec]; [project] recognizes the variant's values
    of this case. [name] (by default the number) is for descriptions. *)

val variant : 'a case list -> 'a t
(** A variant: the first case whose [project] answers. Writing a value no
    case recognizes raises [Invalid_argument]. *)

val fix : ?name:string -> ('a t -> 'a t) -> 'a t
(** A recursive codec (trees); [name] (["t"]) names the type in its
    shape. *)

(** {2 Shapes}

    What a codec writes, as data: services describe their protocols with
    them (doc/decisions/llm.md), and a program that knows nothing of a
    protocol's OCaml types can still write its requests and read its
    replies (module {!Tools}, from JSON). *)

type shape =
  | Unit | Bool | Int | Float | String
  | Option of shape
  | List of shape                     (** lists and arrays *)
  | Tuple of shape list               (** components one after the other *)
  | Named of string * shape           (** {!field} *)
  | Variant of (int * string * shape) list   (** case number, name, value *)
  | Rec of string * shape             (** {!fix}: a recursive type... *)
  | Var of string                     (** ...and its occurrences inside *)

val shape : 'a t -> shape

val shape_codec : shape t

(** {2 Writing and reading} *)

type writer
val writer : unit -> writer
val write : writer -> 'a t -> 'a -> unit
val contents : writer -> string

type reader
val reader : string -> reader
val read : reader -> 'a t -> 'a
val at_end : reader -> bool

val to_string : 'a t -> 'a -> string
val of_string : 'a t -> string -> 'a
(** The whole string: bytes left over are an {!Error}. *)
