(* The document's tree: see dom.mli. *)

type ns = Html | Svg | Mathml
type attr_ns = No_ns | Xlink | Xml | Xmlns
type attr = { name : string; value : string; ans : attr_ns }
type quirks = No_quirks | Quirks | Limited_quirks

type kind =
  | Document of { mutable quirks : quirks }
  | Fragment
  | Doctype of { name : string; public_id : string; system_id : string }
  | Element of { name : string; ns : ns; mutable attrs : attr list }
  | Text of { mutable data : string }
  | Comment of { mutable data : string }
  | Pi of { target : string; mutable data : string }   (* a processing instruction *)

type node = {
  id : int;
  kind : kind;
  mutable parent : node option;
  mutable first_child : node option;
  mutable last_child : node option;
  mutable prev : node option;
  mutable next : node option;
  mutable content : node option;
  mutable cls : string list option;   (* the class attribute, split: a cache *)
}

let next_id = ref 0

let make kind =
  incr next_id;
  { id = !next_id; kind; parent = None; first_child = None; last_child = None;
    prev = None; next = None; content = None; cls = None }

let document () = make (Document { quirks = No_quirks })
let fragment () = make Fragment
let element_with ns name attrs = make (Element { name; ns; attrs })
let element ?(ns = Html) ?(attrs = []) name =
  element_with ns name (List.map (fun (name, value) -> { name; value; ans = No_ns }) attrs)
let text data = make (Text { data })
let comment data = make (Comment { data })
let pi target data = make (Pi { target; data })
let doctype ?(public_id = "") ?(system_id = "") name =
  make (Doctype { name; public_id; system_id })
let set_content t f = t.content <- Some f

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

let set_attrs n a = match n.kind with Element e -> e.attrs <- a; n.cls <- None | _ -> ()
let set_quirks n q = match n.kind with Document d -> d.quirks <- q | _ -> ()

let name n = match n.kind with Element e -> e.name | _ -> ""
let ns n = match n.kind with Element e -> Some e.ns | _ -> None
let is_html n nm = match n.kind with Element e -> e.ns = Html && e.name = nm | _ -> false

let attrs n = match n.kind with Element e -> e.attrs | _ -> []

let attr n a =
  match n.kind with
  | Element e -> (match List.find_opt (fun (x : attr) -> x.name = a) e.attrs with
      | Some x -> Some x.value | None -> None)
  | _ -> None

(* the class attribute's names, split once and kept *)
let classes n =
  match n.cls with
  | Some c -> c
  | None ->
    let c = match attr n "class" with
      | Some v ->
        List.filter (fun x -> x <> "")
          (String.split_on_char ' ' (String.map (fun ch ->
               if ch = '\t' || ch = '\n' || ch = '\r' || ch = '\012' then ' ' else ch) v))
      | None -> [] in
    n.cls <- Some c;
    c

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
