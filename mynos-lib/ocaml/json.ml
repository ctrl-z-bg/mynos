(* JSON: see json.mli. A recursive descent parser over the string. *)

type t =
  | Null
  | Bool of bool
  | Number of float
  | String of string
  | Array of t list
  | Object of (string * t) list

exception Error of string

let error fmt = Printf.ksprintf (fun m -> raise (Error m)) fmt

(* ---- parsing ---- *)

let of_string s =
  let n = String.length s in
  let pos = ref 0 in
  let peek () = if !pos < n then s.[!pos] else '\000' in
  let fail what = error "JSON: %s at %d" what !pos in
  let rec blank () =
    match peek () with
    | ' ' | '\t' | '\n' | '\r' when !pos < n -> incr pos; blank ()
    | _ -> () in
  let expect c =
    if peek () = c && !pos < n then incr pos
    else fail (Printf.sprintf "'%c' expected" c) in
  let word w v =
    let l = String.length w in
    if !pos + l <= n && String.sub s !pos l = w then (pos := !pos + l; v)
    else fail "unknown word" in
  let hex4 () =
    if !pos + 4 > n then fail "short \\u escape";
    let v = match int_of_string_opt ("0x" ^ String.sub s !pos 4) with
      | Some v -> v | None -> fail "bad \\u escape" in
    pos := !pos + 4; v in
  let string () =
    expect '"';
    let b = Buffer.create 16 in
    let rec go () =
      if !pos >= n then fail "unterminated string";
      let c = s.[!pos] in
      incr pos;
      match c with
      | '"' -> Buffer.contents b
      | '\\' ->
        if !pos >= n then fail "unterminated string";
        let e = s.[!pos] in
        incr pos;
        (match e with
         | '"' | '\\' | '/' -> Buffer.add_char b e
         | 'b' -> Buffer.add_char b '\b'
         | 'f' -> Buffer.add_char b '\012'
         | 'n' -> Buffer.add_char b '\n'
         | 'r' -> Buffer.add_char b '\r'
         | 't' -> Buffer.add_char b '\t'
         | 'u' ->
           let u = hex4 () in
           let u =
             if u >= 0xD800 && u <= 0xDBFF && !pos + 6 <= n
                && s.[!pos] = '\\' && s.[!pos + 1] = 'u' then begin
               pos := !pos + 2;
               let lo = hex4 () in
               if lo >= 0xDC00 && lo <= 0xDFFF then
                 0x10000 + ((u - 0xD800) lsl 10) + (lo - 0xDC00)
               else fail "bad surrogate pair"
             end else u in
           if Uchar.is_valid u then Buffer.add_utf_8_uchar b (Uchar.of_int u)
           else Buffer.add_utf_8_uchar b Uchar.rep
         | _ -> fail "bad escape");
        go ()
      | c when c < ' ' -> fail "control character in a string"
      | c -> Buffer.add_char b c; go () in
    go () in
  let number () =
    let start = !pos in
    let digits () = while !pos < n && s.[!pos] >= '0' && s.[!pos] <= '9' do incr pos done in
    if peek () = '-' then incr pos;
    digits ();
    if peek () = '.' then (incr pos; digits ());
    if peek () = 'e' || peek () = 'E' then begin
      incr pos;
      if peek () = '+' || peek () = '-' then incr pos;
      digits ()
    end;
    match float_of_string_opt (String.sub s start (!pos - start)) with
    | Some f -> Number f
    | None -> pos := start; fail "bad number" in
  let rec value depth =
    if depth > 512 then fail "too deep";
    blank ();
    match peek () with
    | '{' ->
      incr pos; blank ();
      if peek () = '}' then (incr pos; Object [])
      else begin
        let rec fields acc =
          blank ();
          let k = string () in
          blank (); expect ':';
          let v = value (depth + 1) in
          blank ();
          match peek () with
          | ',' -> incr pos; fields ((k, v) :: acc)
          | '}' -> incr pos; Object (List.rev ((k, v) :: acc))
          | _ -> fail "',' or '}' expected" in
        fields []
      end
    | '[' ->
      incr pos; blank ();
      if peek () = ']' then (incr pos; Array [])
      else begin
        let rec elements acc =
          let v = value (depth + 1) in
          blank ();
          match peek () with
          | ',' -> incr pos; elements (v :: acc)
          | ']' -> incr pos; Array (List.rev (v :: acc))
          | _ -> fail "',' or ']' expected" in
        elements []
      end
    | '"' -> String (string ())
    | 't' -> word "true" (Bool true)
    | 'f' -> word "false" (Bool false)
    | 'n' -> word "null" Null
    | '-' | '0' .. '9' -> number ()
    | _ -> fail "a value expected" in
  let v = value 0 in
  blank ();
  if !pos <> n then fail "text after the value";
  v

(* ---- printing ---- *)

let escape b str =
  Buffer.add_char b '"';
  String.iter (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when c < ' ' -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c) str;
  Buffer.add_char b '"'

let number f =
  if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.0f" f
  else if Float.is_finite f then Printf.sprintf "%.17g" f
  else "null"

let to_string v =
  let b = Buffer.create 64 in
  let rec go = function
    | Null -> Buffer.add_string b "null"
    | Bool x -> Buffer.add_string b (if x then "true" else "false")
    | Number f -> Buffer.add_string b (number f)
    | String str -> escape b str
    | Array l ->
      Buffer.add_char b '[';
      List.iteri (fun i v -> if i > 0 then Buffer.add_char b ','; go v) l;
      Buffer.add_char b ']'
    | Object l ->
      Buffer.add_char b '{';
      List.iteri (fun i (k, v) ->
          if i > 0 then Buffer.add_char b ',';
          escape b k; Buffer.add_char b ':'; go v) l;
      Buffer.add_char b '}' in
  go v;
  Buffer.contents b

(* ---- access ---- *)

let kind = function
  | Null -> "null" | Bool _ -> "a boolean" | Number _ -> "a number"
  | String _ -> "a string" | Array _ -> "an array" | Object _ -> "an object"

let member k = function
  | Object l -> (try List.assoc k l with Not_found -> Null)
  | v -> error "JSON: field %S of %s" k (kind v)

let index i = function
  | Array l as v ->
    (match List.nth_opt l i with
     | Some x when i >= 0 -> x
     | _ -> error "JSON: no element %d in %s" i (kind v))
  | v -> error "JSON: element %d of %s" i (kind v)

let to_string_value = function String s -> s | v -> error "JSON: %s, not a string" (kind v)
let to_float = function Number f -> f | v -> error "JSON: %s, not a number" (kind v)
let to_int v = int_of_float (to_float v)
let to_bool = function Bool b -> b | v -> error "JSON: %s, not a boolean" (kind v)
let to_list = function Array l -> l | v -> error "JSON: %s, not an array" (kind v)
