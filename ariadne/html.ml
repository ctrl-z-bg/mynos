(* HTML to a Dom tree: see html.mli. *)

let parse text = Treebuilder.parse_document text

let parse_bytes ?charset bytes =
  let e, text = Encoding.to_utf8 ?transport:charset bytes in
  (parse text, e)

let parse_fragment ~context text = Treebuilder.parse_fragment ~context text
