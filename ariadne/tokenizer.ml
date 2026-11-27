(* The HTML Standard's tokenizer (13.2.5): see tokenizer.mli. Each state
   below is the specification's, in its order; "reconsume" is [back t]. *)

type token =
  | Doctype of { name : string option; public_id : string option;
                 system_id : string option; force_quirks : bool }
  | Start_tag of { name : string; attrs : (string * string) list; self_closing : bool }
  | End_tag of string
  | Comment of string
  | Pi of { target : string; data : string }   (* a processing instruction: <?target data> *)
  | Chars of string
  | Eof

type state =
  | Data | Rcdata | Rawtext | Script_data | Plaintext
  | Tag_open | End_tag_open | Tag_name
  | Rcdata_lt | Rcdata_end_tag_open | Rcdata_end_tag_name
  | Rawtext_lt | Rawtext_end_tag_open | Rawtext_end_tag_name
  | Script_lt | Script_end_tag_open | Script_end_tag_name
  | Script_escape_start | Script_escape_start_dash
  | Script_escaped | Script_escaped_dash | Script_escaped_dash_dash
  | Script_escaped_lt | Script_escaped_end_tag_open | Script_escaped_end_tag_name
  | Script_double_escape_start | Script_double_escaped | Script_double_escaped_dash
  | Script_double_escaped_dash_dash | Script_double_escaped_lt | Script_double_escape_end
  | Before_attr_name | Attr_name | After_attr_name | Before_attr_value
  | Attr_value_dq | Attr_value_sq | Attr_value_unquoted | After_attr_value_quoted
  | Self_closing_start_tag | Bogus_comment | Markup_declaration_open
  | Comment_start | Comment_start_dash | Comment_state | Comment_lt | Comment_lt_bang
  | Comment_lt_bang_dash | Comment_lt_bang_dash_dash | Comment_end_dash | Comment_end
  | Comment_end_bang
  | Doctype_state | Before_doctype_name | Doctype_name | After_doctype_name
  | After_doctype_public_keyword | Before_doctype_public_id | Doctype_public_id_dq
  | Doctype_public_id_sq | After_doctype_public_id | Between_doctype_public_and_system
  | After_doctype_system_keyword | Before_doctype_system_id | Doctype_system_id_dq
  | Doctype_system_id_sq | After_doctype_system_id | Bogus_doctype
  | Cdata_section | Cdata_section_bracket | Cdata_section_end
  | Pi_open | Pi_target | After_pi_target | Pi_data | Pi_questionable
  | Char_ref | Named_char_ref | Ambiguous_ampersand | Numeric_char_ref
  | Hex_char_ref_start | Decimal_char_ref_start | Hex_char_ref | Decimal_char_ref
  | Numeric_char_ref_end

type t = {
  s : string;
  n : int;
  mutable pos : int;
  mutable state : state;
  mutable return_state : state;
  queue : token Queue.t;
  chars : Buffer.t;                 (* characters not emitted yet *)
  tmp : Buffer.t;                   (* the specification's temporary buffer *)
  (* the tag being read *)
  mutable is_end : bool;
  tag_name : Buffer.t;
  mutable attrs : (string * string) list;     (* reversed *)
  mutable has_attr : bool;                     (* an attribute is being read *)
  attr_name : Buffer.t;
  attr_value : Buffer.t;
  mutable self_closing : bool;
  comment : Buffer.t;
  mutable pi_target : string;
  pi_data : Buffer.t;
  (* the DOCTYPE being read *)
  dt_name : Buffer.t; mutable dt_has_name : bool;
  dt_public : Buffer.t; mutable dt_has_public : bool;
  dt_system : Buffer.t; mutable dt_has_system : bool;
  mutable force_quirks : bool;
  mutable last_start_tag : string;
  mutable code : int;               (* a numeric character reference's *)
  mutable allow_cdata : bool;
}

(* ---- the named character references ---- *)

let entities : (string, int array) Hashtbl.t =
  let h = Hashtbl.create 4096 in
  List.iter (fun (k, v) -> Hashtbl.replace h k v) Entities_data.all;
  h

let max_entity = List.fold_left (fun m (k, _) -> max m (String.length k)) 0 Entities_data.all

(* ---- characters ---- *)

let eof = -1
let is_alpha c = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
let is_upper c = c >= 0x41 && c <= 0x5A
let is_digit c = c >= 0x30 && c <= 0x39
let is_hex c = is_digit c || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)
let is_alnum c = is_alpha c || is_digit c
let is_space c = c = 0x09 || c = 0x0A || c = 0x0C || c = 0x20
let lower c = if is_upper c then c + 0x20 else c

let add_utf8 b c =
  let add x = Buffer.add_char b (Char.unsafe_chr x) in
  if c < 0x80 then add c
  else if c < 0x800 then (add (0xC0 lor (c lsr 6)); add (0x80 lor (c land 0x3F)))
  else if c < 0x10000 then
    (add (0xE0 lor (c lsr 12)); add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))
  else
    (add (0xF0 lor (c lsr 18)); add (0x80 lor ((c lsr 12) land 0x3F));
     add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))

let replacement = "\xEF\xBF\xBD"

(* CR LF and CR to LF *)
let normalize s =
  if not (String.contains s '\r') then s
  else begin
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '\r' then begin
        Buffer.add_char b '\n';
        if !i + 1 < n && s.[!i + 1] = '\n' then incr i
      end else Buffer.add_char b s.[!i];
      incr i
    done;
    Buffer.contents b
  end

let create s =
  let s = normalize s in
  let buf () = Buffer.create 32 in
  { s; n = String.length s; pos = 0; state = Data; return_state = Data; queue = Queue.create ();
    chars = Buffer.create 256; tmp = buf (); is_end = false; tag_name = buf (); attrs = [];
    has_attr = false; attr_name = buf (); attr_value = buf (); self_closing = false;
    comment = buf (); pi_target = ""; pi_data = buf (); dt_name = buf (); dt_has_name = false; dt_public = buf ();
    dt_has_public = false; dt_system = buf (); dt_has_system = false; force_quirks = false;
    last_start_tag = ""; code = 0; allow_cdata = false }

let set_state t st = t.state <- st
let set_last_start_tag t name = t.last_start_tag <- name
let set_allow_cdata t b = t.allow_cdata <- b

(* ---- reading ---- *)

let consume t = if t.pos < t.n then (let c = Char.code t.s.[t.pos] in t.pos <- t.pos + 1; c) else eof
let back t c = if c <> eof then t.pos <- t.pos - 1

(* the next characters are [word] (ASCII case-insensitively if [ci]): they
   are consumed *)
let next_is ?(ci = false) t word =
  let m = String.length word in
  t.pos + m <= t.n
  && (let sub = String.sub t.s t.pos m in
      if ci then String.lowercase_ascii sub = String.lowercase_ascii word else sub = word)
  && (t.pos <- t.pos + m; true)

(* ---- emitting ---- *)

let emit_char t c = Buffer.add_char t.chars (Char.unsafe_chr c)
let emit_string t s = Buffer.add_string t.chars s

let flush_chars t =
  if Buffer.length t.chars > 0 then begin
    Queue.add (Chars (Buffer.contents t.chars)) t.queue;
    Buffer.clear t.chars
  end

let emit t tok = flush_chars t; Queue.add tok t.queue

let start_tag t is_end =
  t.is_end <- is_end; Buffer.clear t.tag_name; t.attrs <- []; t.has_attr <- false;
  t.self_closing <- false

(* the attribute being read, kept unless its name was seen already *)
let commit_attr t =
  if t.has_attr then begin
    let name = Buffer.contents t.attr_name in
    if not (List.mem_assoc name t.attrs) then t.attrs <- (name, Buffer.contents t.attr_value) :: t.attrs;
    t.has_attr <- false
  end

let start_attr t =
  commit_attr t;
  t.has_attr <- true; Buffer.clear t.attr_name; Buffer.clear t.attr_value

let emit_tag t =
  commit_attr t;
  let name = Buffer.contents t.tag_name in
  if t.is_end then emit t (End_tag name)
  else begin
    t.last_start_tag <- name;
    emit t (Start_tag { name; attrs = List.rev t.attrs; self_closing = t.self_closing })
  end

let emit_comment t = emit t (Comment (Buffer.contents t.comment))

(* "convert the temporary buffer to a comment": an invalid processing
   instruction's target, after "?", begins a bogus comment *)
let pi_to_comment t =
  Buffer.clear t.comment; Buffer.add_char t.comment '?'; Buffer.add_buffer t.comment t.tmp

let emit_pi t = emit t (Pi { target = t.pi_target; data = Buffer.contents t.pi_data })

let start_doctype t =
  Buffer.clear t.dt_name; Buffer.clear t.dt_public; Buffer.clear t.dt_system;
  t.dt_has_name <- false; t.dt_has_public <- false; t.dt_has_system <- false;
  t.force_quirks <- false

let emit_doctype t =
  let opt has b = if has then Some (Buffer.contents b) else None in
  emit t (Doctype { name = opt t.dt_has_name t.dt_name; public_id = opt t.dt_has_public t.dt_public;
                    system_id = opt t.dt_has_system t.dt_system; force_quirks = t.force_quirks })

let appropriate t = Buffer.contents t.tag_name = t.last_start_tag

let in_attr t = match t.return_state with
  | Attr_value_dq | Attr_value_sq | Attr_value_unquoted -> true | _ -> false

let flush_char_ref t =
  if in_attr t then Buffer.add_buffer t.attr_value t.tmp else Buffer.add_buffer t.chars t.tmp

(* "anything else" in the end tag name states of RCDATA, RAWTEXT and the
   script states: "</" and the name read so far, as characters *)
let not_an_end_tag t st c =
  emit_string t "</"; Buffer.add_buffer t.chars t.tmp; back t c; t.state <- st

let numeric_end t =
  let c = t.code in
  let c =
    if c = 0 then 0xFFFD
    else if c > 0x10FFFF then 0xFFFD
    else if c >= 0xD800 && c <= 0xDFFF then 0xFFFD
    else if c >= 0x80 && c <= 0x9F then
      (match Encoding.cp1252.(c - 0x80) with x when x <> c || List.mem c [ 0x81; 0x8D; 0x8F; 0x90; 0x9D ] -> x | x -> x)
    else c in
  Buffer.clear t.tmp; add_utf8 t.tmp c; flush_char_ref t; t.state <- t.return_state

(* ---- the states ---- *)

(* the states that copy most of their input: a run of ordinary bytes is
   copied at once, without going through the state machine byte by byte *)
let fast_run t stop dst =
  let start = t.pos in
  while t.pos < t.n && not (stop (String.unsafe_get t.s t.pos)) do t.pos <- t.pos + 1 done;
  if t.pos > start then Buffer.add_substring dst t.s start (t.pos - start)

let step t =
  (match t.state with
   | Data | Rcdata -> fast_run t (fun c -> c = '<' || c = '&' || c = '\000') t.chars
   | Rawtext | Script_data -> fast_run t (fun c -> c = '<' || c = '\000') t.chars
   | Plaintext -> fast_run t (fun c -> c = '\000') t.chars
   | Attr_value_dq -> fast_run t (fun c -> c = '"' || c = '&' || c = '\000') t.attr_value
   | Attr_value_sq -> fast_run t (fun c -> c = '\'' || c = '&' || c = '\000') t.attr_value
   | Comment_state -> fast_run t (fun c -> c = '<' || c = '-' || c = '\000') t.comment
   | _ -> ());
  let c = consume t in
  match t.state with
  | Data ->
    (match c with
     | 0x26 -> t.return_state <- Data; t.state <- Char_ref
     | 0x3C -> t.state <- Tag_open
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Rcdata ->
    (match c with
     | 0x26 -> t.return_state <- Rcdata; t.state <- Char_ref
     | 0x3C -> t.state <- Rcdata_lt
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Rawtext ->
    (match c with
     | 0x3C -> t.state <- Rawtext_lt
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Script_data ->
    (match c with
     | 0x3C -> t.state <- Script_lt
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Plaintext ->
    (match c with
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Tag_open ->
    (match c with
     | 0x21 -> t.state <- Markup_declaration_open
     | 0x2F -> t.state <- End_tag_open
     | c when is_alpha c -> start_tag t false; back t c; t.state <- Tag_name
     | 0x3F -> Buffer.clear t.tmp; t.state <- Pi_open
     | -1 -> emit_char t 0x3C; emit t Eof
     | c -> emit_char t 0x3C; back t c; t.state <- Data)
  | End_tag_open ->
    (match c with
     | c when is_alpha c -> start_tag t true; back t c; t.state <- Tag_name
     | 0x3E -> t.state <- Data
     | -1 -> emit_string t "</"; emit t Eof
     | c -> Buffer.clear t.comment; back t c; t.state <- Bogus_comment)
  | Tag_name ->
    (match c with
     | c when is_space c -> t.state <- Before_attr_name
     | 0x2F -> t.state <- Self_closing_start_tag
     | 0x3E -> t.state <- Data; emit_tag t
     | 0 -> Buffer.add_string t.tag_name replacement
     | -1 -> emit t Eof
     | c -> Buffer.add_char t.tag_name (Char.unsafe_chr (lower c)))
  | Rcdata_lt ->
    if c = 0x2F then (Buffer.clear t.tmp; t.state <- Rcdata_end_tag_open)
    else (emit_char t 0x3C; back t c; t.state <- Rcdata)
  | Rcdata_end_tag_open ->
    if is_alpha c then (start_tag t true; back t c; t.state <- Rcdata_end_tag_name)
    else (emit_string t "</"; back t c; t.state <- Rcdata)
  | Rawtext_lt ->
    if c = 0x2F then (Buffer.clear t.tmp; t.state <- Rawtext_end_tag_open)
    else (emit_char t 0x3C; back t c; t.state <- Rawtext)
  | Rawtext_end_tag_open ->
    if is_alpha c then (start_tag t true; back t c; t.state <- Rawtext_end_tag_name)
    else (emit_string t "</"; back t c; t.state <- Rawtext)
  | Rcdata_end_tag_name | Rawtext_end_tag_name | Script_end_tag_name | Script_escaped_end_tag_name ->
    let fallback = match t.state with
      | Rcdata_end_tag_name -> Rcdata | Rawtext_end_tag_name -> Rawtext
      | Script_end_tag_name -> Script_data | _ -> Script_escaped in
    (match c with
     | c when is_space c && appropriate t -> t.state <- Before_attr_name
     | 0x2F when appropriate t -> t.state <- Self_closing_start_tag
     | 0x3E when appropriate t -> t.state <- Data; emit_tag t
     | c when is_alpha c ->
       Buffer.add_char t.tag_name (Char.unsafe_chr (lower c));
       Buffer.add_char t.tmp (Char.unsafe_chr c)
     | c -> not_an_end_tag t fallback c)
  | Script_lt ->
    (match c with
     | 0x2F -> Buffer.clear t.tmp; t.state <- Script_end_tag_open
     | 0x21 -> t.state <- Script_escape_start; emit_string t "<!"
     | c -> emit_char t 0x3C; back t c; t.state <- Script_data)
  | Script_end_tag_open ->
    if is_alpha c then (start_tag t true; back t c; t.state <- Script_end_tag_name)
    else (emit_string t "</"; back t c; t.state <- Script_data)
  | Script_escape_start ->
    if c = 0x2D then (t.state <- Script_escape_start_dash; emit_char t 0x2D)
    else (back t c; t.state <- Script_data)
  | Script_escape_start_dash ->
    if c = 0x2D then (t.state <- Script_escaped_dash_dash; emit_char t 0x2D)
    else (back t c; t.state <- Script_data)
  | Script_escaped ->
    (match c with
     | 0x2D -> t.state <- Script_escaped_dash; emit_char t 0x2D
     | 0x3C -> t.state <- Script_escaped_lt
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Script_escaped_dash ->
    (match c with
     | 0x2D -> t.state <- Script_escaped_dash_dash; emit_char t 0x2D
     | 0x3C -> t.state <- Script_escaped_lt
     | 0 -> t.state <- Script_escaped; emit_string t replacement
     | -1 -> emit t Eof
     | c -> t.state <- Script_escaped; emit_char t c)
  | Script_escaped_dash_dash ->
    (match c with
     | 0x2D -> emit_char t 0x2D
     | 0x3C -> t.state <- Script_escaped_lt
     | 0x3E -> t.state <- Script_data; emit_char t 0x3E
     | 0 -> t.state <- Script_escaped; emit_string t replacement
     | -1 -> emit t Eof
     | c -> t.state <- Script_escaped; emit_char t c)
  | Script_escaped_lt ->
    (match c with
     | 0x2F -> Buffer.clear t.tmp; t.state <- Script_escaped_end_tag_open
     | c when is_alpha c ->
       Buffer.clear t.tmp; emit_char t 0x3C; back t c; t.state <- Script_double_escape_start
     | c -> emit_char t 0x3C; back t c; t.state <- Script_escaped)
  | Script_escaped_end_tag_open ->
    if is_alpha c then (start_tag t true; back t c; t.state <- Script_escaped_end_tag_name)
    else (emit_string t "</"; back t c; t.state <- Script_escaped)
  | Script_double_escape_start | Script_double_escape_end ->
    let start = t.state = Script_double_escape_start in
    (match c with
     | c when is_space c || c = 0x2F || c = 0x3E ->
       let script = Buffer.contents t.tmp = "script" in
       t.state <- (if start = script then Script_double_escaped else Script_escaped);
       emit_char t c
     | c when is_alpha c ->
       Buffer.add_char t.tmp (Char.unsafe_chr (lower c)); emit_char t c
     | c -> back t c; t.state <- (if start then Script_escaped else Script_double_escaped))
  | Script_double_escaped ->
    (match c with
     | 0x2D -> t.state <- Script_double_escaped_dash; emit_char t 0x2D
     | 0x3C -> t.state <- Script_double_escaped_lt; emit_char t 0x3C
     | 0 -> emit_string t replacement
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Script_double_escaped_dash ->
    (match c with
     | 0x2D -> t.state <- Script_double_escaped_dash_dash; emit_char t 0x2D
     | 0x3C -> t.state <- Script_double_escaped_lt; emit_char t 0x3C
     | 0 -> t.state <- Script_double_escaped; emit_string t replacement
     | -1 -> emit t Eof
     | c -> t.state <- Script_double_escaped; emit_char t c)
  | Script_double_escaped_dash_dash ->
    (match c with
     | 0x2D -> emit_char t 0x2D
     | 0x3C -> t.state <- Script_double_escaped_lt; emit_char t 0x3C
     | 0x3E -> t.state <- Script_data; emit_char t 0x3E
     | 0 -> t.state <- Script_double_escaped; emit_string t replacement
     | -1 -> emit t Eof
     | c -> t.state <- Script_double_escaped; emit_char t c)
  | Script_double_escaped_lt ->
    if c = 0x2F then (Buffer.clear t.tmp; t.state <- Script_double_escape_end; emit_char t 0x2F)
    else (back t c; t.state <- Script_double_escaped)
  | Before_attr_name ->
    (match c with
     | c when is_space c -> ()
     | 0x2F | 0x3E | -1 -> back t c; t.state <- After_attr_name
     | 0x3D -> start_attr t; Buffer.add_char t.attr_name '='; t.state <- Attr_name
     | c -> start_attr t; back t c; t.state <- Attr_name)
  | Attr_name ->
    (match c with
     | c when is_space c || c = 0x2F || c = 0x3E || c = eof -> back t c; t.state <- After_attr_name
     | 0x3D -> t.state <- Before_attr_value
     | 0 -> Buffer.add_string t.attr_name replacement
     | c -> Buffer.add_char t.attr_name (Char.unsafe_chr (lower c)))
  | After_attr_name ->
    (match c with
     | c when is_space c -> ()
     | 0x2F -> t.state <- Self_closing_start_tag
     | 0x3D -> t.state <- Before_attr_value
     | 0x3E -> t.state <- Data; emit_tag t
     | -1 -> emit t Eof
     | c -> start_attr t; back t c; t.state <- Attr_name)
  | Before_attr_value ->
    (match c with
     | c when is_space c -> ()
     | 0x22 -> t.state <- Attr_value_dq
     | 0x27 -> t.state <- Attr_value_sq
     | 0x3E -> t.state <- Data; emit_tag t
     | c -> back t c; t.state <- Attr_value_unquoted)
  | Attr_value_dq | Attr_value_sq ->
    let quote = if t.state = Attr_value_dq then 0x22 else 0x27 in
    (match c with
     | c when c = quote -> t.state <- After_attr_value_quoted
     | 0x26 -> t.return_state <- t.state; t.state <- Char_ref
     | 0 -> Buffer.add_string t.attr_value replacement
     | -1 -> emit t Eof
     | c -> Buffer.add_char t.attr_value (Char.unsafe_chr c))
  | Attr_value_unquoted ->
    (match c with
     | c when is_space c -> t.state <- Before_attr_name
     | 0x26 -> t.return_state <- Attr_value_unquoted; t.state <- Char_ref
     | 0x3E -> t.state <- Data; emit_tag t
     | 0 -> Buffer.add_string t.attr_value replacement
     | -1 -> emit t Eof
     | c -> Buffer.add_char t.attr_value (Char.unsafe_chr c))
  | After_attr_value_quoted ->
    (match c with
     | c when is_space c -> t.state <- Before_attr_name
     | 0x2F -> t.state <- Self_closing_start_tag
     | 0x3E -> t.state <- Data; emit_tag t
     | -1 -> emit t Eof
     | c -> back t c; t.state <- Before_attr_name)
  | Self_closing_start_tag ->
    (match c with
     | 0x3E -> t.self_closing <- true; t.state <- Data; emit_tag t
     | -1 -> emit t Eof
     | c -> back t c; t.state <- Before_attr_name)
  | Bogus_comment ->
    (match c with
     | 0x3E -> t.state <- Data; emit_comment t
     | -1 -> emit_comment t; emit t Eof
     | 0 -> Buffer.add_string t.comment replacement
     | c -> Buffer.add_char t.comment (Char.unsafe_chr c))
  | Markup_declaration_open ->
    back t c;
    if next_is t "--" then (Buffer.clear t.comment; t.state <- Comment_start)
    else if next_is ~ci:true t "DOCTYPE" then t.state <- Doctype_state
    else if t.allow_cdata && next_is t "[CDATA[" then t.state <- Cdata_section
    else if next_is t "[CDATA[" then (Buffer.clear t.comment; Buffer.add_string t.comment "[CDATA[";
                                      t.state <- Bogus_comment)
    else (Buffer.clear t.comment; t.state <- Bogus_comment)
  | Comment_start ->
    (match c with
     | 0x2D -> t.state <- Comment_start_dash
     | 0x3E -> t.state <- Data; emit_comment t
     | c -> back t c; t.state <- Comment_state)
  | Comment_start_dash ->
    (match c with
     | 0x2D -> t.state <- Comment_end
     | 0x3E -> t.state <- Data; emit_comment t
     | -1 -> emit_comment t; emit t Eof
     | c -> Buffer.add_char t.comment '-'; back t c; t.state <- Comment_state)
  | Comment_state ->
    (match c with
     | 0x3C -> Buffer.add_char t.comment '<'; t.state <- Comment_lt
     | 0x2D -> t.state <- Comment_end_dash
     | 0 -> Buffer.add_string t.comment replacement
     | -1 -> emit_comment t; emit t Eof
     | c -> Buffer.add_char t.comment (Char.unsafe_chr c))
  | Comment_lt ->
    (match c with
     | 0x21 -> Buffer.add_char t.comment '!'; t.state <- Comment_lt_bang
     | 0x3C -> Buffer.add_char t.comment '<'
     | c -> back t c; t.state <- Comment_state)
  | Comment_lt_bang ->
    if c = 0x2D then t.state <- Comment_lt_bang_dash else (back t c; t.state <- Comment_state)
  | Comment_lt_bang_dash ->
    if c = 0x2D then t.state <- Comment_lt_bang_dash_dash else (back t c; t.state <- Comment_end_dash)
  | Comment_lt_bang_dash_dash ->
    back t c; t.state <- Comment_end
  | Comment_end_dash ->
    (match c with
     | 0x2D -> t.state <- Comment_end
     | -1 -> emit_comment t; emit t Eof
     | c -> Buffer.add_char t.comment '-'; back t c; t.state <- Comment_state)
  | Comment_end ->
    (match c with
     | 0x3E -> t.state <- Data; emit_comment t
     | 0x21 -> t.state <- Comment_end_bang
     | 0x2D -> Buffer.add_char t.comment '-'
     | -1 -> emit_comment t; emit t Eof
     | c -> Buffer.add_string t.comment "--"; back t c; t.state <- Comment_state)
  | Comment_end_bang ->
    (match c with
     | 0x2D -> Buffer.add_string t.comment "--!"; t.state <- Comment_end_dash
     | 0x3E -> t.state <- Data; emit_comment t
     | -1 -> emit_comment t; emit t Eof
     | c -> Buffer.add_string t.comment "--!"; back t c; t.state <- Comment_state)
  | Doctype_state ->
    (match c with
     | c when is_space c -> t.state <- Before_doctype_name
     | 0x3E -> back t c; t.state <- Before_doctype_name
     | -1 -> start_doctype t; t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> back t c; t.state <- Before_doctype_name)
  | Before_doctype_name ->
    (match c with
     | c when is_space c -> ()
     | 0 -> start_doctype t; t.dt_has_name <- true; Buffer.add_string t.dt_name replacement;
       t.state <- Doctype_name
     | 0x3E -> start_doctype t; t.force_quirks <- true; t.state <- Data; emit_doctype t
     | -1 -> start_doctype t; t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> start_doctype t; t.dt_has_name <- true;
       Buffer.add_char t.dt_name (Char.unsafe_chr (lower c)); t.state <- Doctype_name)
  | Doctype_name ->
    (match c with
     | c when is_space c -> t.state <- After_doctype_name
     | 0x3E -> t.state <- Data; emit_doctype t
     | 0 -> Buffer.add_string t.dt_name replacement
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> Buffer.add_char t.dt_name (Char.unsafe_chr (lower c)))
  | After_doctype_name ->
    (match c with
     | c when is_space c -> ()
     | 0x3E -> t.state <- Data; emit_doctype t
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c ->
       back t c;
       if next_is ~ci:true t "PUBLIC" then t.state <- After_doctype_public_keyword
       else if next_is ~ci:true t "SYSTEM" then t.state <- After_doctype_system_keyword
       else (ignore (consume t); t.force_quirks <- true; t.state <- Bogus_doctype))
  | After_doctype_public_keyword | Before_doctype_public_id ->
    let after_keyword = t.state = After_doctype_public_keyword in
    (match c with
     | c when is_space c -> if after_keyword then t.state <- Before_doctype_public_id
     | 0x22 -> t.dt_has_public <- true; Buffer.clear t.dt_public; t.state <- Doctype_public_id_dq
     | 0x27 -> t.dt_has_public <- true; Buffer.clear t.dt_public; t.state <- Doctype_public_id_sq
     | 0x3E -> t.force_quirks <- true; t.state <- Data; emit_doctype t
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> t.force_quirks <- true; back t c; t.state <- Bogus_doctype)
  | Doctype_public_id_dq | Doctype_public_id_sq | Doctype_system_id_dq | Doctype_system_id_sq ->
    let quote = match t.state with Doctype_public_id_dq | Doctype_system_id_dq -> 0x22 | _ -> 0x27 in
    let public = match t.state with Doctype_public_id_dq | Doctype_public_id_sq -> true | _ -> false in
    let b = if public then t.dt_public else t.dt_system in
    (match c with
     | c when c = quote -> t.state <- (if public then After_doctype_public_id else After_doctype_system_id)
     | 0 -> Buffer.add_string b replacement
     | 0x3E -> t.force_quirks <- true; t.state <- Data; emit_doctype t
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> Buffer.add_char b (Char.unsafe_chr c))
  | After_doctype_public_id | Between_doctype_public_and_system ->
    let after = t.state = After_doctype_public_id in
    (match c with
     | c when is_space c -> if after then t.state <- Between_doctype_public_and_system
     | 0x3E -> t.state <- Data; emit_doctype t
     | 0x22 -> t.dt_has_system <- true; Buffer.clear t.dt_system; t.state <- Doctype_system_id_dq
     | 0x27 -> t.dt_has_system <- true; Buffer.clear t.dt_system; t.state <- Doctype_system_id_sq
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> t.force_quirks <- true; back t c; t.state <- Bogus_doctype)
  | After_doctype_system_keyword | Before_doctype_system_id ->
    let after_keyword = t.state = After_doctype_system_keyword in
    (match c with
     | c when is_space c -> if after_keyword then t.state <- Before_doctype_system_id
     | 0x22 -> t.dt_has_system <- true; Buffer.clear t.dt_system; t.state <- Doctype_system_id_dq
     | 0x27 -> t.dt_has_system <- true; Buffer.clear t.dt_system; t.state <- Doctype_system_id_sq
     | 0x3E -> t.force_quirks <- true; t.state <- Data; emit_doctype t
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> t.force_quirks <- true; back t c; t.state <- Bogus_doctype)
  | After_doctype_system_id ->
    (match c with
     | c when is_space c -> ()
     | 0x3E -> t.state <- Data; emit_doctype t
     | -1 -> t.force_quirks <- true; emit_doctype t; emit t Eof
     | c -> back t c; t.state <- Bogus_doctype)
  | Bogus_doctype ->
    (match c with
     | 0x3E -> t.state <- Data; emit_doctype t
     | -1 -> emit_doctype t; emit t Eof
     | _ -> ())
  | Cdata_section ->
    (match c with
     | 0x5D -> t.state <- Cdata_section_bracket
     | -1 -> emit t Eof
     | c -> emit_char t c)
  | Cdata_section_bracket ->
    if c = 0x5D then t.state <- Cdata_section_end
    else (emit_char t 0x5D; back t c; t.state <- Cdata_section)
  | Cdata_section_end ->
    (match c with
     | 0x5D -> emit_char t 0x5D
     | 0x3E -> t.state <- Data
     | c -> emit_string t "]]"; back t c; t.state <- Cdata_section)
  | Pi_open ->
    (match c with
     | c when is_alpha c || c = 0x5F -> back t c; t.state <- Pi_target
     | -1 -> emit t Eof
     | c -> pi_to_comment t; back t c; t.state <- Bogus_comment)
  | Pi_target ->
    (match c with
     | c when is_space c || c = 0x3F || c = 0x3E ->
       let target = Buffer.contents t.tmp in
       let l = String.lowercase_ascii target in
       if l = "xml" || l = "xml-stylesheet" then (pi_to_comment t; back t c; t.state <- Bogus_comment)
       else begin
         t.pi_target <- target; Buffer.clear t.pi_data;
         back t c; t.state <- After_pi_target
       end
     | c when is_alnum c || c = 0x2D || c = 0x5F -> Buffer.add_char t.tmp (Char.unsafe_chr c)
     | -1 -> emit t Eof
     | c -> pi_to_comment t; back t c; t.state <- Bogus_comment)
  | After_pi_target ->
    if not (is_space c) then (back t c; t.state <- Pi_data)
  | Pi_data ->
    (match c with
     | 0x3F -> t.state <- Pi_questionable
     | 0x3E -> t.state <- Data; emit_pi t
     | -1 -> emit t Eof
     | c -> Buffer.add_char t.pi_data (Char.unsafe_chr c))
  | Pi_questionable ->
    (match c with
     | 0x3E -> t.state <- Data; emit_pi t
     | -1 -> emit t Eof
     | c -> Buffer.add_char t.pi_data '?'; back t c; t.state <- Pi_data)
  | Char_ref ->
    Buffer.clear t.tmp; Buffer.add_char t.tmp '&';
    (match c with
     | c when is_alnum c -> back t c; t.state <- Named_char_ref
     | 0x23 -> Buffer.add_char t.tmp '#'; t.state <- Numeric_char_ref
     | c -> flush_char_ref t; back t c; t.state <- t.return_state)
  | Named_char_ref ->
    back t c;
    (* the longest name of the table that the input starts with *)
    let rec longest k =
      if k = 0 then None
      else if t.pos + k <= t.n && Hashtbl.mem entities (String.sub t.s t.pos k) then Some k
      else longest (k - 1) in
    (* a name is letters and digits, then perhaps ";": no candidate is longer
       than the run of them here *)
    let run = ref t.pos in
    while !run < t.n && is_alnum (Char.code t.s.[!run]) do incr run done;
    let longest_possible = !run - t.pos + (if !run < t.n && t.s.[!run] = ';' then 1 else 0) in
    (match longest (min max_entity longest_possible) with
     | Some k ->
       let name = String.sub t.s t.pos k in
       t.pos <- t.pos + k;
       let semicolon = name.[k - 1] = ';' in
       let next = if t.pos < t.n then Char.code t.s.[t.pos] else eof in
       if in_attr t && not semicolon && (next = 0x3D || is_alnum next) then begin
         Buffer.add_string t.tmp name; flush_char_ref t; t.state <- t.return_state
       end else begin
         Buffer.clear t.tmp;
         Array.iter (add_utf8 t.tmp) (Hashtbl.find entities name);
         flush_char_ref t; t.state <- t.return_state
       end
     | None -> flush_char_ref t; t.state <- Ambiguous_ampersand)
  | Ambiguous_ampersand ->
    (match c with
     | c when is_alnum c ->
       if in_attr t then Buffer.add_char t.attr_value (Char.unsafe_chr c) else emit_char t c
     | c -> back t c; t.state <- t.return_state)
  | Numeric_char_ref ->
    t.code <- 0;
    (match c with
     | 0x78 | 0x58 -> Buffer.add_char t.tmp (Char.unsafe_chr c); t.state <- Hex_char_ref_start
     | c -> back t c; t.state <- Decimal_char_ref_start)
  | Hex_char_ref_start ->
    if is_hex c then (back t c; t.state <- Hex_char_ref)
    else (flush_char_ref t; back t c; t.state <- t.return_state)
  | Decimal_char_ref_start ->
    if is_digit c then (back t c; t.state <- Decimal_char_ref)
    else (flush_char_ref t; back t c; t.state <- t.return_state)
  | Hex_char_ref ->
    (match c with
     | c when is_hex c ->
       let v = if is_digit c then c - 0x30 else (lower c) - 0x61 + 10 in
       t.code <- min 0x110000 (t.code * 16 + v)
     | 0x3B -> numeric_end t
     | c -> back t c; numeric_end t)
  | Decimal_char_ref ->
    (match c with
     | c when is_digit c -> t.code <- min 0x110000 (t.code * 10 + (c - 0x30))
     | 0x3B -> numeric_end t
     | c -> back t c; numeric_end t)
  | Numeric_char_ref_end -> back t c; numeric_end t

let rec next t =
  match Queue.take_opt t.queue with
  | Some tok -> tok
  | None -> step t; next t
