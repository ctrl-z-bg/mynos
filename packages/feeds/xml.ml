(* Xml: a small, forgiving XML reader, enough for feeds: elements,
   attributes, text, CDATA, the entities (named and numeric); comments,
   declarations and processing instructions skipped. Names keep their
   prefix ("atom:link"). *)

type t = Element of string * (string * string) list * t list | Text of string

let utf8 cp =
  let b = Buffer.create 4 in
  (try Buffer.add_utf_8_uchar b (Uchar.of_int cp) with Invalid_argument _ -> ());
  Buffer.contents b

let entity name =
  match name with
  | "amp" -> "&" | "lt" -> "<" | "gt" -> ">" | "quot" -> "\"" | "apos" -> "'"
  | "nbsp" -> "\u{00A0}" | "mdash" -> "\u{2014}" | "ndash" -> "\u{2013}"
  | "hellip" -> "\u{2026}" | "rsquo" -> "\u{2019}" | "lsquo" -> "\u{2018}"
  | "rdquo" -> "\u{201D}" | "ldquo" -> "\u{201C}" | "copy" -> "\u{00A9}"
  | _ ->
    if String.length name > 1 && name.[0] = '#' then
      let n = if name.[1] = 'x' || name.[1] = 'X'
        then int_of_string_opt ("0x" ^ String.sub name 2 (String.length name - 2))
        else int_of_string_opt (String.sub name 1 (String.length name - 1)) in
      match n with Some n -> utf8 n | None -> "&" ^ name ^ ";"
    else "&" ^ name ^ ";"

(* text with its entities decoded *)
let decode s =
  if not (String.contains s '&') then s
  else begin
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '&' then
        match String.index_from_opt s !i ';' with
        | Some j when j - !i < 12 ->
          Buffer.add_string b (entity (String.sub s (!i + 1) (j - !i - 1))); i := j + 1
        | _ -> Buffer.add_char b '&'; incr i
      else (Buffer.add_char b s.[!i]; incr i)
    done;
    Buffer.contents b
  end

let parse s =
  let n = String.length s in
  let pos = ref 0 in
  let starts p = !pos + String.length p <= n && String.sub s !pos (String.length p) = p in
  let skip_to p =
    let rec go () =
      if !pos >= n then ()
      else if starts p then pos := !pos + String.length p
      else (incr pos; go ()) in
    go () in
  let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let name () =
    let st = !pos in
    while !pos < n && not (is_space s.[!pos]) && s.[!pos] <> '>' && s.[!pos] <> '/'
          && s.[!pos] <> '=' do incr pos done;
    String.sub s st (!pos - st) in
  let spaces () = while !pos < n && is_space s.[!pos] do incr pos done in
  (* the children up to the end tag of [parent] *)
  let rec children parent =
    let items = ref [] in
    let text = Buffer.create 64 in
    let flush () =
      if Buffer.length text > 0 then begin
        items := Text (decode (Buffer.contents text)) :: !items; Buffer.clear text end in
    let rec go () =
      if !pos >= n then ()
      else if starts "<![CDATA[" then begin
        pos := !pos + 9;
        let st = !pos in
        skip_to "]]>";
        Buffer.add_string text (String.sub s st (max 0 (!pos - 3 - st)));
        (* decoded with the text around it: a feed's CDATA is HTML, whose
           entities are wanted decoded anyway *)
        go ()
      end
      else if starts "<!--" then (skip_to "-->"; go ())
      else if starts "<?" || starts "<!" then (skip_to ">"; go ())
      else if starts "</" then begin
        pos := !pos + 2;
        let _ = name () in
        skip_to ">"
        (* a mismatched end tag ends the element anyway: forgiving *)
      end
      else if s.[!pos] = '<' then begin
        flush ();
        incr pos;
        let tag = name () in
        let attrs = ref [] in
        let rec attributes () =
          spaces ();
          if !pos < n && s.[!pos] <> '>' && s.[!pos] <> '/' then begin
            let k = name () in
            spaces ();
            let v =
              if !pos < n && s.[!pos] = '=' then begin
                incr pos; spaces ();
                if !pos < n && (s.[!pos] = '"' || s.[!pos] = '\'') then begin
                  let q = s.[!pos] in
                  incr pos;
                  let st = !pos in
                  while !pos < n && s.[!pos] <> q do incr pos done;
                  let v = String.sub s st (!pos - st) in
                  incr pos; decode v
                end else name ()
              end else "" in
            if k <> "" then attrs := (k, v) :: !attrs else incr pos;
            attributes ()
          end in
        attributes ();
        if starts "/>" then begin
          pos := !pos + 2;
          items := Element (tag, List.rev !attrs, []) :: !items
        end else begin
          if !pos < n then incr pos;
          let kids = children tag in
          items := Element (tag, List.rev !attrs, kids) :: !items
        end;
        go ()
      end
      else (Buffer.add_char text s.[!pos]; incr pos; go ()) in
    ignore parent;
    go ();
    flush ();
    List.rev !items in
  match List.filter (function Element _ -> true | Text _ -> false) (children "") with
  | e :: _ -> e
  | [] -> failwith "no XML element"

(* {1 Reading} *)

let local name = match String.rindex_opt name ':' with Some i -> String.sub name (i + 1) (String.length name - i - 1) | None -> name

let tag = function Element (t, _, _) -> local t | Text _ -> ""
let attr k = function Element (_, a, _) -> List.assoc_opt k a | Text _ -> None
let kids = function Element (_, _, k) -> k | Text _ -> []
let child name e = List.find_opt (fun c -> tag c = name) (kids e)
let children name e = List.filter (fun c -> tag c = name) (kids e)

let rec text e =
  match e with
  | Text t -> t
  | Element (_, _, k) -> String.concat "" (List.map text k)
