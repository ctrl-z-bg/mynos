(* A page's bytes to UTF-8 (the HTML Standard, "determining the character
   encoding", and the Encoding Standard's decoders): the byte order mark,
   the HTTP header's charset, a <meta> in the first 1024 bytes, else UTF-8
   when the bytes are valid UTF-8 and windows-1252 when not. UTF-8,
   windows-1252 (and the labels that mean it: ISO-8859-1, ASCII...) and
   UTF-16 are decoded; a page in another encoding is read as windows-1252. *)

type t = Utf8 | Windows_1252 | Utf16le | Utf16be

let name = function
  | Utf8 -> "UTF-8" | Windows_1252 -> "windows-1252"
  | Utf16le -> "UTF-16LE" | Utf16be -> "UTF-16BE"

let of_label label =
  match String.lowercase_ascii (String.trim label) with
  | "unicode-1-1-utf-8" | "unicode11utf8" | "unicode20utf8" | "utf-8" | "utf8"
  | "x-unicode20utf8" -> Some Utf8
  | "ansi_x3.4-1968" | "ascii" | "cp1252" | "cp819" | "csisolatin1" | "ibm819"
  | "iso-8859-1" | "iso-ir-100" | "iso8859-1" | "iso88591" | "iso_8859-1"
  | "iso_8859-1:1987" | "l1" | "latin1" | "us-ascii" | "windows-1252" | "x-cp1252"
  | "x-user-defined" -> Some Windows_1252
  | "csunicode" | "iso-10646-ucs-2" | "ucs-2" | "unicode" | "unicodefeff"
  | "utf-16" | "utf-16le" -> Some Utf16le
  | "unicodefffe" | "utf-16be" -> Some Utf16be
  | _ -> None

(* "text/html; charset=ISO-8859-1" -> Some "ISO-8859-1" *)
let charset_of_content_type ct =
  let lower = String.lowercase_ascii ct in
  let n = String.length lower in
  let rec find i =
    if i + 7 > n then None
    else if String.sub lower i 7 = "charset" then begin
      let j = ref (i + 7) in
      while !j < n && (lower.[!j] = ' ' || lower.[!j] = '\t') do incr j done;
      if !j < n && lower.[!j] = '=' then begin
        incr j;
        while !j < n && (lower.[!j] = ' ' || lower.[!j] = '\t') do incr j done;
        let quote = if !j < n && (lower.[!j] = '"' || lower.[!j] = '\'') then Some lower.[!j] else None in
        if quote <> None then incr j;
        let s = !j in
        while !j < n && (match quote with
            | Some q -> lower.[!j] <> q
            | None -> lower.[!j] <> ';' && lower.[!j] <> ' ' && lower.[!j] <> '\t') do incr j done;
        if !j > s then Some (String.sub ct s (!j - s)) else None
      end else find (i + 7)
    end else find (i + 1) in
  find 0

(* ---- the prescan of a byte stream, for <meta charset> ---- *)

let is_space c = c = '\t' || c = '\n' || c = '\012' || c = '\r' || c = ' '
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

let prescan s =
  let n = min (String.length s) 1024 in
  let pos = ref 0 in
  let at str = let m = String.length str in
    !pos + m <= n && String.lowercase_ascii (String.sub s !pos m) = str in
  (* "get an attribute": (name, value), or None at the tag's end *)
  let get_attribute () =
    while !pos < n && (is_space s.[!pos] || s.[!pos] = '/') do incr pos done;
    if !pos >= n || s.[!pos] = '>' then None
    else begin
      let name = Buffer.create 16 and value = Buffer.create 16 in
      let fin = ref false in
      (* the name *)
      let first = ref true in
      while not !fin && !pos < n do
        let c = s.[!pos] in
        if c = '=' && not !first then fin := true
        else if is_space c then fin := true
        else if c = '/' || c = '>' then fin := true
        else (Buffer.add_char name (Char.lowercase_ascii c); incr pos);
        first := false
      done;
      while !pos < n && is_space s.[!pos] do incr pos done;
      if !pos < n && s.[!pos] = '=' then begin
        incr pos;
        while !pos < n && is_space s.[!pos] do incr pos done;
        if !pos < n && (s.[!pos] = '"' || s.[!pos] = '\'') then begin
          let q = s.[!pos] in
          incr pos;
          while !pos < n && s.[!pos] <> q do Buffer.add_char value (Char.lowercase_ascii s.[!pos]); incr pos done;
          incr pos
        end else
          while !pos < n && not (is_space s.[!pos] || s.[!pos] = '>') do
            Buffer.add_char value (Char.lowercase_ascii s.[!pos]); incr pos done
      end;
      Some (Buffer.contents name, Buffer.contents value)
    end in
  let result = ref None in
  while !result = None && !pos < n do
    if at "<!--" then begin
      pos := !pos + 4;
      while !pos < n && not (at "-->") do incr pos done;
      pos := !pos + 3
    end else if at "<meta" && !pos + 5 < n && (is_space s.[!pos + 5] || s.[!pos + 5] = '/') then begin
      pos := !pos + 6;
      let seen = Hashtbl.create 8 in
      let got_pragma = ref false and need_pragma = ref None and charset = ref None in
      let rec attrs () =
        match get_attribute () with
        | None -> ()
        | Some (nm, v) ->
          if not (Hashtbl.mem seen nm) then begin
            Hashtbl.add seen nm ();
            (match nm with
             | "http-equiv" -> if v = "content-type" then got_pragma := true
             | "content" ->
               if !charset = None then
                 (match charset_of_content_type v with
                  | Some c -> charset := Some c; need_pragma := Some true
                  | None -> ())
             | "charset" -> charset := Some v; need_pragma := Some false
             | _ -> ())
          end;
          attrs () in
      attrs ();
      (match !need_pragma, !charset with
       | Some np, Some c when (not np) || !got_pragma ->
         (match of_label c with
          | Some (Utf16le | Utf16be) -> result := Some Utf8
          | Some e -> result := Some e
          | None -> ())
       | _ -> ())
    end else if !pos + 1 < n && s.[!pos] = '<'
              && (is_alpha s.[!pos + 1] || (s.[!pos + 1] = '/' && !pos + 2 < n && is_alpha s.[!pos + 2])) then begin
      (* another tag: skipped, with its attributes *)
      pos := !pos + 2;
      while !pos < n && not (is_space s.[!pos] || s.[!pos] = '>') do incr pos done;
      let rec skip () = match get_attribute () with Some _ -> skip () | None -> () in
      skip ()
    end else if at "<!" || at "</" || at "<?" then begin
      while !pos < n && s.[!pos] <> '>' do incr pos done;
      incr pos
    end else incr pos
  done;
  !result

(* ---- the decoders ---- *)

let add_utf8 b c =
  let add x = Buffer.add_char b (Char.unsafe_chr x) in
  if c < 0x80 then add c
  else if c < 0x800 then (add (0xC0 lor (c lsr 6)); add (0x80 lor (c land 0x3F)))
  else if c < 0x10000 then
    (add (0xE0 lor (c lsr 12)); add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))
  else
    (add (0xF0 lor (c lsr 18)); add (0x80 lor ((c lsr 12) land 0x3F));
     add (0x80 lor ((c lsr 6) land 0x3F)); add (0x80 lor (c land 0x3F)))

(* the Encoding Standard's UTF-8 decoder: an invalid sequence becomes
   U+FFFD, and decoding goes on at the byte that made it invalid *)
let decode_utf8 ?(from = 0) s =
  let n = String.length s in
  let b = Buffer.create n in
  let need = ref 0 and seen = ref 0 and cp = ref 0 and lower = ref 0x80 and upper = ref 0xBF in
  let i = ref from in
  while !i < n do
    let byte = Char.code s.[!i] in
    if !need = 0 then begin
      (if byte < 0x80 then Buffer.add_char b s.[!i]
       else if byte >= 0xC2 && byte <= 0xDF then (need := 1; cp := byte land 0x1F)
       else if byte >= 0xE0 && byte <= 0xEF then begin
         if byte = 0xE0 then lower := 0xA0;
         if byte = 0xED then upper := 0x9F;
         need := 2; cp := byte land 0xF
       end else if byte >= 0xF0 && byte <= 0xF4 then begin
         if byte = 0xF0 then lower := 0x90;
         if byte = 0xF4 then upper := 0x8F;
         need := 3; cp := byte land 0x7
       end else add_utf8 b 0xFFFD);
      incr i
    end else if byte < !lower || byte > !upper then begin
      (* not a continuation: U+FFFD, and this byte again *)
      need := 0; seen := 0; cp := 0; lower := 0x80; upper := 0xBF;
      add_utf8 b 0xFFFD
    end else begin
      lower := 0x80; upper := 0xBF;
      cp := (!cp lsl 6) lor (byte land 0x3F);
      incr seen;
      if !seen = !need then begin
        add_utf8 b !cp; need := 0; seen := 0; cp := 0
      end;
      incr i
    end
  done;
  if !need > 0 then add_utf8 b 0xFFFD;
  Buffer.contents b

let cp1252 = [| 0x20AC; 0x81; 0x201A; 0x0192; 0x201E; 0x2026; 0x2020; 0x2021;
                0x02C6; 0x2030; 0x0160; 0x2039; 0x0152; 0x8D; 0x017D; 0x8F;
                0x90; 0x2018; 0x2019; 0x201C; 0x201D; 0x2022; 0x2013; 0x2014;
                0x02DC; 0x2122; 0x0161; 0x203A; 0x0153; 0x9D; 0x017E; 0x0178 |]

let decode_1252 s =
  let b = Buffer.create (String.length s + String.length s / 8) in
  String.iter (fun ch ->
      let c = Char.code ch in
      if c < 0x80 then Buffer.add_char b ch
      else add_utf8 b (if c < 0xA0 then cp1252.(c - 0x80) else c)) s;
  Buffer.contents b

let decode_utf16 ~big ?(from = 0) s =
  let n = String.length s in
  let b = Buffer.create n in
  let unit i = if big then (Char.code s.[i] lsl 8) lor Char.code s.[i + 1]
    else (Char.code s.[i + 1] lsl 8) lor Char.code s.[i] in
  let i = ref from in
  while !i + 1 < n do
    let u = unit !i in
    i := !i + 2;
    if u >= 0xD800 && u <= 0xDBFF then begin
      if !i + 1 < n && (let l = unit !i in l >= 0xDC00 && l <= 0xDFFF) then begin
        let l = unit !i in
        i := !i + 2;
        add_utf8 b (0x10000 + ((u - 0xD800) lsl 10) + (l - 0xDC00))
      end else add_utf8 b 0xFFFD
    end else if u >= 0xDC00 && u <= 0xDFFF then add_utf8 b 0xFFFD
    else add_utf8 b u
  done;
  if !i < n then add_utf8 b 0xFFFD;
  Buffer.contents b

(* valid UTF-8 from [from] on: checked without building a copy (most pages
   are, and then decoding is just this check) *)
let valid_utf8 ?(from = 0) s =
  let n = String.length s in
  let rec go i =
    if i >= n then true
    else
      let b = Char.code (String.unsafe_get s i) in
      if b < 0x80 then go (i + 1)
      else
        let cont k lo hi =
          i + k < n
          && (let c = Char.code s.[i + 1] in c >= lo && c <= hi)
          && (k < 2 || (let c = Char.code s.[i + 2] in c >= 0x80 && c <= 0xBF))
          && (k < 3 || (let c = Char.code s.[i + 3] in c >= 0x80 && c <= 0xBF)) in
        if b >= 0xC2 && b <= 0xDF then cont 1 0x80 0xBF && go (i + 2)
        else if b = 0xE0 then cont 2 0xA0 0xBF && go (i + 3)
        else if b = 0xED then cont 2 0x80 0x9F && go (i + 3)
        else if b >= 0xE1 && b <= 0xEF then cont 2 0x80 0xBF && go (i + 3)
        else if b = 0xF0 then cont 3 0x90 0xBF && go (i + 4)
        else if b = 0xF4 then cont 3 0x80 0x8F && go (i + 4)
        else if b >= 0xF1 && b <= 0xF3 then cont 3 0x80 0xBF && go (i + 4)
        else false in
  go from

(* the encoding, and where the content starts (after a byte order mark) *)
let sniff ?transport s =
  let n = String.length s in
  if n >= 3 && String.sub s 0 3 = "\xEF\xBB\xBF" then (Utf8, 3)
  else if n >= 2 && String.sub s 0 2 = "\xFE\xFF" then (Utf16be, 2)
  else if n >= 2 && String.sub s 0 2 = "\xFF\xFE" then (Utf16le, 2)
  else match Option.bind transport of_label with
    | Some e -> (e, 0)
    | None ->
      match prescan s with
      | Some e -> (e, 0)
      | None -> ((if valid_utf8 s then Utf8 else Windows_1252), 0)

let decode e ?(from = 0) s =
  match e with
  | Utf8 -> if valid_utf8 ~from s then (if from = 0 then s else String.sub s from (String.length s - from))
            else decode_utf8 ~from s
  | Windows_1252 -> decode_1252 (if from = 0 then s else String.sub s from (String.length s - from))
  | Utf16le -> decode_utf16 ~big:false ~from s
  | Utf16be -> decode_utf16 ~big:true ~from s

let to_utf8 ?transport s =
  let e, from = sniff ?transport s in
  (e, decode e ~from s)
