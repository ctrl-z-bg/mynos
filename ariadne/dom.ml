(* The document's tree: see dom.mli. *)

type kind =
  | Document
  | Doctype of { name : string; public_id : string; system_id : string }
  | Element of { name : string; mutable attrs : (string * string) list }
  | Text of { mutable data : string }
  | Comment of { mutable data : string }

type node = {
  id : int;
  kind : kind;
  mutable parent : node option;
  mutable first_child : node option;
  mutable last_child : node option;
  mutable prev : node option;
  mutable next : node option;
}

let next_id = ref 0

let make kind =
  incr next_id;
  { id = !next_id; kind; parent = None; first_child = None; last_child = None;
    prev = None; next = None }

let document () = make Document
let element ?(attrs = []) name = make (Element { name; attrs })
let text data = make (Text { data })
let comment data = make (Comment { data })
let doctype ?(public_id = "") ?(system_id = "") name =
  make (Doctype { name; public_id; system_id })

let remove n =
  (match n.parent with
   | None -> ()
   | Some p ->
     (match n.prev with Some s -> s.next <- n.next | None -> p.first_child <- n.next);
     (match n.next with Some s -> s.prev <- n.prev | None -> p.last_child <- n.prev));
  n.parent <- None; n.prev <- None; n.next <- None

let insert_before parent child reference =
  remove child;
  child.parent <- Some parent;
  match reference with
  | None ->
    child.prev <- parent.last_child;
    (match parent.last_child with Some l -> l.next <- Some child | None -> parent.first_child <- Some child);
    parent.last_child <- Some child
  | Some r ->
    child.next <- Some r;
    child.prev <- r.prev;
    (match r.prev with Some p -> p.next <- Some child | None -> parent.first_child <- Some child);
    r.prev <- Some child

let append parent child = insert_before parent child None

let name n = match n.kind with Element e -> e.name | _ -> ""

let attr n a = match n.kind with Element e -> List.assoc_opt a e.attrs | _ -> None

let children n =
  let rec go acc = function None -> List.rev acc | Some c -> go (c :: acc) c.next in
  go [] n.first_child

(* down to the first child, else across to the next sibling, else up and
   across: tail calls only, so the stack stays flat however deep the tree *)
let walk ~enter ~leave root =
  let rec down n =
    match (if enter n then n.first_child else None) with
    | Some c -> down c
    | None -> up n
  and up n =
    leave n;
    if n != root then
      match n.next with
      | Some s -> down s
      | None -> (match n.parent with Some p -> up p | None -> ())
  in
  down root

let iter f root = walk ~enter:(fun n -> f n; true) ~leave:ignore root

exception Found of node

let find p root =
  match iter (fun n -> if p n then raise (Found n)) root with
  | () -> None
  | exception Found n -> Some n

let text_content root =
  let b = Buffer.create 256 in
  iter (fun n -> match n.kind with Text t -> Buffer.add_string b t.data | _ -> ()) root;
  Buffer.contents b

let count root =
  let k = ref 0 in
  iter (fun _ -> incr k) root;
  !k
