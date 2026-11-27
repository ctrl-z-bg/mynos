(** HTML to a {!Dom} tree: the HTML Standard's parser ({!Encoding},
    {!Tokenizer}, {!Treebuilder}). *)

val parse : string -> Dom.node
(** A document (a {!Dom.Document} node) from its text in UTF-8. *)

val parse_bytes : ?charset:string -> string -> Dom.node * Encoding.t
(** A document from its bytes: the encoding found (the byte order mark,
    the HTTP header's [charset], a [<meta>], or a guess) and used. *)

val parse_fragment : context:Dom.node -> string -> Dom.node
(** The fragment parsing algorithm ([innerHTML]): the nodes, in a
    {!Dom.Fragment}, that the text makes inside an element like
    [context]. *)
