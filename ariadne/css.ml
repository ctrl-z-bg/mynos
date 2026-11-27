(* CSS Syntax Level 3: the tokenizer (4) and the parser (5), on UTF-8 text.
   Code points beyond ASCII are name characters, as the specification says,
   so the tokenizer works on bytes, like Ariadne's HTML tokenizer. *)

type token =
  | Ident of string
  | Function of string            (* "name(" : the name, in its case *)
  | At_keyword of string
  | Hash of string * bool         (* the name; true: a valid id ("type id") *)
  | String of string
  | Bad_string
  | Url of string
  | Bad_url
  | Delim of string               (* one code point, as UTF-8 *)
  | Number of float * bool        (* the value; true: an integer *)
  | Percentage of float
  | Dimension of float * string   (* the value, the unit in lower case *)
  | Whitespace
  | Cdo | Cdc | Colon | Semicolon | Comma
  | Lbracket | Rbracket | Lparen | Rparen | Lbrace | Rbrace

(* component values *)
type cv =
  | Tok of token
  | Func of string * cv list      (* name in lower case, arguments *)
  | Block of char * cv list       (* '(' '[' '{' and the contents *)

type decl = { name : string; value : cv list; important : bool }
(* [name]: lower case, except custom properties ("--x"), kept as written *)

type rule =
  | Style of { prelude : cv list; decls : decl list }
  | At of { name : string; prelude : cv list; block : cv list option }

(* ---- the tokenizer ---- *)

let is_digit c = c >= '0' && c <= '9'
let is_hex c = is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
let is_letter c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let is_name_start c = is_letter c || c = '_' || Char.code c >= 0x80
let is_name c = is_name_start c || is_digit c || c = '-'
let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012'

let add_utf8 = Encoding.add_utf8

let tokenize (s : string) : token array =
  let n = String.length s in
  let out = ref [] in
  let pos = ref 0 in
  let peek k = if !pos + k < n then s.[!pos + k] else '\000' in
  let at_end k = !pos + k >= n in
  (* a valid escape: a backslash not followed by a newline *)
  let valid_escape k = not (at_end k) && peek k = '\\' && (at_end (k + 1) || peek (k + 1) <> '\n') in
  let starts_ident k =
    match peek k with
    | '-' -> (not (at_end (k + 1))) && (is_name_start (peek (k + 1)) || peek (k + 1) = '-' || valid_escape (k + 1))
    | '\\' -> valid_escape k
    | c -> (not (at_end k)) && is_name_start c in
  let starts_number k =
    match peek k with
    | '+' | '-' -> is_digit (peek (k + 1)) || (peek (k + 1) = '.' && is_digit (peek (k + 2)))
    | '.' -> is_digit (peek (k + 1))
    | c -> (not (at_end k)) && is_digit c in
  (* after the backslash *)
  let consume_escape b =
    if at_end 0 then add_utf8 b 0xFFFD
    else if is_hex (peek 0) then begin
      let start = !pos in
      while !pos < n && !pos - start < 6 && is_hex s.[!pos] do incr pos done;
      let v = int_of_string ("0x" ^ String.sub s start (!pos - start)) in
      if !pos < n && is_ws s.[!pos] then incr pos;
      add_utf8 b (if v = 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) then 0xFFFD else v)
    end else (Buffer.add_char b s.[!pos]; incr pos) in
  let consume_name () =
    let b = Buffer.create 16 in
    let continue = ref true in
    while !continue && !pos < n do
      let c = s.[!pos] in
      if is_name c then (Buffer.add_char b c; incr pos)
      else if valid_escape 0 then (incr pos; consume_escape b)
      else continue := false
    done;
    Buffer.contents b in
  let consume_number () =
    let start = !pos in
    let integer = ref true in
    if peek 0 = '+' || peek 0 = '-' then incr pos;
    while !pos < n && is_digit s.[!pos] do incr pos done;
    if peek 0 = '.' && is_digit (peek 1) then begin
      integer := false; incr pos;
      while !pos < n && is_digit s.[!pos] do incr pos done
    end;
    if (peek 0 = 'e' || peek 0 = 'E')
       && (is_digit (peek 1) || ((peek 1 = '+' || peek 1 = '-') && is_digit (peek 2))) then begin
      integer := false; pos := !pos + 2;
      while !pos < n && is_digit s.[!pos] do incr pos done
    end;
    let text = String.sub s start (!pos - start) in
    let text = if String.length text > 0 && text.[0] = '+' then String.sub text 1 (String.length text - 1) else text in
    (Option.value (float_of_string_opt text) ~default:0., !integer) in
  let consume_numeric () =
    let v, int = consume_number () in
    if starts_ident 0 then Dimension (v, String.lowercase_ascii (consume_name ()))
    else if peek 0 = '%' then (incr pos; Percentage v)
    else Number (v, int) in
  let consume_string q =
    let b = Buffer.create 32 in
    let result = ref None in
    while !result = None do
      if at_end 0 then result := Some (String (Buffer.contents b))
      else begin
        let c = s.[!pos] in
        if c = q then (incr pos; result := Some (String (Buffer.contents b)))
        else if c = '\n' then result := Some Bad_string
        else if c = '\\' then begin
          if at_end 1 then incr pos
          else if peek 1 = '\n' then pos := !pos + 2
          else (incr pos; consume_escape b)
        end else (Buffer.add_char b c; incr pos)
      end
    done;
    Option.get !result in
  let consume_bad_url () =
    let fin = ref false in
    while not !fin && !pos < n do
      if s.[!pos] = ')' then (incr pos; fin := true)
      else if valid_escape 0 then (incr pos; ignore (consume_escape (Buffer.create 4)))
      else incr pos
    done in
  let consume_url () =
    while !pos < n && is_ws s.[!pos] do incr pos done;
    let b = Buffer.create 64 in
    let result = ref None in
    while !result = None do
      if at_end 0 then result := Some (Url (Buffer.contents b))
      else begin
        let c = s.[!pos] in
        if c = ')' then (incr pos; result := Some (Url (Buffer.contents b)))
        else if is_ws c then begin
          while !pos < n && is_ws s.[!pos] do incr pos done;
          if at_end 0 then result := Some (Url (Buffer.contents b))
          else if s.[!pos] = ')' then (incr pos; result := Some (Url (Buffer.contents b)))
          else (consume_bad_url (); result := Some Bad_url)
        end else if c = '"' || c = '\'' || c = '(' then (consume_bad_url (); result := Some Bad_url)
        else if c = '\\' then begin
          if valid_escape 0 then (incr pos; consume_escape b)
          else (consume_bad_url (); result := Some Bad_url)
        end else (Buffer.add_char b c; incr pos)
      end
    done;
    Option.get !result in
  let consume_ident_like () =
    let name = consume_name () in
    if String.lowercase_ascii name = "url" && peek 0 = '(' then begin
      incr pos;
      while is_ws (peek 0) && is_ws (peek 1) do incr pos done;
      let q k = peek k = '"' || peek k = '\'' in
      if q 0 || (is_ws (peek 0) && q 1) then Function name else consume_url ()
    end else if peek 0 = '(' then (incr pos; Function name)
    else Ident name in
  let emit t = out := t :: !out in
  while !pos < n do
    let c = s.[!pos] in
    if c = '/' && peek 1 = '*' then begin
      (* a comment *)
      pos := !pos + 2;
      while !pos < n && not (s.[!pos] = '*' && peek 1 = '/') do incr pos done;
      pos := min n (!pos + 2)
    end else if is_ws c then begin
      while !pos < n && is_ws s.[!pos] do incr pos done;
      emit Whitespace
    end else if c = '"' || c = '\'' then (incr pos; emit (consume_string c))
    else if c = '#' then begin
      if (not (at_end 1)) && (is_name (peek 1) || valid_escape 1) then begin
        incr pos;
        let id = starts_ident 0 in
        emit (Hash (consume_name (), id))
      end else (incr pos; emit (Delim "#"))
    end
    else if c = '(' then (incr pos; emit Lparen)
    else if c = ')' then (incr pos; emit Rparen)
    else if c = '+' then (if starts_number 0 then emit (consume_numeric ()) else (incr pos; emit (Delim "+")))
    else if c = ',' then (incr pos; emit Comma)
    else if c = '-' then begin
      if starts_number 0 then emit (consume_numeric ())
      else if peek 1 = '-' && peek 2 = '>' then (pos := !pos + 3; emit Cdc)
      else if starts_ident 0 then emit (consume_ident_like ())
      else (incr pos; emit (Delim "-"))
    end
    else if c = '.' then (if starts_number 0 then emit (consume_numeric ()) else (incr pos; emit (Delim ".")))
    else if c = ':' then (incr pos; emit Colon)
    else if c = ';' then (incr pos; emit Semicolon)
    else if c = '<' then begin
      if peek 1 = '!' && peek 2 = '-' && peek 3 = '-' then (pos := !pos + 4; emit Cdo)
      else (incr pos; emit (Delim "<"))
    end
    else if c = '@' then begin
      incr pos;
      if starts_ident 0 then emit (At_keyword (consume_name ())) else emit (Delim "@")
    end
    else if c = '[' then (incr pos; emit Lbracket)
    else if c = ']' then (incr pos; emit Rbracket)
    else if c = '\\' then begin
      if valid_escape 0 then emit (consume_ident_like ()) else (incr pos; emit (Delim "\\"))
    end
    else if c = '{' then (incr pos; emit Lbrace)
    else if c = '}' then (incr pos; emit Rbrace)
    else if is_digit c then emit (consume_numeric ())
    else if is_name_start c then emit (consume_ident_like ())
    else begin
      (* a delimiter: one code point *)
      let len = let b = Char.code c in if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4 in
      let len = min len (n - !pos) in
      emit (Delim (String.sub s !pos len)); pos := !pos + len
    end
  done;
  Array.of_list (List.rev !out)

(* ---- the parser ---- *)

type stream = { toks : token array; mutable i : int }

let peek st = if st.i < Array.length st.toks then Some st.toks.(st.i) else None
let advance st = st.i <- st.i + 1

(* one component value; blocks and functions with their contents. A loop
   with an explicit stack: nesting is not a recursion of the parser *)
let rec component st =
  match peek st with
  | None -> None
  | Some t ->
    advance st;
    match t with
    | Lbrace | Lbracket | Lparen ->
      let close = match t with Lbrace -> Rbrace | Lbracket -> Rbracket | _ -> Rparen in
      let ch = match t with Lbrace -> '{' | Lbracket -> '[' | _ -> '(' in
      Some (Block (ch, until st close))
    | Function name -> Some (Func (String.lowercase_ascii name, until st Rparen))
    | t -> Some (Tok t)

and until st close =
  let acc = ref [] in
  let fin = ref false in
  while not !fin do
    match peek st with
    | None -> fin := true
    | Some t when t = close -> advance st; fin := true
    | Some _ -> (match component st with Some c -> acc := c :: !acc | None -> fin := true)
  done;
  List.rev !acc

let all_components st =
  let acc = ref [] in
  let rec go () = match component st with Some c -> acc := c :: !acc; go () | None -> () in
  go ();
  List.rev !acc

let trim cvs =
  let drop = List.filter (fun _ -> true) in
  let rec ltrim = function Tok Whitespace :: r -> ltrim r | l -> l in
  drop (List.rev (ltrim (List.rev (ltrim cvs))))

(* a declaration from its component values: "name : value [!important]" *)
let declaration cvs =
  match trim cvs with
  | Tok (Ident name) :: rest ->
    let rec after_colon = function
      | Tok Whitespace :: r -> after_colon r
      | Tok Colon :: r -> Some r
      | _ -> None in
    (match after_colon rest with
     | None -> None
     | Some value ->
       let value = trim value in
       (* "! important" at the end *)
       let rv = List.rev value in
       let rec strip_ws = function Tok Whitespace :: r -> strip_ws r | l -> l in
       let important, value =
         match strip_ws rv with
         | Tok (Ident imp) :: r when String.lowercase_ascii imp = "important" ->
           (match strip_ws r with
            | Tok (Delim "!") :: r2 -> (true, List.rev (strip_ws r2))
            | _ -> (false, value))
         | _ -> (false, value) in
       let name = if String.length name > 2 && String.sub name 0 2 = "--" then name
         else String.lowercase_ascii name in
       Some { name; value; important })
  | _ -> None

(* a list of declarations: split at top-level semicolons; nested rules
   (CSS nesting) and at-rules inside are left out *)
let declarations cvs =
  let rec split acc cur = function
    | [] -> List.rev (List.rev cur :: acc)
    | Tok Semicolon :: rest -> split (List.rev cur :: acc) [] rest
    | Block ('{', _) :: rest when cur <> [] && (match trim (List.rev cur) with Tok (Ident _) :: _ -> false | _ -> true) ->
      (* a nested rule: skipped *)
      split acc [] rest
    | c :: rest -> split acc (c :: cur) rest in
  List.filter_map (fun d ->
      match trim d with
      | [] -> None
      | Tok (At_keyword _) :: _ -> None
      | d -> declaration d) (split [] [] cvs)

let rec rules_of cvs =
  (* top level, or an at-rule's block: rules up to "{...}" or ";" *)
  let rules = ref [] in
  let rec go = function
    | [] -> ()
    | (Tok (Whitespace | Cdo | Cdc)) :: rest -> go rest
    | Tok (At_keyword name) :: rest ->
      let rec prelude acc = function
        | [] -> (List.rev acc, None, [])
        | Tok Semicolon :: r -> (List.rev acc, None, r)
        | Block ('{', b) :: r -> (List.rev acc, Some b, r)
        | c :: r -> prelude (c :: acc) r in
      let p, block, rest = prelude [] rest in
      rules := At { name = String.lowercase_ascii name; prelude = trim p; block } :: !rules;
      go rest
    | l ->
      let rec prelude acc = function
        | [] -> None
        | Block ('{', b) :: r -> Some (List.rev acc, b, r)
        | c :: r -> prelude (c :: acc) r in
      (match prelude [] l with
       | Some (p, b, rest) ->
         rules := Style { prelude = trim p; decls = declarations b } :: !rules;
         go rest
       | None -> ()) in
  go cvs;
  List.rev !rules

and parse_stylesheet text =
  rules_of (all_components { toks = tokenize text; i = 0 })

let parse_declarations text = declarations (all_components { toks = tokenize text; i = 0 })

let parse_values text = trim (all_components { toks = tokenize text; i = 0 })

(* a rule list inside an at-rule's block (@media, @supports, @layer) *)
let block_rules cvs = rules_of cvs

(* ---- printing values back (for custom properties and the tests) ---- *)

let rec to_string cvs =
  let b = Buffer.create 64 in
  let num v = if Float.is_integer v then Printf.sprintf "%.0f" v else Printf.sprintf "%g" v in
  List.iter (function
      | Tok t -> Buffer.add_string b (match t with
          | Ident s -> s | At_keyword s -> "@" ^ s | Hash (s, _) -> "#" ^ s
          | String s -> "\"" ^ s ^ "\"" | Bad_string -> "" | Url u -> "url(" ^ u ^ ")" | Bad_url -> ""
          | Delim d -> d | Number (v, _) -> num v | Percentage v -> num v ^ "%"
          | Dimension (v, u) -> num v ^ u | Whitespace -> " " | Cdo -> "<!--" | Cdc -> "-->"
          | Colon -> ":" | Semicolon -> ";" | Comma -> "," | Lbracket -> "[" | Rbracket -> "]"
          | Lparen -> "(" | Rparen -> ")" | Lbrace -> "{" | Rbrace -> "}" | Function f -> f ^ "(")
      | Func (f, args) -> Buffer.add_string b (f ^ "(" ^ to_string args ^ ")")
      | Block (c, inner) ->
        let close = match c with '{' -> "}" | '[' -> "]" | _ -> ")" in
        Buffer.add_string b (String.make 1 c ^ to_string inner ^ close)) cvs;
  Buffer.contents b
