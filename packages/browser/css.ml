(* Css: a little CSS (level A), between the tokens and the layout.

   - The page's elements as a tree (a DOM of its own): the tokens nested,
     with the ends HTML lets a page leave out (a <p> before a block, an
     <li> before the next, the cells and rows of a table...).
   - Its style sheets, in their order: <style> blocks, <link
     rel=stylesheet> (fetched by the browser), @media blocks that hold for
     the window's width; other @ blocks skipped.
   - Selectors: tag, .class, #id, [attr], [attr=v] (~= ^= $= *= |= too),
     *, :first-child, :last-child, :only-child, :not(simple), :link,
     :root; combinators: descendant, >, +, ~. A rule for ::before, :hover,
     :focus... is left out.
   - The cascade: !important, then specificity, then order; the element's
     style attribute last; rules found through an index (by id, class,
     tag), not tried one by one.
   - The result: the tokens again, balanced, each element's style in an
     attribute "x-css" (the properties the layout knows, as prop:value;),
     and the elements hidden (display:none, visibility:hidden, hidden)
     taken out. *)

(* ---- media queries ---- *)

let lower = String.lowercase_ascii

(* whether a media query holds for a screen [px] pixels wide *)
let media_holds ~px query =
  let one q =
    let q = lower (String.trim q) in
    let neg, q =
      if String.starts_with ~prefix:"not " q then (true, String.sub q 4 (String.length q - 4))
      else if String.starts_with ~prefix:"only " q then (false, String.sub q 5 (String.length q - 5))
      else (false, q) in
    let parts =                                    (* split at " and " *)
      let b = Buffer.create (String.length q) and i = ref 0 and n = String.length q in
      while !i < n do
        if !i + 5 <= n && String.sub q !i 5 = " and " then (Buffer.add_char b '\001'; i := !i + 5)
        else (Buffer.add_char b q.[!i]; incr i)
      done;
      List.map String.trim (String.split_on_char '\001' (Buffer.contents b)) in
    let length v =
      let v = String.trim v in
      let num s = float_of_string_opt (String.trim s) in
      if String.ends_with ~suffix:"px" v then num (String.sub v 0 (String.length v - 2))
      else if String.ends_with ~suffix:"em" v then
        Option.map (fun f -> f *. 16.) (num (String.sub v 0 (String.length v - 2)))
      else num v in
    let holds part =
      match part with
      | "" | "all" | "screen" -> true
      | "print" | "speech" | "tv" | "handheld" | "projection" -> false
      | f when String.length f > 2 && f.[0] = '(' && f.[String.length f - 1] = ')' ->
        let f = String.sub f 1 (String.length f - 2) in
        (match String.index_opt f ':' with
         | Some i ->
           let name = String.trim (String.sub f 0 i)
           and v = String.sub f (i + 1) (String.length f - i - 1) in
           (match name, length v with
            | "max-width", Some w -> float px <= w
            | "min-width", Some w -> float px >= w
            | "orientation", _ -> String.trim v = "landscape"
            | "prefers-color-scheme", _ -> String.trim v = "light"
            | "prefers-reduced-motion", _ -> String.trim v = "no-preference"
            | _ -> false)
         | None -> f = "color")
      | _ -> false in
    let r = List.for_all holds parts in
    if neg then not r else r in
  List.exists one (String.split_on_char ',' query)

(* ---- colours ---- *)

let named_colours = [
  "black", 0x000000; "white", 0xFFFFFF; "red", 0xFF0000; "green", 0x008000; "blue", 0x0000FF;
  "yellow", 0xFFFF00; "orange", 0xFFA500; "purple", 0x800080; "gray", 0x808080; "grey", 0x808080;
  "silver", 0xC0C0C0; "maroon", 0x800000; "navy", 0x000080; "teal", 0x008080; "olive", 0x808000;
  "lime", 0x00FF00; "aqua", 0x00FFFF; "fuchsia", 0xFF00FF; "brown", 0xA52A2A;
  "darkred", 0x8B0000; "darkgreen", 0x006400; "darkblue", 0x00008B; "darkgray", 0xA9A9A9;
  "darkgrey", 0xA9A9A9; "dimgray", 0x696969; "dimgrey", 0x696969; "lightgray", 0xD3D3D3;
  "lightgrey", 0xD3D3D3; "gainsboro", 0xDCDCDC; "whitesmoke", 0xF5F5F5; "crimson", 0xDC143C;
  "firebrick", 0xB22222; "indigo", 0x4B0082; "darkslategray", 0x2F4F4F; "slategray", 0x708090;
  "steelblue", 0x4682B4; "royalblue", 0x4169E1; "midnightblue", 0x191970; "seagreen", 0x2E8B57;
  "forestgreen", 0x228B22; "chocolate", 0xD2691E; "sienna", 0xA0522D; "darkorange", 0xFF8C00;
  "gold", 0xFFD700; "pink", 0xFFC0CB; "beige", 0xF5F5DC; "ivory", 0xFFFFF0; "linen", 0xFAF0E6;
  "aliceblue", 0xF0F8FF; "lightblue", 0xADD8E6; "lightyellow", 0xFFFFE0; "darkviolet", 0x9400D3;
  "darkcyan", 0x008B8B; "darkmagenta", 0x8B008B; "darkolivegreen", 0x556B2F; "tomato", 0xFF6347 ]

(* a CSS colour: #rgb, #rrggbb (#rrggbbaa), rgb() / rgba() (mostly
   transparent: none), a name; transparent, currentColor...: none *)
let colour v =
  let v = String.trim (String.lowercase_ascii v) in
  let hex s = int_of_string_opt ("0x" ^ s) in
  let n = String.length v in
  if n > 0 && v.[0] = '#' then
    match n with
    | 4 | 5 -> Option.map (fun x -> let x = if n = 5 then x lsr 4 else x in
                            let r = (x lsr 8) land 15 and g = (x lsr 4) land 15 and b = x land 15 in
                            (r * 17) lsl 16 lor (g * 17) lsl 8 lor (b * 17)) (hex (String.sub v 1 (n - 1)))
    | 7 -> hex (String.sub v 1 6)
    | 9 -> if (match hex (String.sub v 7 2) with Some a -> a < 128 | None -> true) then None
      else hex (String.sub v 1 6)
    | _ -> None
  else if String.starts_with ~prefix:"rgb" v then
    match String.index_opt v '(', String.rindex_opt v ')' with
    | Some i, Some j when j > i ->
      let parts = List.filter (( <> ) "")
          (String.split_on_char ' ' (String.map (fun c -> if c = ',' || c = '/' then ' ' else c)
                                       (String.sub v (i + 1) (j - i - 1)))) in
      let num s = if String.ends_with ~suffix:"%" s
        then Option.map (fun f -> int_of_float (f *. 2.55)) (float_of_string_opt (String.sub s 0 (String.length s - 1)))
        else Option.map int_of_float (float_of_string_opt s) in
      let alpha = match List.nth_opt parts 3 with
        | Some a -> (match float_of_string_opt (String.map (fun c -> if c = '%' then ' ' else c) a |> String.trim) with
            | Some f -> if String.ends_with ~suffix:"%" a then f /. 100. else f | None -> 1.)
        | None -> 1. in
      (match List.map num (List.filteri (fun k _ -> k < 3) parts) with
       | [ Some r; Some g; Some b ] when alpha >= 0.5 ->
         let c x = max 0 (min 255 x) in Some ((c r lsl 16) lor (c g lsl 8) lor c b)
       | _ -> None)
    | _ -> None
  else List.assoc_opt v named_colours

let luminance c = (299 * (c lsr 16) + 587 * ((c lsr 8) land 255) + 114 * (c land 255)) / 1000

(* ---- selectors ---- *)

type attr_test = { aname : string; op : string; avalue : string }

type pseudo =
  | First_child | Last_child | Only_child | Link | Root
  | Not of compound
  | Never                       (* :hover, :focus...: nobody points or types here *)

and compound = {
  tag : string;                     (* "" or "*": any *)
  id : string;
  classes : string list;
  attrs : attr_test list;
  pseudos : pseudo list;
}

type combinator = Descendant | Child | Adjacent | Sibling

(* a selector, from its right end: the subject, then (combinator,
   compound) towards the left *)
type selector = { subject : compound; left : (combinator * compound) list; spec : int }

exception Unsupported

let is_ident c =
  match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' -> true
             | c -> Char.code c >= 0x80

(* one selector (no commas); Unsupported for what is not level A *)
let parse_selector s =
  let n = String.length s and i = ref 0 in
  let ident () =
    let j = !i in
    while !i < n && (is_ident s.[!i] || (s.[!i] = '\\' && !i + 1 < n && (incr i; true))) do incr i done;
    if !i = j then raise Unsupported;
    String.sub s j (!i - j) in
  let skip_ws () = while !i < n && (s.[!i] = ' ' || s.[!i] = '\t' || s.[!i] = '\n' || s.[!i] = '\r') do incr i done in
  let rec compound () =
    let tag = ref "" and id = ref "" and classes = ref [] and attrs = ref [] and pseudos = ref [] in
    if !i < n && s.[!i] = '*' then (incr i; tag := "*")
    else if !i < n && is_ident s.[!i] then tag := lower (ident ());
    let continue = ref true in
    while !continue && !i < n do
      match s.[!i] with
      | '#' -> incr i; id := ident ()
      | '.' -> incr i; classes := ident () :: !classes
      | '[' ->
        incr i; skip_ws ();
        let a = lower (ident ()) in
        skip_ws ();
        let op =
          if !i < n && s.[!i] = ']' then ""
          else if !i < n && s.[!i] = '=' then (incr i; "=")
          else if !i + 1 < n && s.[!i + 1] = '=' && String.contains "~^$*|" s.[!i] then
            (let o = String.make 1 s.[!i] ^ "=" in i := !i + 2; o)
          else raise Unsupported in
        skip_ws ();
        let v =
          if op = "" then ""
          else if !i < n && (s.[!i] = '"' || s.[!i] = '\'') then begin
            let q = s.[!i] in
            incr i;
            let j = !i in
            while !i < n && s.[!i] <> q do incr i done;
            let v = String.sub s j (!i - j) in
            incr i; v
          end else ident () in
        skip_ws ();
        (* [a=v i]: case-insensitive, taken as written *)
        if !i < n && (s.[!i] = 'i' || s.[!i] = 's') then (incr i; skip_ws ());
        if !i >= n || s.[!i] <> ']' then raise Unsupported;
        incr i;
        attrs := { aname = a; op; avalue = v } :: !attrs
      | ':' ->
        incr i;
        if !i < n && s.[!i] = ':' then raise Unsupported;       (* ::before *)
        let p = lower (ident ()) in
        (match p with
         | "first-child" -> pseudos := First_child :: !pseudos
         | "last-child" -> pseudos := Last_child :: !pseudos
         | "only-child" -> pseudos := Only_child :: !pseudos
         | "link" | "any-link" -> pseudos := Link :: !pseudos
         | "root" -> pseudos := Root :: !pseudos
         | "not" when !i < n && s.[!i] = '(' ->
           incr i; skip_ws ();
           let c = compound () in
           skip_ws ();
           if !i >= n || s.[!i] <> ')' then raise Unsupported;
           incr i;
           pseudos := Not c :: !pseudos
         | "hover" | "focus" | "active" | "visited" | "focus-within" | "focus-visible"
         | "target" | "checked" | "disabled" | "invalid" | "placeholder-shown" ->
           pseudos := Never :: !pseudos
         | _ -> raise Unsupported)     (* :before, :nth-child()... *)
      | _ -> continue := false
    done;
    if !tag = "" && !id = "" && !classes = [] && !attrs = [] && !pseudos = [] then raise Unsupported;
    (* :not(:hover): the pseudo alone, which never holds *)
    { tag = !tag; id = !id; classes = !classes; attrs = !attrs; pseudos = !pseudos } in
  skip_ws ();
  let first = compound () in
  let parts = ref [] and last = ref first in
  let rec more () =
    let had_ws = !i < n && (s.[!i] = ' ' || s.[!i] = '\t' || s.[!i] = '\n' || s.[!i] = '\r') in
    skip_ws ();
    if !i < n then begin
      let comb = match s.[!i] with
        | '>' -> incr i; Child
        | '+' -> incr i; Adjacent
        | '~' -> incr i; Sibling
        | _ -> if had_ws then Descendant else raise Unsupported in
      skip_ws ();
      let c = compound () in
      parts := (comb, !last) :: !parts;
      last := c;
      more ()
    end in
  more ();
  (* specificity: ids, then classes, attributes and pseudo-classes, then tags *)
  let rec count c =
    let a = if c.id <> "" then 1 else 0
    and b = List.length c.classes + List.length c.attrs
            + List.fold_left (fun k p -> match p with Not c' -> let _, b', _ = count c' in k + b'
                                                      | _ -> k + 1) 0 c.pseudos
    and t = if c.tag <> "" && c.tag <> "*" then 1 else 0 in
    (a, b, t) in
  let spec = List.fold_left (fun acc c ->
      let a, b, t = count c in
      acc + a * 10000 + b * 100 + t) 0 (!last :: List.map snd !parts) in
  { subject = !last; left = !parts; spec }

(* ---- the tree ---- *)

type element = {
  name : string;
  eattrs : (string * string) list;
  parent : element option;
  mutable kids : node list;                  (* reversed while building *)
  mutable elems : element array;             (* its element children, in order *)
  mutable pos : int;                         (* its place among its parent's elements *)
  mutable decls : (string * string) list;    (* its style, computed *)
  eid : string;
  eclasses : string list;
}
and node = E of element | T of string

let void = [ "area"; "base"; "br"; "col"; "embed"; "hr"; "img"; "input"; "link"; "meta";
             "source"; "track"; "wbr"; "param"; "keygen" ]

let blocks = [ "p"; "div"; "ul"; "ol"; "dl"; "table"; "pre"; "blockquote"; "form"; "hr";
               "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "section"; "article"; "header"; "footer";
               "nav"; "main"; "aside"; "figure"; "address"; "details"; "fieldset"; "menu";
               "center"; "dir"; "listing"; "hgroup" ]

let inline_tags = [ "a"; "span"; "b"; "i"; "em"; "strong"; "font"; "small"; "big"; "code";
                    "u"; "s"; "tt"; "kbd"; "samp"; "var"; "cite"; "abbr"; "sub"; "sup";
                    "label"; "mark"; "q"; "time"; "nobr" ]

let attr name a = List.assoc_opt name a

let build tokens =
  let root = { name = "#root"; eattrs = []; parent = None; kids = []; elems = [||]; pos = 0; decls = [];
               eid = ""; eclasses = [] } in
  let stack = ref [ root ] in
  let top () = List.hd !stack in
  let open_names () = List.map (fun e -> e.name) !stack in
  (* close up to and including the nearest open [name], if it is open
     before any of [stop] *)
  let close_to ?(stop = []) name =
    let rec find = function
      | e :: rest -> if e.name = name then true else if List.mem e.name stop || e.name = "#root" then false else find rest
      | [] -> false in
    if find !stack then begin
      let rec pop () =
        match !stack with
        | e :: rest when e.name = name -> stack := rest
        | _ :: rest when rest <> [] -> stack := rest; pop ()
        | _ -> () in
      pop ()
    end in
  let add n = let t = top () in t.kids <- n :: t.kids in
  List.iter (function
      | Html.Text s -> add (T s)
      | Html.Start (name, a) ->
        (* the ends a page may leave out *)
        if List.mem name blocks || name = "li" || name = "dt" || name = "dd" then
          close_to ~stop:[ "table"; "td"; "th"; "button"; "caption"; "li"; "object" ] "p";
        (match name with
         | "li" -> close_to ~stop:[ "ul"; "ol"; "menu"; "dir" ] "li"
         | "dt" | "dd" -> close_to ~stop:[ "dl" ] "dt"; close_to ~stop:[ "dl" ] "dd"
         | "tr" -> close_to ~stop:[ "table" ] "td"; close_to ~stop:[ "table" ] "th";
           close_to ~stop:[ "table" ] "tr"
         | "td" | "th" -> close_to ~stop:[ "tr"; "table" ] "td"; close_to ~stop:[ "tr"; "table" ] "th"
         | "thead" | "tbody" | "tfoot" ->
           List.iter (close_to ~stop:[ "table" ]) [ "td"; "th"; "tr"; "thead"; "tbody"; "tfoot" ]
         | "option" -> close_to ~stop:[ "select"; "datalist" ] "option"
         | _ -> ());
        let p = top () in
        let eclasses = match attr "class" a with
          | Some c -> List.filter (( <> ) "")
                        (String.split_on_char ' ' (String.map (fun c -> if c = '\t' || c = '\n' then ' ' else c) c))
          | None -> [] in
        let e = { name; eattrs = a; parent = Some p; kids = []; elems = [||]; pos = 0; decls = [];
                  eid = Option.value (attr "id" a) ~default:""; eclasses } in
        add (E e);
        if not (List.mem name void) then stack := e :: !stack
      | Html.End name ->
        if List.mem name (open_names ()) then close_to name) tokens;
  (* the element children in order, and each one's place *)
  let rec finish e =
    e.kids <- List.rev e.kids;
    e.elems <- Array.of_list (List.filter_map (function E x -> Some x | T _ -> None) e.kids);
    Array.iteri (fun i x -> x.pos <- i; finish x) e.elems in
  finish root;
  root

(* ---- matching ---- *)

let classes_of e = e.eclasses

let siblings e = match e.parent with Some p -> p.elems | None -> [| e |]

let rec compound_matches c e =
  (c.tag = "" || c.tag = "*" || c.tag = e.name)
  && (c.id = "" || e.eid = c.id)
  && (c.classes = [] || (let cs = classes_of e in List.for_all (fun k -> List.mem k cs) c.classes))
  && List.for_all (fun t ->
      match attr t.aname e.eattrs, t.op with
      | None, _ -> false
      | Some _, "" -> true
      | Some v, "=" -> v = t.avalue
      | Some v, "~=" -> List.mem t.avalue (String.split_on_char ' ' v)
      | Some v, "^=" -> t.avalue <> "" && String.starts_with ~prefix:t.avalue v
      | Some v, "$=" -> t.avalue <> "" && String.ends_with ~suffix:t.avalue v
      | Some v, "*=" -> t.avalue <> "" && Html.contains v t.avalue
      | Some v, "|=" -> v = t.avalue || String.starts_with ~prefix:(t.avalue ^ "-") v
      | _ -> false) c.attrs
  && List.for_all (fun p ->
      match p with
      | First_child -> e.pos = 0
      | Last_child -> e.pos = Array.length (siblings e) - 1
      | Only_child -> Array.length (siblings e) = 1
      | Link -> (e.name = "a" || e.name = "area") && attr "href" e.eattrs <> None
      | Root -> e.name = "html"
      | Not c' -> not (compound_matches c' e)
      | Never -> false) c.pseudos

let selector_matches sel e =
  compound_matches sel.subject e
  && (let rec go e = function
      | [] -> true
      | (Child, c) :: rest ->
        (match e.parent with Some p when compound_matches c p -> go p rest | _ -> false)
      | (Descendant, c) :: rest ->
        let rec up = function
          | Some p when p.name <> "#root" -> (compound_matches c p && go p rest) || up p.parent
          | _ -> false in
        up e.parent
      | (Adjacent, c) :: rest ->
        e.pos > 0 && (let s = (siblings e).(e.pos - 1) in compound_matches c s && go s rest)
      | (Sibling, c) :: rest ->
        let sib = siblings e in
        let rec back i = i >= 0 && ((compound_matches c sib.(i) && go sib.(i) rest) || back (i - 1)) in
        back (e.pos - 1) in
     go e sel.left)

(* ---- style sheets ---- *)

type rule = { sel : selector; decls : (string * string * bool) list; order : int }

(* the shorthands, as the long properties the layout reads (set below) *)
let expand_ref : (string * string -> (string * string) list) ref = ref (fun d -> [ d ])

(* a rule's declarations, ready: expanded, unless they use var() (that
   waits for the element's variables) *)
let prepare ds =
  List.concat_map (fun (p, v, i) ->
      if String.starts_with ~prefix:"--" p || Html.contains v "var(" then [ (p, v, i) ]
      else List.map (fun (p, v) -> (p, v, i)) (!expand_ref (p, v))) ds

let strip_comments css =
  let b = Buffer.create (String.length css) and i = ref 0 and n = String.length css in
  while !i < n do
    if !i + 1 < n && css.[!i] = '/' && css.[!i + 1] = '*' then begin
      i := !i + 2;
      while !i + 1 < n && not (css.[!i] = '*' && css.[!i + 1] = '/') do incr i done;
      i := !i + 2
    end else begin Buffer.add_char b css.[!i]; incr i end
  done;
  Buffer.contents b

(* "a: b; c: d !important": (property, value, important) *)
let declarations s =
  List.filter_map (fun d ->
      match String.index_opt d ':' with
      | Some i ->
        let p = lower (String.trim (String.sub d 0 i)) in
        let v = String.trim (String.sub d (i + 1) (String.length d - i - 1)) in
        let important, v =
          match String.rindex_opt v '!' with
          | Some k when lower (String.trim (String.sub v (k + 1) (String.length v - k - 1))) = "important" ->
            (true, String.trim (String.sub v 0 k))
          | _ -> (false, v) in
        if p = "" || v = "" then None else Some (p, v, important)
      | None -> None) (String.split_on_char ';' s)

(* the properties the layout knows (and the variables, for var()) *)
let known p =
  String.starts_with ~prefix:"--" p
  || List.mem p [ "display"; "visibility"; "color"; "background-color"; "background";
                  "font-weight"; "font-style"; "font"; "text-decoration"; "text-decoration-line";
                  "text-align"; "white-space"; "text-transform"; "list-style"; "list-style-type";
                  "margin"; "margin-top"; "margin-bottom"; "opacity"; "position"; "clip";
                  "clip-path"; "left"; "top"; "width"; "height" ]

(* the rules of a style sheet, numbered from [order] on *)
let parse_sheet ~px ~order css =
  let css = strip_comments css in
  let n = String.length css in
  let out = ref [] in
  let rec skip_block i depth =
    if i >= n then n
    else match css.[i] with
      | '{' -> skip_block (i + 1) (depth + 1)
      | '}' -> if depth = 0 then i + 1 else skip_block (i + 1) (depth - 1)
      | _ -> skip_block (i + 1) depth in
  let rec rules i active =
    let j = ref i in
    while !j < n && css.[!j] <> '{' && css.[!j] <> '}' && css.[!j] <> ';' do incr j done;
    if !j >= n then n
    else if css.[!j] = '}' then !j + 1
    else begin
      let prelude = String.trim (String.sub css i (!j - i)) in
      if css.[!j] = ';' then rules (!j + 1) active
      else if String.length prelude > 0 && prelude.[0] = '@' then begin
        let l = lower prelude in
        if String.starts_with ~prefix:"@media" l then
          rules (rules (!j + 1) (active && media_holds ~px (String.sub prelude 6 (String.length prelude - 6)))) active
        else if String.starts_with ~prefix:"@supports" l || String.starts_with ~prefix:"@layer" l
                || String.starts_with ~prefix:"@container" l then
          (* their rules, as if they held *)
          rules (rules (!j + 1) active) active
        else rules (skip_block (!j + 1) 0) active
      end else begin
        let k = ref (!j + 1) in
        while !k < n && css.[!k] <> '}' do incr k done;
        if active then begin
          let ds = prepare (List.filter (fun (p, _, _) -> known p)
                              (declarations (String.sub css (!j + 1) (!k - !j - 1)))) in
          if ds <> [] then
            List.iter (fun s ->
                match parse_selector (String.trim s) with
                | sel -> incr order; out := { sel; decls = ds; order = !order } :: !out
                | exception (Unsupported | Invalid_argument _) -> ())
              (String.split_on_char ',' prelude)
        end;
        rules (min n (!k + 1)) active
      end
    end in
  let i = ref 0 in
  while !i < n do i := rules !i true done;
  List.rev !out

(* ---- the cascade ---- *)

type index = {
  by_id : (string, rule) Hashtbl.t;
  by_class : (string, rule) Hashtbl.t;
  by_tag : (string, rule) Hashtbl.t;
  mutable any : rule list;
}

let index rules =
  let ix = { by_id = Hashtbl.create 256; by_class = Hashtbl.create 1024;
             by_tag = Hashtbl.create 64; any = [] } in
  List.iter (fun r ->
      let c = r.sel.subject in
      if c.id <> "" then Hashtbl.add ix.by_id c.id r
      else if c.classes <> [] then Hashtbl.add ix.by_class (List.hd c.classes) r
      else if c.tag <> "" && c.tag <> "*" then Hashtbl.add ix.by_tag c.tag r
      else ix.any <- r :: ix.any) rules;
  ix

let inherited = [ "color"; "font-weight"; "font-style"; "text-align"; "white-space";
                  "text-transform"; "list-style-type"; "visibility" ]

(* var(--x, fallback): the variable's value (inherited), or the fallback;
   variables that name each other (--a: var(--b); --b: var(--a)) give up *)
let rec resolve ?(level = 0) vars v =
  match Html.contains v "var(" with
  | false -> Some v
  | true when level > 12 -> None
  | true ->
    let i = let rec f k = if String.sub v k 4 = "var(" then k else f (k + 1) in f 0 in
    (* its closing parenthesis *)
    let depth = ref 0 and j = ref (i + 4) and n = String.length v in
    while !j < n && not (v.[!j] = ')' && !depth = 0) do
      if v.[!j] = '(' then incr depth else if v.[!j] = ')' then decr depth;
      incr j
    done;
    if !j >= n then None
    else begin
      let inside = String.sub v (i + 4) (!j - i - 4) in
      let name, fallback = match String.index_opt inside ',' with
        | Some c -> (String.trim (String.sub inside 0 c), Some (String.trim (String.sub inside (c + 1) (String.length inside - c - 1))))
        | None -> (String.trim inside, None) in
      let value = match List.assoc_opt name vars with Some x -> Some x | None -> fallback in
      match value with
      | None -> None
      | Some x -> resolve ~level:(level + 1) vars (String.sub v 0 i ^ x ^ String.sub v (!j + 1) (n - !j - 1))
    end

(* the shorthands, as the long properties the layout reads *)
let expand (p, v) =
  let words = List.filter (( <> ) "") (String.split_on_char ' ' (lower v)) in
  match p with
  | "background" ->
    (match List.find_opt (fun w -> w.[0] = '#' || String.starts_with ~prefix:"rgb" w
                                   || List.mem_assoc w named_colours) words with
     | Some c -> [ ("background-color", c) ] | None -> [])
  | "font" ->
    (if List.exists (fun w -> w = "bold" || w = "bolder" || w = "600" || w = "700" || w = "800" || w = "900") words
     then [ ("font-weight", "bold") ] else [])
    @ (if List.mem "italic" words then [ ("font-style", "italic") ] else [])
  | "text-decoration-line" -> [ ("text-decoration", v) ]
  | "list-style" -> if List.mem "none" words then [ ("list-style-type", "none") ] else []
  | "margin" ->
    (match words with
     | [ a ] -> [ (p ^ "-top", a); (p ^ "-bottom", a) ]
     | [ a; _ ] | [ a; _; _ ] -> [ (p ^ "-top", a); (p ^ "-bottom", match words with [ _; _; c ] -> c | _ -> a) ]
     | [ a; _; c; _ ] -> [ (p ^ "-top", a); (p ^ "-bottom", c) ]
     | _ -> [])
  | _ -> [ (p, v) ]

let () = expand_ref := expand

let compute ~rules root =
  let ix = index rules in
  let rec visit e (parent_decls : (string * string) list) (vars : (string * string) list) =
    if e.name <> "#root" then begin
      let cands = ref ix.any in
      if e.eid <> "" then cands := List.rev_append (Hashtbl.find_all ix.by_id e.eid) !cands;
      List.iter (fun c -> cands := List.rev_append (Hashtbl.find_all ix.by_class c) !cands) e.eclasses;
      cands := List.rev_append (Hashtbl.find_all ix.by_tag e.name) !cands;
      (* a rule found twice (two of its classes): once *)
      let matched = List.filter (fun r -> selector_matches r.sel e)
          (List.sort_uniq (fun a b -> compare a.order b.order) !cands) in
      (* the declarations in cascade order: normal ones by specificity and
         order, the style attribute, then the !important ones *)
      let by_rank = List.sort (fun a b -> compare (a.sel.spec, a.order) (b.sel.spec, b.order)) matched in
      let normal = List.concat_map (fun r -> List.filter (fun (_, _, i) -> not i) r.decls) by_rank in
      let important = List.concat_map (fun r -> List.filter (fun (_, _, i) -> i) r.decls) by_rank in
      let inline_ = match attr "style" e.eattrs with
        | Some s -> List.filter (fun (p, _, _) -> known p) (declarations s) | None -> [] in
      let ordered = List.map (fun (p, v, _) -> (p, v))
          (normal @ List.filter (fun (_, _, i) -> not i) inline_ @ important
           @ List.filter (fun (_, _, i) -> i) inline_) in
      (* variables first (inherited), then the properties *)
      let vars = List.fold_left (fun acc (p, v) ->
          if String.starts_with ~prefix:"--" p then (p, v) :: List.remove_assoc p acc else acc) vars ordered in
      let own = List.fold_left (fun acc (p, v) ->
          if String.starts_with ~prefix:"--" p then acc
          else if not (Html.contains v "var(") then (p, v) :: List.remove_assoc p acc
          else match resolve vars v with
            | Some v ->
              List.fold_left (fun acc (p, v) -> (p, v) :: List.remove_assoc p acc) acc
                (expand (p, v))
            | None -> acc) [] ordered in
      (* "inherit", and the inherited properties a parent has *)
      let own = List.filter_map (fun (p, v) ->
          if lower v = "inherit" then Option.map (fun x -> (p, x)) (List.assoc_opt p parent_decls)
          else if lower v = "initial" || lower v = "unset" then None
          else Some (p, v)) own in
      (* the inherited properties the layout reads per element (alignment,
         white space, case, list marks): the parent's, if not its own *)
      e.decls <- own @ List.filter (fun (p, _) ->
          List.mem p [ "text-align"; "white-space"; "text-transform"; "list-style-type" ]
          && not (List.mem_assoc p own)) parent_decls;
      let passed = List.fold_left (fun acc p ->
          match List.assoc_opt p own with
          | Some v -> (p, v) :: List.remove_assoc p acc
          | None -> acc) (List.filter (fun (p, _) -> List.mem p inherited) parent_decls) inherited in
      Array.iter (fun k -> visit k passed vars) e.elems
    end else Array.iter (fun k -> visit k [] vars) e.elems in
  visit root [] []

(* ---- the whole: tokens in, tokens out ---- *)

(* a length in px, roughly (px, em) *)
let px_of v =
  let v = lower (String.trim v) in
  let num s = float_of_string_opt (String.trim s) in
  if String.ends_with ~suffix:"px" v then num (String.sub v 0 (String.length v - 2))
  else if String.ends_with ~suffix:"em" v then
    Option.map (fun f -> f *. 16.) (num (String.sub v 0 (String.length v - 2)))
  else num v

let hidden (e : element) =
  let d p = Option.map (fun v -> lower (String.trim v)) (List.assoc_opt p e.decls) in
  List.mem_assoc "hidden" e.eattrs
  || d "display" = Some "none"
  || (match d "visibility" with Some ("hidden" | "collapse") -> true | _ -> false)
  || (match Option.bind (d "opacity") float_of_string_opt with Some o -> o < 0.05 | None -> false)
  (* "visually hidden": out of the flow and clipped away, 1 px, or far off *)
  || (match d "position" with
      | Some ("absolute" | "fixed") ->
        (match d "clip" with Some c -> String.starts_with ~prefix:"rect(" c | None -> false)
        || (match d "clip-path" with Some c -> String.starts_with ~prefix:"inset(" c | None -> false)
        || (match Option.bind (d "width") px_of, Option.bind (d "height") px_of with
            | Some w, Some h -> w <= 1. && h <= 1. | _ -> false)
        || List.exists (fun p -> match Option.bind (d p) px_of with Some x -> x <= -500. | None -> false)
             [ "left"; "top" ]
      | _ -> false)

(* [sheet href]: a <link>'s style sheet, if the browser has it *)
let apply ?(sheet = fun _ -> None) ~px tokens =
  let t0 = Unix.gettimeofday () in
  (* the style sheets, in their order *)
  let order = ref 0 in
  let rules = ref [] and in_style = ref None in
  List.iter (function
      | Html.Start ("style", a) ->
        let media = Option.value (attr "media" a) ~default:"all" in
        in_style := Some (media_holds ~px media)
      | Html.Text s when !in_style <> None ->
        if !in_style = Some true then rules := List.rev_append (parse_sheet ~px ~order s) !rules
      | Html.End "style" -> in_style := None
      | Html.Start ("link", a) ->
        let rels = String.split_on_char ' ' (lower (Option.value (attr "rel" a) ~default:"")) in
        let media = Option.value (attr "media" a) ~default:"all" in
        if List.mem "stylesheet" rels && not (List.mem "alternate" rels) && media_holds ~px media then
          (match Option.bind (attr "href" a) sheet with
           | Some css -> rules := List.rev_append (parse_sheet ~px ~order css) !rules
           | None -> ())
      | _ -> ()) tokens;
  let t1 = Unix.gettimeofday () in
  let root = build tokens in
  let t2 = Unix.gettimeofday () in
  compute ~rules:(List.rev !rules) root;
  let t3 = Unix.gettimeofday () in
  if Sys.getenv_opt "BROWSER_TIMES" <> None then
    Printf.eprintf "css: %d rules read %.0f ms, tree %.0f ms, cascade %.0f ms\n%!"
      (List.length !rules) ((t1 -. t0) *. 1000.) ((t2 -. t1) *. 1000.) ((t3 -. t2) *. 1000.);
  let out = ref [] in
  let rec emit e =
    if not (hidden e) then begin
      let css = String.concat "" (List.map (fun (p, v) -> p ^ ":" ^ v ^ ";") (List.rev e.decls)) in
      let a = List.filter (fun (k, _) -> k <> "x-css") e.eattrs in
      out := Html.Start (e.name, if css = "" then a else a @ [ ("x-css", css) ]) :: !out;
      List.iter (function E k -> emit k | T s -> out := Html.Text s :: !out) e.kids;
      if not (List.mem e.name void) then out := Html.End e.name :: !out
    end in
  List.iter (function E k -> emit k | T s -> out := Html.Text s :: !out) root.kids;
  List.rev !out

(* the <link rel=stylesheet> a page names, for the browser to fetch *)
let links ~px tokens =
  List.filter_map (function
      | Html.Start ("link", a) ->
        let rels = String.split_on_char ' ' (lower (Option.value (attr "rel" a) ~default:"")) in
        let media = Option.value (attr "media" a) ~default:"all" in
        if List.mem "stylesheet" rels && not (List.mem "alternate" rels) && media_holds ~px media
        then attr "href" a else None
      | _ -> None) tokens

(* a property of an element, as apply left it in "x-css" *)
let get attrs prop =
  match attr "x-css" attrs with
  | None -> None
  | Some s ->
    List.find_map (fun d ->
        match String.index_opt d ':' with
        | Some i when String.sub d 0 i = prop -> Some (String.sub d (i + 1) (String.length d - i - 1))
        | _ -> None) (String.split_on_char ';' s)
