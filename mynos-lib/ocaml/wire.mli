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

type 'a case
val case : int -> 'b t -> ('b -> 'a) -> ('a -> 'b option) -> 'a case
(** [case n codec inject project]: the case number [n] of a variant, its
    value written with [codec]; [project] recognizes the variant's values
    of this case. *)

val variant : 'a case list -> 'a t
(** A variant: the first case whose [project] answers. Writing a value no
    case recognizes raises [Invalid_argument]. *)

val fix : ('a t -> 'a t) -> 'a t
(** A recursive codec (trees). *)

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
