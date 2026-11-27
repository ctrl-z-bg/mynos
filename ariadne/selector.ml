(* Selectors Level 4, as far as Ariadne needs them: parsed from CSS
   component values (Css), matched right to left against Dom elements, with
   their specificity and the key the cascade indexes rules by.

   Dynamic pseudo-classes (:hover, :focus, :visited...) are valid and never
   match yet. A selector with a pseudo-element (::before...) is valid but
   applies to no element, until generated content exists. An unknown
   pseudo-class or pseudo-element makes the selector invalid, and its rule
   is dropped, as the specification says. *)

open Css

type attr_op = Exists | Equals | Includes | Dash | Prefix | Suffix | Substring

type simple =
  | Universal
  | Type of string                         (* lower case *)
  | Id of string
  | Class of string
  | Attr of string * attr_op * string * bool   (* name (lower case), op, value, case-insensitive *)
  | Root | First_child | Last_child | Only_child
  | First_of_type | Last_of_type | Only_of_type
  | Nth_child of int * int * complex list option * bool   (* a, b, "of S", from the end *)
  | Nth_of_type of int * int * bool
  | Not of complex list
  | Is of complex list                     (* :is :matches :any *)
  | Where of complex list
  | Has of (combinator * complex) list
  | Empty | Link | Checked | Disabled | Enabled | Defined
  | Never                                  (* :hover, :focus...: no state yet *)
  | Anchor                                 (* :has's subject, while it is matched *)
  | Pseudo_element of string

and combinator = Descendant | Child | Next | Subsequent

(* compounds left to right; combs.(i) is between compounds i and i + 1 *)
and complex = { comps : simple list array; combs : combinator array }

exception Invalid

(* ---- parsing ---- *)

let lower = String.lowercase_ascii

(* An+B, from its text ("2n+1", "odd", "-n + 3") *)
let parse_anb text =
  let t = lower (String.concat "" (String.split_on_char ' ' text)) in
  match t with
  | "odd" -> (2, 1)
  | "even" -> (2, 0)
  | _ ->
    match String.index_opt t 'n' with
    | None -> (match int_of_string_opt t with Some b -> (0, b) | None -> raise Invalid)
    | Some i ->
      let a = match String.sub t 0 i with
        | "" | "+" -> 1 | "-" -> -1
        | s -> (match int_of_string_opt s with Some a -> a | None -> raise Invalid) in
      let rest = String.sub t (i + 1) (String.length t - i - 1) in
      let b = if rest = "" then 0
        else match int_of_string_opt (if rest.[0] = '+' then String.sub rest 1 (String.length rest - 1) else rest) with
          | Some b -> b | None -> raise Invalid in
      (a, b)

let rec parse_complex_list ?(forgiving = false) (cvs : cv list) : complex list =
  (* split at top-level commas *)
  let rec split acc cur = function
    | [] -> List.rev (List.rev cur :: acc)
    | Tok Comma :: r -> split (List.rev cur :: acc) [] r
    | c :: r -> split acc (c :: cur) r in
  let parts = split [] [] cvs in
  if forgiving then List.filter_map (fun p -> try Some (parse_complex p) with Invalid -> None) parts
  else List.map parse_complex parts

and parse_complex (cvs : cv list) : complex =
  let cvs = Css.trim cvs in
  if cvs = [] then raise Invalid;
  let comps = ref [] and combs = ref [] and cur = ref [] in
  let pending = ref None in       (* a combinator read, waiting for its compound *)
  let push_simple s =
    (match !pending with
     | Some c ->
       if !cur = [] && !comps = [] then raise Invalid;
       if !cur <> [] then (comps := List.rev !cur :: !comps; cur := []);
       combs := c :: !combs; pending := None
     | None -> ());
    cur := s :: !cur in
  let combinator c =
    if !cur = [] && !pending = None then raise Invalid;
    (match !pending with Some Descendant | None -> pending := Some c | Some _ -> raise Invalid) in
  let rec go = function
    | [] -> ()
    | Tok Whitespace :: r ->
      if !cur <> [] && !pending = None then pending := Some Descendant;
      go r
    | Tok (Delim ">") :: r -> combinator Child; go r
    | Tok (Delim "+") :: r -> combinator Next; go r
    | Tok (Delim "~") :: r -> combinator Subsequent; go r
    | Tok (Delim "*") :: r -> push_simple Universal; go r
    | Tok (Ident name) :: r -> push_simple (Type (lower name)); go r
    | Tok (Hash (id, true)) :: r -> push_simple (Id id); go r
    | Tok (Delim ".") :: Tok (Ident c) :: r -> push_simple (Class c); go r
    | Block ('[', inner) :: r -> push_simple (attribute inner); go r
    | Tok Colon :: Tok Colon :: Tok (Ident pe) :: r -> push_simple (pseudo_element (lower pe)); go r
    | Tok Colon :: Tok (Ident pc) :: r -> push_simple (pseudo_class (lower pc)); go r
    | Tok Colon :: Func (f, args) :: r -> push_simple (pseudo_function f args); go r
    | _ -> raise Invalid in
  go cvs;
  if !pending <> None && !pending <> Some Descendant then raise Invalid;
  if !cur = [] then raise Invalid;
  comps := List.rev !cur :: !comps;
  { comps = Array.of_list (List.rev !comps); combs = Array.of_list (List.rev !combs) }

and attribute inner =
  match List.filter (fun c -> c <> Tok Whitespace) inner with
  | [ Tok (Ident name) ] -> Attr (lower name, Exists, "", false)
  | Tok (Ident name) :: rest ->
    let op, rest = match rest with
      | Tok (Delim "=") :: r -> (Equals, r)
      | Tok (Delim d) :: Tok (Delim "=") :: r ->
        ((match d with "~" -> Includes | "|" -> Dash | "^" -> Prefix | "$" -> Suffix
                     | "*" -> Substring | _ -> raise Invalid), r)
      | _ -> raise Invalid in
    let value, rest = match rest with
      | Tok (Ident v) :: r | Tok (String v) :: r -> (v, r)
      | _ -> raise Invalid in
    let ci = match rest with
      | [] -> false
      | [ Tok (Ident f) ] when lower f = "i" -> true
      | [ Tok (Ident f) ] when lower f = "s" -> false
      | _ -> raise Invalid in
    Attr (lower name, op, (if ci then lower value else value), ci)
  | _ -> raise Invalid

and pseudo_element = function
  | "before" | "after" | "marker" | "placeholder" | "selection" | "first-line" | "first-letter"
  | "backdrop" | "file-selector-button" | "cue" | "target-text" | "spelling-error"
  | "grammar-error" as p -> Pseudo_element p
  | _ -> raise Invalid

and pseudo_class = function
  | "root" -> Root
  | "first-child" -> First_child | "last-child" -> Last_child | "only-child" -> Only_child
  | "first-of-type" -> First_of_type | "last-of-type" -> Last_of_type | "only-of-type" -> Only_of_type
  | "empty" -> Empty
  | "link" | "any-link" -> Link
  | "checked" -> Checked
  | "disabled" -> Disabled | "enabled" -> Enabled
  | "defined" -> Defined
  | "scope" -> Root
  | "hover" | "focus" | "focus-within" | "focus-visible" | "active" | "visited" | "target"
  | "target-within" | "placeholder-shown" | "autofill" | "invalid" | "valid" | "user-invalid"
  | "user-valid" | "required" | "optional" | "read-only" | "read-write" | "indeterminate"
  | "default" | "in-range" | "out-of-range" | "fullscreen" | "modal" | "popover-open"
  | "playing" | "paused" | "open" | "closed" | "picture-in-picture" | "blank" | "current"
  | "past" | "future" | "local-link" | "host" | "muted" | "seeking" | "buffering" | "stalled"
  | "volume-locked" -> Never
  (* the old single-colon pseudo-elements *)
  | "before" | "after" | "first-line" | "first-letter" as p -> Pseudo_element p
  | _ -> raise Invalid

and pseudo_function f args =
  match f with
  | "not" -> Not (parse_complex_list args)
  | "is" | "matches" | "-webkit-any" | "-moz-any" -> Is (parse_complex_list ~forgiving:true args)
  | "where" -> Where (parse_complex_list ~forgiving:true args)
  | "has" -> Has (relative_list args)
  | "nth-child" | "nth-last-child" ->
    (* "An+B" or "An+B of S" *)
    let rec split acc = function
      | Tok Whitespace :: Tok (Ident o) :: r when lower o = "of" -> (List.rev acc, Some r)
      | c :: r -> split (c :: acc) r
      | [] -> (List.rev acc, None) in
    let anb, of_s = split [] args in
    let a, b = parse_anb (Css.to_string anb) in
    Nth_child (a, b, Option.map parse_complex_list of_s, f = "nth-last-child")
  | "nth-of-type" | "nth-last-of-type" ->
    let a, b = parse_anb (Css.to_string args) in
    Nth_of_type (a, b, f = "nth-last-of-type")
  | "lang" | "dir" | "host" | "host-context" | "state" -> Never
  | _ -> raise Invalid

(* :has's relative selectors: "> a", "+ b", "c" (a descendant) *)
and relative_list args =
  let rec split acc cur = function
    | [] -> List.rev (List.rev cur :: acc)
    | Tok Comma :: r -> split (List.rev cur :: acc) [] r
    | c :: r -> split acc (c :: cur) r in
  List.filter_map (fun part ->
      try
        match Css.trim part with
        | Tok (Delim ">") :: r -> Some (Child, parse_complex r)
        | Tok (Delim "+") :: r -> Some (Next, parse_complex r)
        | Tok (Delim "~") :: r -> Some (Subsequent, parse_complex r)
        | r -> Some (Descendant, parse_complex r)
      with Invalid -> None) (split [] [] args)

let parse_list cvs = try Some (parse_complex_list cvs) with Invalid -> None

(* ---- specificity: ids, classes and the like, types; as one number ---- *)

let rec specificity (c : complex) =
  Array.fold_left (fun acc comp -> acc + List.fold_left (fun a s -> a + simple_spec s) 0 comp) 0 c.comps

and simple_spec = function
  | Universal | Where _ | Anchor -> 0
  | Type _ | Pseudo_element _ -> 1
  | Id _ -> 10000
  | Not l | Is l -> max_spec l
  | Has l -> max_spec (List.map snd l)
  | Nth_child (_, _, Some l, _) -> 100 + max_spec l
  | _ -> 100

and max_spec l = List.fold_left (fun m c -> max m (specificity c)) 0 l

(* ---- the key a rule is indexed by: its rightmost compound's best part ---- *)

type key = K_id of string | K_class of string | K_tag of string | K_any

let key (c : complex) =
  let last = c.comps.(Array.length c.comps - 1) in
  match List.find_map (function Id i -> Some (K_id i) | _ -> None) last with
  | Some k -> k
  | None ->
    match List.find_map (function Class cl -> Some (K_class cl) | _ -> None) last with
    | Some k -> k
    | None -> match List.find_map (function Type t -> Some (K_tag t) | _ -> None) last with
      | Some k -> k
      | None -> K_any

(* the ancestor filter's keys: the tags, classes and ids that an element's
   ancestors must have for the selector to match it ("#id", ".class",
   "tag"); taken from the compounds joined to the right by a descendant or
   child combinator *)
let ancestor_keys (c : complex) =
  let keys = ref [] in
  Array.iteri (fun i comp ->
      if i < Array.length c.combs && (c.combs.(i) = Descendant || c.combs.(i) = Child) then
        List.iter (function
            | Id x -> keys := ("#" ^ x) :: !keys
            | Class x -> keys := ("." ^ x) :: !keys
            | Type t -> keys := t :: !keys
            | _ -> ()) comp) c.comps;
  List.sort_uniq compare !keys

let pseudo_element (c : complex) =
  List.find_map (function Pseudo_element p -> Some p | _ -> None) c.comps.(Array.length c.comps - 1)

(* ---- matching ---- *)

let element_parent (n : Dom.node) =
  match n.parent with Some ({ kind = Element _; _ } as p) -> Some p | _ -> None

let rec prev_element (n : Dom.node) =
  match n.prev with
  | Some ({ kind = Element _; _ } as p) -> Some p
  | Some p -> prev_element p
  | None -> None

let rec next_element (n : Dom.node) =
  match n.next with
  | Some ({ kind = Element _; _ } as p) -> Some p
  | Some p -> next_element p
  | None -> None

let anchor : Dom.node option ref = ref None

(* the position (1-based) among the element siblings that satisfy [p] *)
let index ~from_end p (n : Dom.node) =
  let step = if from_end then next_element else prev_element in
  let rec go k m = match step m with Some s -> go (if p s then k + 1 else k) s | None -> k in
  go 1 n

let nth a b k = if a = 0 then k = b else (k - b) mod a = 0 && (k - b) / a >= 0

let has_class n c = List.mem c (Dom.classes n)

let attr_value (n : Dom.node) name =
  (* HTML attribute names are lower case already; foreign ones may not be *)
  match Dom.attr n name with
  | Some v -> Some v
  | None -> List.find_map (fun (a : Dom.attr) -> if lower a.name = name then Some a.value else None) (Dom.attrs n)

let rec simple_matches (n : Dom.node) s =
  match s with
  | Universal -> true
  | Type t ->
    (match n.kind with
     | Element { ns = Dom.Html; name; _ } -> name = t
     | Element { name; _ } -> name = t || lower name = t
     | _ -> false)
  | Id i -> Dom.attr n "id" = Some i
  | Class c -> has_class n c
  | Attr (name, op, v, ci) ->
    (match attr_value n name with
     | None -> false
     | Some actual ->
       let actual = if ci then lower actual else actual in
       let lv = String.length v and la = String.length actual in
       match op with
       | Exists -> true
       | Equals -> actual = v
       | Includes -> v <> "" && not (String.contains v ' ')
                     && List.mem v (String.split_on_char ' ' actual)
       | Dash -> actual = v || (la > lv && String.sub actual 0 lv = v && actual.[lv] = '-')
       | Prefix -> v <> "" && String.starts_with ~prefix:v actual
       | Suffix -> v <> "" && String.ends_with ~suffix:v actual
       | Substring -> v <> "" && (let rec find i = i + lv <= la && (String.sub actual i lv = v || find (i + 1)) in find 0))
  | Root -> (match n.parent with Some { kind = Document _; _ } -> true | _ -> false)
  | First_child -> prev_element n = None
  | Last_child -> next_element n = None
  | Only_child -> prev_element n = None && next_element n = None
  | First_of_type -> index ~from_end:false (fun s -> Dom.name s = Dom.name n) n = 1
  | Last_of_type -> index ~from_end:true (fun s -> Dom.name s = Dom.name n) n = 1
  | Only_of_type -> index ~from_end:false (fun s -> Dom.name s = Dom.name n) n = 1
                    && index ~from_end:true (fun s -> Dom.name s = Dom.name n) n = 1
  | Nth_child (a, b, of_s, from_end) ->
    (match of_s with
     | None -> nth a b (index ~from_end (fun _ -> true) n)
     | Some l -> any l n && nth a b (index ~from_end (any l) n))
  | Nth_of_type (a, b, from_end) -> nth a b (index ~from_end (fun s -> Dom.name s = Dom.name n) n)
  | Not l -> not (any l n)
  | Is l | Where l -> any l n
  | Has rels -> has rels n
  | Empty ->
    List.for_all (fun (c : Dom.node) -> match c.kind with
        | Element _ -> false | Text { data } -> data = "" | _ -> true) (Dom.children n)
  | Link -> (Dom.is_html n "a" || Dom.is_html n "area") && Dom.attr n "href" <> None
  | Checked ->
    (Dom.is_html n "input" && Dom.attr n "checked" <> None)
    || (Dom.is_html n "option" && Dom.attr n "selected" <> None)
  | Disabled -> List.mem (Dom.name n) [ "button"; "input"; "select"; "textarea"; "optgroup"; "option"; "fieldset" ]
                && Dom.attr n "disabled" <> None
  | Enabled -> List.mem (Dom.name n) [ "button"; "input"; "select"; "textarea"; "optgroup"; "option"; "fieldset" ]
               && Dom.attr n "disabled" = None
  | Defined -> true
  | Never -> false
  | Anchor -> (match !anchor with Some a -> a == n | None -> false)
  | Pseudo_element _ -> true

and compound_matches n comp = List.for_all (simple_matches n) comp

(* compound i matches n, and so does everything left of it *)
and match_at (c : complex) i (n : Dom.node) =
  compound_matches n c.comps.(i)
  && (i = 0
      || match c.combs.(i - 1) with
      | Child -> (match element_parent n with Some p -> match_at c (i - 1) p | None -> false)
      | Descendant ->
        let rec up m = match element_parent m with Some p -> match_at c (i - 1) p || up p | None -> false in
        up n
      | Next -> (match prev_element n with Some s -> match_at c (i - 1) s | None -> false)
      | Subsequent ->
        let rec back m = match prev_element m with Some s -> match_at c (i - 1) s || back s | None -> false in
        back n)

and matches (c : complex) n =
  match n.Dom.kind with
  | Element _ -> match_at c (Array.length c.comps - 1) n
  | _ -> false

and any l n = List.exists (fun c -> matches c n) l

(* :has: an element related to [n] as each relative selector says *)
and has rels n =
  let saved = !anchor in
  anchor := Some n;
  let result = List.exists (fun (comb, (c : complex)) ->
      (* the relative selector, with [n] as an extra leftmost compound *)
      let anchored = { comps = Array.append [| [ Anchor ] |] c.comps;
                       combs = Array.append [| comb |] c.combs } in
      match comb with
      | Descendant | Child ->
        let found = ref false in
        (try
           Dom.iter (fun d -> if d != n && matches anchored d then (found := true; raise Exit)) n
         with Exit -> ());
        !found
      | Next | Subsequent ->
        let rec sib m = match next_element m with
          | Some s -> matches anchored s || sib s | None -> false in
        sib n) rels in
  anchor := saved;
  result
