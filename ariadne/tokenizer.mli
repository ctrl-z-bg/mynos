(** The HTML Standard's tokenizer (13.2.5): every state.

    The input is UTF-8 (from {!Encoding}); since every character the
    syntax looks at is ASCII, the tokenizer works on its bytes and copies
    the others. Parse errors are not reported: the specification says what
    to do after each one, and that is what is done. *)

type token =
  | Doctype of { name : string option; public_id : string option;
                 system_id : string option; force_quirks : bool }
  | Start_tag of { name : string; attrs : (string * string) list; self_closing : bool }
      (** names in lower case; attributes in order, a repeated one dropped *)
  | End_tag of string
  | Comment of string
  | Pi of { target : string; data : string }   (* a processing instruction: <?target data> *)
  | Chars of string        (** a run of characters *)
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

type t

val create : string -> t
(** A tokenizer over a document's text, in UTF-8. Newlines are normalized
    (CR LF and CR become LF) here. *)

val next : t -> token
(** The next token; [Eof] at the end, and again after it. *)

val set_state : t -> state -> unit
(** The tree builder's switches: RCDATA after [<title>], and so on. *)

val set_last_start_tag : t -> string -> unit
(** For a tokenizer that starts in RCDATA, RAWTEXT or script data. *)

val set_allow_cdata : t -> bool -> unit
(** Whether [<![CDATA[] opens a CDATA section: when the adjusted current
    node is not an HTML element (the tree builder says). *)
