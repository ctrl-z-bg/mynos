(* The DOM's operations for JavaScript (M6; doc/decisions/browser.md, rule
   2): a page's scripts run in jsd, and reach the nodes through integer
   handles (a node's id), an operation and string arguments at a time
   (dom/1's call (op, args) -> strings, which Ariadne serves). The API
   scripts see (document, Element, querySelector...) is JavaScript over
   these operations: Js_prelude. No input or output here: the host tests
   it. An error is [Failure], its message the script's exception. *)

(* what scripts learn of the layout (the browser's: a layout of the page
   as it is now) *)
type geometry = {
  box : Dom.node -> (int * int * int * int * int array) option;
      (* the border box on the page, and the borders' widths (top, right,
         bottom, left); None: no box (display: none) *)
  viewport : unit -> int * int * int * int * int;   (* scroll x, y; width, height; the page's height *)
  offset_parent : Dom.node -> Dom.node option;
  computed : Dom.node -> string -> string;          (* getComputedStyle's value *)
  scroll_to : int -> int -> unit;                   (* window.scrollTo *)
}

let no_geometry = {
  box = (fun _ -> None); viewport = (fun () -> (0, 0, 0, 0, 0)); offset_parent = (fun _ -> None);
  computed = (fun _ _ -> ""); scroll_to = (fun _ _ -> ());
}

type t = {
  doc : Dom.node;
  mutable geometry : geometry;
  mutable version : int;                           (* one more at each change: a layout's freshness *)
  cookies : (unit -> string) * (string -> unit);   (* document.cookie: read, set (the Loader's jar) *)
  fetch : string list -> string list;              (* a request: the browser's (fetch, XMLHttpRequest) *)
  prefetch : string -> unit;                       (* a script's src: fetched ahead, from now *)
  ready : string -> bool;                          (* ... and its answer in *)
  nodes : (int, Dom.node) Hashtbl.t;        (* the handles given out *)
  mutable changed : bool;                    (* the tree, an attribute or a text changed *)
  mutable navigation : (string * bool) option;  (* a script asked to go to a URL (replacing this page or not) *)
  mutable outbox : (string * string * string) list;
  (* messages posted to other frames, the last first: to ("parent", "top",
     "frame:" ^ an iframe's handle), the data (JSON), the target origin *)
}

let create ?(cookies = ((fun () -> ""), ignore)) ?(fetch = fun _ -> failwith "NetworkError: no network here")
    ?(prefetch = ignore) ?(ready = fun _ -> true) doc =
  let t = { doc; cookies; fetch; prefetch; ready; nodes = Hashtbl.create 256; changed = false; geometry = no_geometry; version = 0;
            navigation = None; outbox = [] } in
  Hashtbl.replace t.nodes doc.Dom.id doc;
  t

let handle t (n : Dom.node) = Hashtbl.replace t.nodes n.id n; string_of_int n.id

let node t s =
  match Option.bind (int_of_string_opt s) (Hashtbl.find_opt t.nodes) with
  | Some n -> n
  | None -> failwith ("no node " ^ s)

let fail fmt = Printf.ksprintf failwith fmt

(* ---- serializing (innerHTML, outerHTML; the HTML Standard's 13.3) ---- *)

let void_elements = [ "area"; "base"; "br"; "col"; "embed"; "hr"; "img"; "input"; "link"; "meta";
                      "source"; "track"; "wbr"; "basefont"; "bgsound"; "frame"; "keygen"; "param" ]
let raw_text = [ "style"; "script"; "xmp"; "iframe"; "noembed"; "noframes"; "plaintext" ]

let escape ~attr s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
      | '&' -> Buffer.add_string b "&amp;"
      | '<' when not attr -> Buffer.add_string b "&lt;"
      | '>' when not attr -> Buffer.add_string b "&gt;"
      | '"' when attr -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c) s;
  (* a no-break space *)
  let s = Buffer.contents b in
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if !i + 1 < n && s.[!i] = '\xc2' && s.[!i + 1] = '\xa0' then (Buffer.add_string b "&nbsp;"; i := !i + 2)
    else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

(* a node's children as HTML (a loop: Dom.walk) *)
let inner_html (root : Dom.node) =
  let b = Buffer.create 1024 in
  let raw = ref 0 in
  Dom.walk root
    ~enter:(fun n ->
        if n == root then true
        else match n.kind with
          | Element { name; attrs; _ } ->
            Buffer.add_char b '<'; Buffer.add_string b name;
            List.iter (fun (a : Dom.attr) ->
                Printf.bprintf b " %s=\"%s\"" a.name (escape ~attr:true a.value)) attrs;
            Buffer.add_char b '>';
            if List.mem name raw_text then incr raw;
            not (List.mem name void_elements)
          | Text { data } ->
            let parent_raw = match n.parent with
              | Some p -> List.mem (Dom.name p) raw_text && Dom.ns p = Some Dom.Html | None -> false in
            Buffer.add_string b (if parent_raw then data else escape ~attr:false data); false
          | Comment { data } -> Printf.bprintf b "<!--%s-->" data; false
          | Pi { target; data } -> Printf.bprintf b "<?%s %s>" target data; false
          | Doctype { name; _ } -> Printf.bprintf b "<!DOCTYPE %s>" name; false
          | Document _ | Fragment -> true)
    ~leave:(fun n ->
        if n != root then
          match n.kind with
          | Element { name; _ } when not (List.mem name void_elements) ->
            if List.mem name raw_text then decr raw;
            Printf.bprintf b "</%s>" name
          | _ -> ());
  Buffer.contents b

let outer_html (n : Dom.node) =
  match n.kind with
  | Element { name; attrs; _ } ->
    let b = Buffer.create 256 in
    Buffer.add_char b '<'; Buffer.add_string b name;
    List.iter (fun (a : Dom.attr) -> Printf.bprintf b " %s=\"%s\"" a.name (escape ~attr:true a.value)) attrs;
    Buffer.add_char b '>';
    if not (List.mem name void_elements) then begin
      Buffer.add_string b (inner_html n);
      Printf.bprintf b "</%s>" name
    end;
    Buffer.contents b
  | Text { data } -> escape ~attr:false data
  | Comment { data } -> "<!--" ^ data ^ "-->"
  | _ -> inner_html n

(* ---- queries ---- *)

let selectors s =
  match Selector.parse_list (Css.parse_values s) with
  | Some l -> l
  | None -> fail "SyntaxError: '%s' is not a valid selector" s

(* the elements under [root] (not it) that match, in document order; the
   first only, with [first] *)
let query ?(first = false) root sels =
  let out = ref [] and found = ref false in
  Dom.walk root ~leave:ignore ~enter:(fun n ->
      if !found then false
      else begin
        if n != root && (match n.kind with Element _ -> true | _ -> false) && Selector.any sels n then begin
          out := n :: !out;
          if first then found := true
        end;
        true
      end);
  List.rev !out

let is_element (n : Dom.node) = match n.kind with Element _ -> true | _ -> false

let node_type (n : Dom.node) = match n.kind with
  | Element _ -> 1 | Text _ -> 3 | Pi _ -> 7 | Comment _ -> 8 | Document _ -> 9 | Doctype _ -> 10 | Fragment -> 11

let node_name (n : Dom.node) = match n.kind with
  | Element { name; ns = Dom.Html; _ } -> String.uppercase_ascii name
  | Element { name; _ } -> name
  | Text _ -> "#text" | Comment _ -> "#comment" | Document _ -> "#document"
  | Doctype { name; _ } -> name | Fragment -> "#document-fragment" | Pi { target; _ } -> target

let set_attr (n : Dom.node) k v =
  let others = List.filter (fun (a : Dom.attr) -> a.name <> k) (Dom.attrs n) in
  (* in place, if it was there: attributes keep their order *)
  let existing = List.exists (fun (a : Dom.attr) -> a.name = k) (Dom.attrs n) in
  Dom.set_attrs n (match v with
      | Some v when existing ->
        List.map (fun (a : Dom.attr) -> if a.name = k then { a with value = v } else a) (Dom.attrs n)
      | Some v -> others @ [ { Dom.name = k; value = v; ans = Dom.No_ns } ]
      | None -> others)

let replace_children t (n : Dom.node) (nodes : Dom.node list) =
  List.iter Dom.remove (Dom.children n);
  List.iter (Dom.append n) nodes;
  t.changed <- true; t.version <- t.version + 1

(* the html, head, body elements *)
let html_element t = Dom.find (fun n -> Dom.is_html n "html") t.doc
let body t = Dom.find (fun n -> Dom.is_html n "body") t.doc
let head t = Dom.find (fun n -> Dom.is_html n "head") t.doc

(* ---- the operations ---- *)

(* nodes are answered as (handle, type, name) triples: the script makes
   its object of the right class without asking again *)
let call t op (args : string list) : string list =
  let h n = [ handle t n; string_of_int (node_type n); node_name n ] in
  let opt = function Some n -> h n | None -> [] in
  let many l = List.concat_map h l in
  let changed () = t.changed <- true; t.version <- t.version + 1 in
  match op, args with
  | "document", [] -> h t.doc
  | "documentElement", [] -> opt (html_element t)
  | "body", [] -> opt (body t)
  | "head", [] -> opt (head t)
  | "byId", [ id ] ->
    opt (Dom.find (fun n -> is_element n && Dom.attr n "id" = Some id) t.doc)
  | "query", [ root; sel ] -> many (query ~first:true (node t root) (selectors sel))
  | "queryAll", [ root; sel ] -> many (query (node t root) (selectors sel))
  | "byTag", [ root; tag ] ->
    let tag = String.lowercase_ascii tag in
    many (query (node t root) (selectors (if tag = "*" then "*" else tag)))
  | "byClass", [ root; cls ] ->
    let names = List.filter (fun c -> c <> "") (String.split_on_char ' ' cls) in
    let out = ref [] in
    Dom.walk (node t root) ~leave:ignore ~enter:(fun n ->
        if is_element n && n != node t root && List.for_all (fun c -> List.mem c (Dom.classes n)) names then
          out := n :: !out;
        true);
    many (List.rev !out)
  | "matches", [ n; sel ] -> [ if Selector.any (selectors sel) (node t n) then "1" else "0" ]
  | "closest", [ n; sel ] ->
    let sels = selectors sel in
    let rec up (x : Dom.node) =
      if is_element x && Selector.any sels x then Some x
      else match x.parent with Some p -> up p | None -> None in
    opt (up (node t n))
  | "info", [ n ] -> let n = node t n in [ string_of_int (node_type n); node_name n ]
  | "parent", [ n ] -> opt (node t n).parent
  | "children", [ n ] -> many (Dom.children (node t n))
  | "elements", [ n ] -> many (List.filter is_element (Dom.children (node t n)))
  | "next", [ n ] -> opt (node t n).next
  | "prev", [ n ] -> opt (node t n).prev
  | "getAttr", [ n; k ] -> (match Dom.attr (node t n) (String.lowercase_ascii k) with Some v -> [ v ] | None -> [])
  | "setAttr", [ n; k; v ] -> set_attr (node t n) (String.lowercase_ascii k) (Some v); changed (); []
  | "removeAttr", [ n; k ] -> set_attr (node t n) (String.lowercase_ascii k) None; changed (); []
  | "attrNames", [ n ] -> List.map (fun (a : Dom.attr) -> a.name) (Dom.attrs (node t n))
  | "text", [ n ] ->
    let n = node t n in
    (match n.kind with
     | Text { data } | Comment { data } -> [ data ]
     | Document _ -> []
     | _ -> [ Dom.text_content n ])
  | "setText", [ n; s ] ->
    let n = node t n in
    (match n.kind with
     | Text r -> r.data <- s; changed ()
     | Comment r -> r.data <- s
     | _ -> replace_children t n (if s = "" then [] else [ Dom.text s ]));
    []
  | "html", [ n ] -> [ inner_html (node t n) ]
  | "outerHtml", [ n ] -> [ outer_html (node t n) ]
  | "setHtml", [ n; s ] ->
    let n = node t n in
    let frag = Html.parse_fragment ~context:n s in
    replace_children t n (Dom.children frag); []
  | "insertHtml", [ n; where; s ] ->
    (* insertAdjacentHTML *)
    let n = node t n in
    let context = match where with "beforebegin" | "afterend" -> Option.value n.parent ~default:n | _ -> n in
    let nodes = Dom.children (Html.parse_fragment ~context s) in
    (match String.lowercase_ascii where with
     | "beforebegin" -> Option.iter (fun p -> List.iter (fun c -> Dom.insert_before p c (Some n)) nodes) n.parent
     | "afterbegin" -> let first = n.first_child in List.iter (fun c -> Dom.insert_before n c first) nodes
     | "beforeend" -> List.iter (Dom.append n) nodes
     | "afterend" -> Option.iter (fun p -> let next = n.next in List.iter (fun c -> Dom.insert_before p c next) nodes) n.parent
     | w -> fail "SyntaxError: '%s' is not a position" w);
    changed (); []
  | "create", [ name ] -> h (Dom.element (String.lowercase_ascii name))
  | "createText", [ s ] -> h (Dom.text s)
  | "createComment", [ s ] -> h (Dom.comment s)
  | "createFragment", [] -> h (Dom.fragment ())
  | "insert", [ p; c; before ] ->
    let p = node t p and c = node t c in
    let before = if before = "" then None else Some (node t before) in
    (* an ancestor cannot go inside its descendant *)
    let rec inside (x : Dom.node) = x == c || (match x.parent with Some q -> inside q | None -> false) in
    if inside p then fail "HierarchyRequestError: the new child contains the parent";
    (match before with
     | Some b when not (match b.parent with Some q -> q == p | None -> false) ->
       fail "NotFoundError: the reference is not a child"
     | _ -> ());
    (* a fragment's children move, not the fragment *)
    (match c.kind with
     | Fragment -> List.iter (fun x -> Dom.insert_before p x before) (Dom.children c)
     | _ -> Dom.insert_before p c before);
    changed (); []
  | "remove", [ n ] -> Dom.remove (node t n); changed (); []
  | "value", [ n ] -> [ Forms.value (node t n) ]
  | "setValue", [ n; v ] -> Forms.set_value (node t n) v; []
  | "checked", [ n ] -> [ if Forms.checked (node t n) then "1" else "0" ]
  | "setChecked", [ n; v ] ->
    let n = node t n in
    if v = "1" && Forms.kind n = Forms.Radio then (Forms.toggle n) else Forms.set_checked n (v = "1"); []
  | "title", [] ->
    (match Dom.find (fun n -> Dom.is_html n "title") t.doc with
     | Some n -> [ String.trim (Text.collapse (Dom.text_content n)) ] | None -> [ "" ])
  | "setTitle", [ s ] ->
    (match Dom.find (fun n -> Dom.is_html n "title") t.doc with
     | Some n -> replace_children t n [ Dom.text s ]
     | None -> Option.iter (fun hd -> let ti = Dom.element "title" in Dom.append ti (Dom.text s); Dom.append hd ti) (head t));
    []
  | "fetch", args -> t.fetch args
  | "box", [ n ] ->
    (match t.geometry.box (node t n) with
     | Some (x, y, w, h, b) -> List.map string_of_int ([ x; y; w; h ] @ Array.to_list b)
     | None -> [])
  | "viewport", [] ->
    let sx, sy, w, h, ph = t.geometry.viewport () in List.map string_of_int [ sx; sy; w; h; ph ]
  | "offsetParent", [ n ] -> opt (t.geometry.offset_parent (node t n))
  | "computed", [ n; prop ] -> [ t.geometry.computed (node t n) (String.lowercase_ascii prop) ]
  | "scrollTo", [ x; y ] ->
    t.geometry.scroll_to (Option.value (int_of_string_opt x) ~default:0) (Option.value (int_of_string_opt y) ~default:0); []
  | "navigate", [ url; replace ] -> t.navigation <- Some (url, replace = "1"); []
  | "postMessage", [ target; data; origin ] ->
    if List.length t.outbox < 200 then t.outbox <- (target, data, origin) :: t.outbox; []
  | "prefetch", [ url ] -> t.prefetch url; []
  | "ready", [ url ] -> [ (if t.ready url then "1" else "0") ]
  | "cookie", [] -> [ (fst t.cookies) () ]
  | "setCookie", [ c ] -> (snd t.cookies) c; []
  | op, args -> fail "no DOM operation %s/%d" op (List.length args)
