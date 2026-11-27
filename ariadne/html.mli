(** HTML to a {!Dom} tree.

    M0: a small tolerant parser, enough to show a page's text. M1
    replaces it with the WHATWG tokenizer and tree builder, behind this
    same interface. *)

val parse : string -> Dom.node
(** The document (a {!Dom.Document} node) of a page in UTF-8. *)

val decode_entities : string -> string
(** [&amp;], [&lt;], [&#233;], [&#xE9;]... as UTF-8 (M0: the common named
    ones only). *)

val utf8_of_code : Buffer.t -> int -> unit
(** A code point, as UTF-8. *)
