(** The document's tree (doc/decisions/browser.md).

    Nodes are linked to their parent and their siblings, as in the DOM of
    the specifications: inserting and removing are O(1), and every walk
    over the tree is a loop, never a recursion as deep as the tree
    (the plan's rule 3). Each node has an [id], unique in the program:
    the handle by which JavaScript will name it (rule 2). *)

type kind =
  | Document
  | Doctype of { name : string; public_id : string; system_id : string }
  | Element of { name : string; mutable attrs : (string * string) list }
      (** [name] in lower case (HTML); attributes in document order,
          their names in lower case *)
  | Text of { mutable data : string }
  | Comment of { mutable data : string }

type node = private {
  id : int;
  kind : kind;
  mutable parent : node option;
  mutable first_child : node option;
  mutable last_child : node option;
  mutable prev : node option;
  mutable next : node option;
}

(** {1 Making nodes} *)

val document : unit -> node
val element : ?attrs:(string * string) list -> string -> node
val text : string -> node
val comment : string -> node
val doctype : ?public_id:string -> ?system_id:string -> string -> node

(** {1 Changing the tree} *)

val append : node -> node -> unit
(** [append parent child]: [child] (taken from where it was) as the last
    child of [parent]. *)

val insert_before : node -> node -> node option -> unit
(** [insert_before parent child reference]: before [reference], a child of
    [parent]; at the end when [None]. *)

val remove : node -> unit
(** Out of its parent; its own children stay with it. *)

(** {1 Reading it} *)

val name : node -> string
(** An element's name; [""] for the other nodes. *)

val attr : node -> string -> string option
val children : node -> node list

val walk : enter:(node -> bool) -> leave:(node -> unit) -> node -> unit
(** The subtree in document order: [enter n] before [n]'s children (which
    are skipped if it returns [false]), [leave n] after them. A loop, in
    constant stack. *)

val iter : (node -> unit) -> node -> unit
(** Every node of the subtree, in document order. *)

val find : (node -> bool) -> node -> node option
(** The first node of the subtree, in document order, that satisfies it. *)

val text_content : node -> string
(** The text of the subtree's text nodes, joined. *)

val count : node -> int
(** How many nodes the subtree has. *)
