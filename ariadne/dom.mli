(** The document's tree (doc/decisions/browser.md).

    Nodes are linked to their parent and their siblings, as in the DOM of
    the specifications: inserting and removing are O(1), and every walk
    over the tree is a loop, never a recursion as deep as the tree
    (the plan's rule 3). Each node has an [id], unique in the program:
    the handle by which JavaScript will name it (rule 2). *)

type ns = Html | Svg | Mathml
(** An element's namespace *)

type attr_ns = No_ns | Xlink | Xml | Xmlns
(** An attribute's namespace: only the attributes of SVG and MathML
    elements the parser adjusts ([xlink:href], [xml:lang], [xmlns]...)
    have one *)

type attr = { name : string; value : string; ans : attr_ns }
(** [name]: the qualified name, as [getAttribute] knows it ([xlink:href]);
    in lower case on HTML elements *)

type quirks = No_quirks | Quirks | Limited_quirks

type kind =
  | Document of { mutable quirks : quirks }
  | Fragment                (** a document fragment: a template's contents, a parsed fragment *)
  | Doctype of { name : string; public_id : string; system_id : string }
  | Element of { name : string; ns : ns; mutable attrs : attr list }
      (** [name]: the local name, in lower case for HTML elements, with
          SVG's camel case where the specification adjusts it *)
  | Text of { mutable data : string }
  | Comment of { mutable data : string }
  | Pi of { target : string; mutable data : string }   (* a processing instruction *)

type node = private {
  id : int;
  kind : kind;
  mutable parent : node option;
  mutable first_child : node option;
  mutable last_child : node option;
  mutable prev : node option;
  mutable next : node option;
  mutable content : node option;   (** a template's contents (a [Fragment]) *)
}

(** {1 Making nodes} *)

val document : unit -> node
val fragment : unit -> node
val element : ?ns:ns -> ?attrs:(string * string) list -> string -> node
val element_with : ns -> string -> attr list -> node
val text : string -> node
val comment : string -> node
val pi : string -> string -> node
(** [pi target data]: a processing instruction *)
val doctype : ?public_id:string -> ?system_id:string -> string -> node
val set_content : node -> node -> unit
(** [set_content template fragment] *)

(** {1 Changing the tree} *)

val append : node -> node -> unit
(** [append parent child]: [child] (taken from where it was) as the last
    child of [parent]. *)

val insert_before : node -> node -> node option -> unit
(** [insert_before parent child reference]: before [reference], a child of
    [parent]; at the end when [None]. *)

val remove : node -> unit
(** Out of its parent; its own children stay with it. *)

val set_attrs : node -> attr list -> unit
val set_quirks : node -> quirks -> unit

(** {1 Reading it} *)

val name : node -> string
(** An element's local name; [""] for the other nodes. *)

val ns : node -> ns option
(** An element's namespace; [None] for the other nodes. *)

val is_html : node -> string -> bool
(** [is_html n "p"]: [n] is an HTML element named [p]. *)

val attr : node -> string -> string option
val attrs : node -> attr list
val children : node -> node list

val walk : enter:(node -> bool) -> leave:(node -> unit) -> node -> unit
(** The subtree in document order: [enter n] before [n]'s children (which
    are skipped if it returns [false]), [leave n] after them. A loop, in
    constant stack. A template's contents are not part of the walk. *)

val iter : (node -> unit) -> node -> unit
(** Every node of the subtree, in document order. *)

val find : (node -> bool) -> node -> node option
(** The first node of the subtree, in document order, that satisfies it. *)

val text_content : node -> string
(** The text of the subtree's text nodes, joined. *)

val count : node -> int
(** How many nodes the subtree has. *)
