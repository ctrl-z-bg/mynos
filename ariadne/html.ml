(* HTML to a Dom tree. M0's parser: tolerant tag soup, replaced in M1 by
   the WHATWG tokenizer and tree builder (BROWSER-TODO.md). *)

let utf8_of_code b c =
  let c = if c < 0 || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) then 0xFFFD else c in
  let add x = Buffer.add_char b (Char.unsafe_chr x) in
  if c < 0x80 then add c
  else if c < 0x800 then (add (0xC0 lor (c lsr 6)); add (0x80 lor (c land 0x3F)))
  else if c < 0x10000 then
    (add (0xE0 lor (c lsr 12)); add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))
  else
    (add (0xF0 lor (c lsr 18)); add (0x80 lor ((c lsr 12) land 0x3F));
     add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))

(* the common named references; M1 has the specification's whole table *)
let named = [
  "amp", 38; "lt", 60; "gt", 62; "quot", 34; "apos", 39; "nbsp", 160;
  "copy", 169; "reg", 174; "trade", 8482; "hellip", 8230; "mdash", 8212;
  "ndash", 8211; "lsquo", 8216; "rsquo", 8217; "ldquo", 8220; "rdquo", 8221;
  "laquo", 171; "raquo", 187; "middot", 183; "bull", 8226; "deg", 176;
  "times", 215; "euro", 8364; "eacute", 233; "egrave", 232; "agrave", 224;
  "ograve", 242; "ugrave", 249; "igrave", 236; "ccedil", 231; "uuml", 252;
  "ouml", 246; "auml", 228; "szlig", 223 ]

let decode_entities s =
  if not (String.contains s '&') then s
  else begin
    let n = String.length s in
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if s.[!i] <> '&' then (Buffer.add_char b s.[!i]; incr i)
      else begin
        (* the reference's name, up to ';' (at most 32 characters) *)
        let j = ref (!i + 1) in
        while !j < n && !j - !i <= 32 && s.[!j] <> ';' && s.[!j] <> '&' && s.[!j] <> ' ' && s.[!j] <> '<' do incr j done;
        let body = String.sub s (!i + 1) (!j - !i - 1) in
        let terminated = !j < n && s.[!j] = ';' in
        let code =
          if String.length body > 1 && body.[0] = '#' then
            let digits = String.sub body 1 (String.length body - 1) in
            if String.length digits > 1 && (digits.[0] = 'x' || digits.[0] = 'X') then
              int_of_string_opt ("0x" ^ String.sub digits 1 (String.length digits - 1))
            else int_of_string_opt digits
          else List.assoc_opt body named in
        match code with
        | Some c -> utf8_of_code b c; i := if terminated then !j + 1 else !j
        | None -> Buffer.add_char b '&'; incr i
      end
    done;
    Buffer.contents b
  end

(* ---- the tokens ---- *)

type token =
  | Start of string * (string * string) list * bool   (* name, attributes, self-closing *)
  | End of string
  | Chars of string
  | Comment_tok of string
  | Doctype_tok of string

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012'
let is_name_char c = not (is_space c || c = '>' || c = '/' || c = '=')

let lower = String.lowercase_ascii

(* elements whose content is text up to their end tag *)
let raw_text = [ "script"; "style"; "textarea"; "title"; "xmp"; "iframe"; "noembed"; "noframes" ]

let index_from_opt s i sub =
  let n = String.length s and m = String.length sub in
  let rec go i = if i + m > n then None else if String.sub s i m = sub then Some i else go (i + 1) in
  go i

(* case-insensitive search, for "</script" *)
let index_ci s i sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if lower (String.sub s i m) = sub then Some i else go (i + 1) in
  go i

let tokens s =
  let n = String.length s in
  let out = ref [] in
  let emit t = out := t :: !out in
  let text_start = ref 0 in
  let flush_text upto =
    if upto > !text_start then emit (Chars (String.sub s !text_start (upto - !text_start))) in
  let i = ref 0 in
  while !i < n do
    if s.[!i] <> '<' || !i + 1 >= n then incr i
    else begin
      let c = s.[!i + 1] in
      if c = '!' then begin
        flush_text !i;
        if !i + 3 < n && s.[!i + 2] = '-' && s.[!i + 3] = '-' then begin
          let e = Option.value (index_from_opt s (!i + 4) "-->") ~default:n in
          emit (Comment_tok (String.sub s (!i + 4) (e - !i - 4)));
          i := min n (e + 3)
        end else begin
          let e = Option.value (String.index_from_opt s !i '>') ~default:n in
          let body = String.sub s (!i + 2) (e - !i - 2) in
          if String.length body >= 7 && lower (String.sub body 0 7) = "doctype" then
            emit (Doctype_tok (lower (String.trim (String.sub body 7 (String.length body - 7)))))
          else emit (Comment_tok body);
          i := min n (e + 1)
        end;
        text_start := !i
      end else if c = '/' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') then begin
        flush_text !i;
        let closing = c = '/' in
        let j = ref (!i + if closing then 2 else 1) in
        let name_start = !j in
        while !j < n && is_name_char s.[!j] do incr j done;
        let name = lower (String.sub s name_start (!j - name_start)) in
        (* the attributes *)
        let attrs = ref [] and self_closing = ref false in
        let fin = ref false in
        while not !fin && !j < n do
          let ch = s.[!j] in
          if ch = '>' then (fin := true; incr j)
          else if is_space ch then incr j
          else if ch = '/' then (self_closing := true; incr j)
          else begin
            let a = !j in
            while !j < n && is_name_char s.[!j] do incr j done;
            let aname = lower (String.sub s a (!j - a)) in
            if !j = a then incr j;          (* a lone '=' *)
            while !j < n && is_space s.[!j] do incr j done;
            let value =
              if !j < n && s.[!j] = '=' then begin
                incr j;
                while !j < n && is_space s.[!j] do incr j done;
                if !j < n && (s.[!j] = '"' || s.[!j] = '\'') then begin
                  let q = s.[!j] in
                  let e = Option.value (String.index_from_opt s (!j + 1) q) ~default:n in
                  let v = String.sub s (!j + 1) (e - !j - 1) in
                  j := min n (e + 1); v
                end else begin
                  let v0 = !j in
                  while !j < n && not (is_space s.[!j] || s.[!j] = '>') do incr j done;
                  String.sub s v0 (!j - v0)
                end
              end else "" in
            self_closing := false;
            if aname <> "" && not (List.mem_assoc aname !attrs) then
              attrs := (aname, decode_entities value) :: !attrs
          end
        done;
        i := !j;
        if closing then emit (End name)
        else begin
          emit (Start (name, List.rev !attrs, !self_closing));
          (* raw text: everything up to the end tag *)
          if List.mem name raw_text && not !self_closing then begin
            let e = Option.value (index_ci s !i ("</" ^ name)) ~default:n in
            if e > !i then emit (Chars (String.sub s !i (e - !i)));
            emit (End name);
            let close = Option.value (String.index_from_opt s e '>') ~default:(n - 1) in
            i := if e >= n then n else close + 1
          end
        end;
        text_start := !i
      end else incr i
    end
  done;
  flush_text n;
  List.rev !out

(* ---- the tree ---- *)

let void = [ "area"; "base"; "br"; "col"; "embed"; "hr"; "img"; "input"; "link";
             "meta"; "param"; "source"; "track"; "wbr" ]

(* a start tag of these closes an open <p> *)
let closes_p = [ "address"; "article"; "aside"; "blockquote"; "details"; "div"; "dl";
                 "fieldset"; "figcaption"; "figure"; "footer"; "form"; "h1"; "h2"; "h3";
                 "h4"; "h5"; "h6"; "header"; "hr"; "main"; "menu"; "nav"; "ol"; "p";
                 "pre"; "section"; "table"; "ul" ]

(* a start tag of the first closes an open one of the others, up to the
   nearest of the last *)
let implied_ends = [
  "li", ([ "li" ], [ "ul"; "ol"; "menu" ]);
  "dt", ([ "dt"; "dd" ], [ "dl" ]);
  "dd", ([ "dt"; "dd" ], [ "dl" ]);
  "tr", ([ "tr"; "td"; "th" ], [ "table"; "tbody"; "thead"; "tfoot" ]);
  "td", ([ "td"; "th" ], [ "tr"; "table" ]);
  "th", ([ "td"; "th" ], [ "tr"; "table" ]);
  "option", ([ "option" ], [ "select"; "datalist" ]);
]

let parse s =
  let doc = Dom.document () in
  (* the open elements, the innermost first; the document at the bottom *)
  let stack = ref [ doc ] in
  (* how many elements of each name are open: a search of the stack for a
     name none of which is open is skipped, so a deep page (thousands of
     nested elements) does not cost a walk of the stack at every tag *)
  let opened : (string, int) Hashtbl.t = Hashtbl.create 64 in
  let open_count name = Option.value (Hashtbl.find_opt opened name) ~default:0 in
  let push e =
    stack := e :: !stack;
    Hashtbl.replace opened (Dom.name e) (open_count (Dom.name e) + 1) in
  let pop () = match !stack with
    | e :: (_ :: _ as rest) ->
      stack := rest; Hashtbl.replace opened (Dom.name e) (open_count (Dom.name e) - 1)
    | _ -> () in
  let current () = List.hd !stack in
  let pop_to name =
    (* up to and including the nearest open [name]; nothing if none is open *)
    if open_count name > 0 then begin
      while Dom.name (current ()) <> name do pop () done;
      pop ()
    end in
  let close_any names ~within =
    if List.exists (fun n -> open_count n > 0) names then begin
      let rec find = function
        | e :: _ when List.mem (Dom.name e) within -> None
        | e :: _ when List.mem (Dom.name e) names -> Some (Dom.name e)
        | _ :: rest -> find rest
        | [] -> None in
      match find !stack with Some nm -> pop_to nm | None -> ()
    end in
  let add_text t =
    match (current ()).Dom.last_child with
    | Some ({ kind = Text tx; _ }) -> tx.data <- tx.data ^ t
    | _ -> Dom.append (current ()) (Dom.text t) in
  List.iter (function
      | Doctype_tok d ->
        let nm = match String.index_opt d ' ' with Some k -> String.sub d 0 k | None -> d in
        Dom.append doc (Dom.doctype nm)
      | Comment_tok c -> Dom.append (current ()) (Dom.comment c)
      | Chars t ->
        (* title and textarea are text with references; the others not *)
        let raw = List.mem (Dom.name (current ())) raw_text
                  && not (List.mem (Dom.name (current ())) [ "title"; "textarea" ]) in
        add_text (if raw then t else decode_entities t)
      | End name -> if not (List.mem name void) then pop_to name
      | Start (name, attrs, self_closing) ->
        if List.mem name closes_p then close_any [ "p" ] ~within:[ "button"; "table"; "td"; "th" ];
        (match List.assoc_opt name implied_ends with
         | Some (names, within) -> close_any names ~within
         | None -> ());
        let e = Dom.element ~attrs name in
        Dom.append (current ()) e;
        if not (List.mem name void || self_closing) then push e)
    (tokens s);
  doc
