(* Html: HTML as a stream of tokens, tolerant of what the web sends:
   tags in any case, attributes quoted or not, entities, comments; the
   contents of script and style skipped whole. The text is turned into
   UTF-8 first when the page says it is Latin-1 or Windows-1252. *)

type token =
  | Start of string * (string * string) list    (* name (lower case), attributes *)
  | End of string
  | Text of string

(* ---- characters ---- *)

let utf8 b c =
  if c < 0x80 then Buffer.add_char b (Char.chr c)
  else if c < 0x800 then begin
    Buffer.add_char b (Char.chr (0xC0 lor (c lsr 6)));
    Buffer.add_char b (Char.chr (0x80 lor (c land 0x3F)))
  end else if c < 0x10000 then begin
    Buffer.add_char b (Char.chr (0xE0 lor (c lsr 12)));
    Buffer.add_char b (Char.chr (0x80 lor ((c lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (c land 0x3F)))
  end else begin
    Buffer.add_char b (Char.chr (0xF0 lor (c lsr 18)));
    Buffer.add_char b (Char.chr (0x80 lor ((c lsr 12) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor ((c lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (c land 0x3F)))
  end

(* Windows-1252's 0x80-0x9F; Latin-1 is the rest *)
let cp1252 = [| 0x20AC; 0x81; 0x201A; 0x0192; 0x201E; 0x2026; 0x2020; 0x2021; 0x02C6; 0x2030;
                0x0160; 0x2039; 0x0152; 0x8D; 0x017D; 0x8F; 0x90; 0x2018; 0x2019; 0x201C;
                0x201D; 0x2022; 0x2013; 0x2014; 0x02DC; 0x2122; 0x0161; 0x203A; 0x0153;
                0x9D; 0x017E; 0x0178 |]

let latin1_to_utf8 s =
  let b = Buffer.create (String.length s + 64) in
  String.iter (fun ch ->
      let c = Char.code ch in
      utf8 b (if c >= 0x80 && c < 0xA0 then cp1252.(c - 0x80) else c)) s;
  Buffer.contents b

let lower = String.lowercase_ascii

let contains s w =
  let n = String.length s and k = String.length w in
  let rec at i = i + k <= n && (String.sub s i k = w || at (i + 1)) in
  at 0

(* the page's charset: the header's, or a meta's in its first 2 KB *)
let charset ~content_type body =
  let ct = lower content_type in
  let head = lower (String.sub body 0 (min 2048 (String.length body))) in
  let latin = [ "iso-8859-1"; "latin1"; "windows-1252"; "iso-8859-15" ] in
  if List.exists (contains ct) latin then `Latin1
  else if contains ct "utf-8" then `Utf8
  else if List.exists (fun c -> contains head ("charset=" ^ c) || contains head ("charset=\"" ^ c))
      latin then `Latin1
  else `Utf8

(* ---- entities ---- *)

let entities = [
  "amp", 38; "lt", 60; "gt", 62; "quot", 34; "apos", 39; "nbsp", 160; "copy", 169;
  "reg", 174; "trade", 8482; "hellip", 8230; "mdash", 8212; "ndash", 8211;
  "lsquo", 8216; "rsquo", 8217; "ldquo", 8220; "rdquo", 8221; "sbquo", 8218;
  "bdquo", 8222; "laquo", 171; "raquo", 187; "lsaquo", 8249; "rsaquo", 8250;
  "euro", 8364; "pound", 163; "yen", 165; "cent", 162; "deg", 176; "plusmn", 177;
  "times", 215; "divide", 247; "middot", 183; "bull", 8226; "para", 182; "sect", 167;
  "frac12", 189; "frac14", 188; "frac34", 190; "sup1", 185; "sup2", 178; "sup3", 179;
  "micro", 181; "iexcl", 161; "iquest", 191; "shy", 173; "ensp", 8194; "emsp", 8195;
  "thinsp", 8201; "zwnj", 8204; "zwj", 8205; "larr", 8592; "rarr", 8594; "uarr", 8593;
  "darr", 8595; "harr", 8596; "rArr", 8658; "lArr", 8656; "le", 8804; "ge", 8805;
  "ne", 8800; "asymp", 8776; "infin", 8734; "minus", 8722; "prime", 8242; "Prime", 8243;
  "dagger", 8224; "Dagger", 8225; "permil", 8240; "oline", 8254; "hearts", 9829;
  "agrave", 224; "aacute", 225; "acirc", 226; "atilde", 227; "auml", 228; "aring", 229;
  "aelig", 230; "ccedil", 231; "egrave", 232; "eacute", 233; "ecirc", 234; "euml", 235;
  "igrave", 236; "iacute", 237; "icirc", 238; "iuml", 239; "eth", 240; "ntilde", 241;
  "ograve", 242; "oacute", 243; "ocirc", 244; "otilde", 245; "ouml", 246; "oslash", 248;
  "ugrave", 249; "uacute", 250; "ucirc", 251; "uuml", 252; "yacute", 253; "thorn", 254;
  "yuml", 255; "szlig", 223;
  "Agrave", 192; "Aacute", 193; "Acirc", 194; "Atilde", 195; "Auml", 196; "Aring", 197;
  "AElig", 198; "Ccedil", 199; "Egrave", 200; "Eacute", 201; "Ecirc", 202; "Euml", 203;
  "Igrave", 204; "Iacute", 205; "Icirc", 206; "Iuml", 207; "ETH", 208; "Ntilde", 209;
  "Ograve", 210; "Oacute", 211; "Ocirc", 212; "Otilde", 213; "Ouml", 214; "Oslash", 216;
  "Ugrave", 217; "Uacute", 218; "Ucirc", 219; "Uuml", 220; "Yacute", 221; "THORN", 222;
  "alpha", 945; "beta", 946; "gamma", 947; "delta", 948; "epsilon", 949; "lambda", 955;
  "mu", 956; "pi", 960; "sigma", 963; "omega", 969; "Delta", 916; "Omega", 937;
]

let decode s =
  if not (String.contains s '&') then s
  else begin
    let b = Buffer.create (String.length s) and n = String.length s and i = ref 0 in
    while !i < n do
      if s.[!i] = '&' then begin
        let j = ref (!i + 1) in
        while !j < n && !j - !i < 12 && s.[!j] <> ';' && s.[!j] <> '&' && s.[!j] <> ' '
              && s.[!j] <> '<' do incr j done;
        let name = String.sub s (!i + 1) (!j - !i - 1) in
        let code =
          if String.length name > 1 && name.[0] = '#' then
            (if name.[1] = 'x' || name.[1] = 'X' then
               int_of_string_opt ("0x" ^ String.sub name 2 (String.length name - 2))
             else int_of_string_opt (String.sub name 1 (String.length name - 1)))
          else List.assoc_opt name entities in
        match code with
        | Some c when c > 0 && c < 0x110000 ->
          utf8 b (if c >= 0x80 && c < 0xA0 then cp1252.(c - 0x80) else c);
          i := if !j < n && s.[!j] = ';' then !j + 1 else !j
        | _ -> Buffer.add_char b '&'; incr i
      end else begin Buffer.add_char b s.[!i]; incr i end
    done;
    Buffer.contents b
  end

(* ---- tokens ---- *)

let is_name_char c =
  match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' | ':' -> true | _ -> false

let raw_text = [ "script"; "style"; "textarea"; "title"; "xmp" ]

let tokens s =
  let n = String.length s in
  let out = ref [] in
  let emit t = out := t :: !out in
  let text_start = ref 0 in
  let flush_text upto =
    if upto > !text_start then emit (Text (decode (String.sub s !text_start (upto - !text_start)))) in
  let rec find_from i w =             (* the next occurrence of w, in any case *)
    let k = String.length w in
    if i + k > n then n
    else if lower (String.sub s i k) = w then i
    else find_from (i + 1) w in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '<' && !i + 1 < n then begin
      let c = s.[!i + 1] in
      if !i + 3 < n && String.sub s !i 4 = "<!--" then begin
        flush_text !i;
        let e = find_from (!i + 4) "-->" in
        i := min n (e + 3); text_start := !i
      end else if c = '!' || c = '?' then begin
        flush_text !i;
        let e = try String.index_from s !i '>' with Not_found -> n - 1 in
        i := e + 1; text_start := !i
      end else if c = '/' && !i + 2 < n && is_name_char s.[!i + 2] then begin
        flush_text !i;
        let j = ref (!i + 2) in
        while !j < n && is_name_char s.[!j] do incr j done;
        emit (End (lower (String.sub s (!i + 2) (!j - !i - 2))));
        let e = try String.index_from s !j '>' with Not_found -> n - 1 in
        i := e + 1; text_start := !i
      end else if is_name_char c then begin
        flush_text !i;
        let j = ref (!i + 1) in
        while !j < n && is_name_char s.[!j] do incr j done;
        let name = lower (String.sub s (!i + 1) (!j - !i - 1)) in
        (* attributes, up to '>' (not inside quotes) *)
        let attrs = ref [] in
        let k = ref !j in
        let skip_space () = while !k < n && (s.[!k] = ' ' || s.[!k] = '\n' || s.[!k] = '\t'
                                            || s.[!k] = '\r' || s.[!k] = '/') do incr k done in
        skip_space ();
        while !k < n && s.[!k] <> '>' do
          let a0 = !k in
          while !k < n && s.[!k] <> '=' && s.[!k] <> '>' && s.[!k] <> ' ' && s.[!k] <> '\n'
                && s.[!k] <> '\t' && s.[!k] <> '\r' && not (s.[!k] = '/' && !k + 1 < n && s.[!k + 1] = '>')
          do incr k done;
          let aname = lower (String.sub s a0 (!k - a0)) in
          while !k < n && (s.[!k] = ' ' || s.[!k] = '\n' || s.[!k] = '\t' || s.[!k] = '\r') do incr k done;
          let value =
            if !k < n && s.[!k] = '=' then begin
              incr k;
              while !k < n && (s.[!k] = ' ' || s.[!k] = '\n') do incr k done;
              if !k < n && (s.[!k] = '"' || s.[!k] = '\'') then begin
                let q = s.[!k] in
                let e = try String.index_from s (!k + 1) q with Not_found -> n in
                let v = String.sub s (!k + 1) (e - !k - 1) in
                k := min n (e + 1); v
              end else begin
                let v0 = !k in
                while !k < n && s.[!k] <> ' ' && s.[!k] <> '>' && s.[!k] <> '\n' && s.[!k] <> '\t' do incr k done;
                String.sub s v0 (!k - v0)
              end
            end else "" in
          if aname <> "" then attrs := (aname, decode value) :: !attrs;
          if !k = a0 then incr k;                     (* nothing read: go on *)
          skip_space ()
        done;
        emit (Start (name, List.rev !attrs));
        i := min n (!k + 1); text_start := !i;
        if List.mem name raw_text then begin
          let e = find_from !i ("</" ^ name) in
          if name = "title" || name = "textarea" || name = "style" then
            emit (Text (decode (String.sub s !i (e - !i))));
          emit (End name);
          let close = try String.index_from s e '>' with Not_found -> n - 1 in
          i := if e >= n then n else close + 1; text_start := !i
        end
      end else incr i
    end else incr i
  done;
  flush_text n;
  List.rev !out

let attr name attrs = List.assoc_opt name attrs
