(* SSH's data types (RFC 4251, section 5), Base64 (RFC 4648), and the
   system's random bytes. *)

(* {1 Writing} *)

let u32 n =
  let b = Bytes.create 4 in
  Bytes.set b 0 (Char.chr ((n lsr 24) land 0xFF));
  Bytes.set b 1 (Char.chr ((n lsr 16) land 0xFF));
  Bytes.set b 2 (Char.chr ((n lsr 8) land 0xFF));
  Bytes.set b 3 (Char.chr (n land 0xFF));
  Bytes.unsafe_to_string b

let byte n = String.make 1 (Char.chr n)
let bool b = byte (if b then 1 else 0)
let str s = u32 (String.length s) ^ s
let names l = str (String.concat "," l)

(* a positive number given as its big-endian bytes *)
let mpint_of_bytes s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && s.[!i] = '\000' do incr i done;
  let s = String.sub s !i (n - !i) in
  str (if s <> "" && Char.code s.[0] >= 0x80 then "\000" ^ s else s)

(* {1 Reading} *)

exception Bad of string

type reader = { s : string; mutable pos : int }

let reader ?(pos = 0) s = { s; pos }
let need r n = if r.pos + n > String.length r.s then raise (Bad "message too short")
let get_byte r = need r 1; let c = Char.code r.s.[r.pos] in r.pos <- r.pos + 1; c
let get_bool r = get_byte r <> 0
let get_u32 r =
  need r 4;
  let p = r.pos in
  let g i = Char.code r.s.[p + i] in
  r.pos <- p + 4;
  (* on i386 (ints of 31 bits) a number from 2^30 up is max_int *)
  if Sys.int_size < 33 && g 0 >= 0x40 then max_int
  else (g 0 lsl 24) lor (g 1 lsl 16) lor (g 2 lsl 8) lor g 3
let get_raw r n = need r n; let s = String.sub r.s r.pos n in r.pos <- r.pos + n; s
let get_str r =
  let n = get_u32 r in
  need r n;
  let s = String.sub r.s r.pos n in
  r.pos <- r.pos + n; s
let get_names r = match get_str r with "" -> [] | s -> String.split_on_char ',' s
let at_end r = r.pos >= String.length r.s

(* {1 Base64} *)

let b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64 s =
  let n = String.length s in
  let b = Buffer.create ((n + 2) / 3 * 4) in
  let g i = if i < n then Char.code s.[i] else 0 in
  let i = ref 0 in
  while !i < n do
    let v = (g !i lsl 16) lor (g (!i + 1) lsl 8) lor g (!i + 2) in
    Buffer.add_char b b64chars.[v lsr 18];
    Buffer.add_char b b64chars.[(v lsr 12) land 63];
    Buffer.add_char b (if !i + 1 < n then b64chars.[(v lsr 6) land 63] else '=');
    Buffer.add_char b (if !i + 2 < n then b64chars.[v land 63] else '=');
    i := !i + 3
  done;
  Buffer.contents b

let unbase64 s =
  let b = Buffer.create (String.length s * 3 / 4) in
  let acc = ref 0 and bits = ref 0 in
  String.iter (fun c ->
      let v = match c with
        | 'A' .. 'Z' -> Char.code c - 65 | 'a' .. 'z' -> Char.code c - 71
        | '0' .. '9' -> Char.code c + 4 | '+' -> 62 | '/' -> 63
        | '=' | ' ' | '\n' | '\r' | '\t' -> -1
        | _ -> raise (Bad "not Base64") in
      if v >= 0 then begin
        acc := ((!acc lsl 6) lor v) land 0xFFFFFF; bits := !bits + 6;
        if !bits >= 8 then begin
          bits := !bits - 8;
          Buffer.add_char b (Char.chr ((!acc lsr !bits) land 0xFF))
        end
      end) s;
  Buffer.contents b

(* {1 Randomness} *)

(* the kernel's random bytes (getrandom, through musl's getentropy): the
   runtime's seed is twelve of them, a number each *)
external random_seed : unit -> int array = "caml_sys_random_seed"

let random n =
  let b = Buffer.create (n + 12) in
  while Buffer.length b < n do
    let a = random_seed () in
    if Array.length a <> 12 then failwith "no random bytes from the system";
    Array.iter (fun v -> Buffer.add_char b (Char.chr (v land 0xFF))) a
  done;
  Buffer.sub b 0 n

let hex s = String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))
