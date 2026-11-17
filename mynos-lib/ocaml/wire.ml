(* The wire format of typed IPC: see wire.mli. *)

exception Error of string

type writer = Buffer.t
type reader = { s : string; mutable pos : int }

type shape =
  | Unit | Bool | Int | Float | String
  | Option of shape
  | List of shape
  | Tuple of shape list
  | Named of string * shape
  | Variant of (int * string * shape) list
  | Rec of string * shape
  | Var of string

type 'a t = { write : writer -> 'a -> unit; read : reader -> 'a; shape : shape Lazy.t }

let shape c = Lazy.force c.shape

let fail fmt = Printf.ksprintf (fun m -> raise (Error m)) fmt

let byte r =
  if r.pos >= String.length r.s then fail "message too short";
  let c = Char.code r.s.[r.pos] in
  r.pos <- r.pos + 1;
  c

let remaining r = String.length r.s - r.pos

let unit = { write = (fun _ () -> ()); read = (fun _ -> ()); shape = lazy Unit }

let bool = {
  write = (fun w b -> Buffer.add_char w (if b then '\001' else '\000'));
  read = (fun r -> match byte r with 0 -> false | 1 -> true
                                   | n -> fail "bool: %d" n);
  shape = lazy Bool }

(* zigzag: 0, -1, 1, -2... as 0, 1, 2, 3...; then LEB128 of the unsigned
   result (an OCaml int seen as Sys.int_size bits) *)
let int = {
  write = (fun w n ->
      let z = ref ((n lsl 1) lxor (n asr (Sys.int_size - 1))) in
      while !z land (lnot 0x7F) <> 0 do
        Buffer.add_char w (Char.chr (!z land 0x7F lor 0x80));
        z := !z lsr 7
      done;
      Buffer.add_char w (Char.chr !z));
  read = (fun r ->
      let rec go z shift =
        let b = byte r in
        let v = b land 0x7F in
        (* bits beyond our int: the value does not fit *)
        if shift >= Sys.int_size || (v lsl shift) lsr shift <> v then
          (if v <> 0 then fail "int out of range");
        let z = if shift < Sys.int_size then z lor (v lsl shift) else z in
        if b land 0x80 = 0 then z else go z (shift + 7) in
      let z = go 0 0 in
      (z lsr 1) lxor (- (z land 1)));
  shape = lazy Int }

(* a count or length: never more than the bytes left, so that a malformed
   message cannot make us allocate much *)
let count r what =
  let n = int.read r in
  if n < 0 || n > remaining r then fail "%s: bad length %d" what n;
  n

let string = {
  write = (fun w s -> int.write w (String.length s); Buffer.add_string w s);
  read = (fun r ->
      let n = count r "string" in
      let s = String.sub r.s r.pos n in
      r.pos <- r.pos + n;
      s);
  shape = lazy String }

let float = {
  write = (fun w f -> Buffer.add_int64_le w (Int64.bits_of_float f));
  read = (fun r ->
      if remaining r < 8 then fail "message too short";
      let f = Int64.float_of_bits (String.get_int64_le r.s r.pos) in
      r.pos <- r.pos + 8;
      f);
  shape = lazy Float }

let option c = {
  write = (fun w -> function
      | None -> bool.write w false
      | Some x -> bool.write w true; c.write w x);
  read = (fun r -> if bool.read r then Some (c.read r) else None);
  shape = lazy (Option (shape c)) }

(* the elements of a list or array: at most one per byte left, or one per
   message byte for elements of no bytes (unit) *)
let elements r =
  let n = int.read r in
  if n < 0 || n > String.length r.s then fail "bad count %d" n;
  n

let list c = {
  write = (fun w l -> int.write w (List.length l); List.iter (c.write w) l);
  read = (fun r -> List.init (elements r) (fun _ -> c.read r));
  shape = lazy (List (shape c)) }

let array c = {
  write = (fun w a -> int.write w (Array.length a); Array.iter (c.write w) a);
  read = (fun r -> Array.init (elements r) (fun _ -> c.read r));
  shape = lazy (List (shape c)) }

let pair a b = {
  write = (fun w (x, y) -> a.write w x; b.write w y);
  read = (fun r -> let x = a.read r in let y = b.read r in (x, y));
  shape = lazy (Tuple [ shape a; shape b ]) }

let triple a b c = {
  write = (fun w (x, y, z) -> a.write w x; b.write w y; c.write w z);
  read = (fun r ->
      let x = a.read r in let y = b.read r in let z = c.read r in (x, y, z));
  shape = lazy (Tuple [ shape a; shape b; shape c ]) }

let conv to_b of_b c = {
  write = (fun w x -> c.write w (to_b x));
  read = (fun r -> of_b (c.read r));
  shape = c.shape }

let field name c = { c with shape = lazy (Named (name, shape c)) }

type 'a case = Case : int * string * 'b t * ('b -> 'a) * ('a -> 'b option) -> 'a case

let case ?name n c inject project =
  Case (n, Option.value name ~default:(string_of_int n), c, inject, project)

let variant cases = {
  write = (fun w x ->
      let rec go = function
        | [] -> invalid_arg "Wire.variant: no case for this value"
        | Case (n, _, c, _, project) :: rest ->
          (match project x with
           | Some y -> int.write w n; c.write w y
           | None -> go rest) in
      go cases);
  read = (fun r ->
      let n = int.read r in
      match List.find_opt (fun (Case (m, _, _, _, _)) -> m = n) cases with
      | Some (Case (_, _, c, inject, _)) -> inject (c.read r)
      | None -> fail "unknown case %d" n);
  shape = lazy (Variant (List.map (fun (Case (n, name, c, _, _)) -> (n, name, shape c)) cases)) }

let result a b =
  variant [
    case ~name:"ok" 0 a (fun x -> Ok x) (function Ok x -> Some x | Stdlib.Error _ -> None);
    case ~name:"error" 1 b (fun e -> Stdlib.Error e)
      (function Stdlib.Error e -> Some e | Ok _ -> None);
  ]

(* inside, the recursive occurrences have the shape Var name; the whole,
   Rec (name, ...) *)
let fix ?(name = "t") f =
  let rec self = { write = (fun w x -> (Lazy.force c).write w x);
                   read = (fun r -> (Lazy.force c).read r);
                   shape = lazy (Var name) }
  and c = lazy (f self) in
  { self with shape = lazy (Rec (name, shape (Lazy.force c))) }

(* shapes themselves, for descriptions sent over IPC *)
let shape_codec =
  fix ~name:"shape" (fun s -> variant [
      case 0 unit (fun () -> Unit) (function Unit -> Some () | _ -> None);
      case 1 unit (fun () -> Bool) (function Bool -> Some () | _ -> None);
      case 2 unit (fun () -> Int) (function Int -> Some () | _ -> None);
      case 3 unit (fun () -> Float) (function Float -> Some () | _ -> None);
      case 4 unit (fun () -> String) (function String -> Some () | _ -> None);
      case 5 s (fun x -> Option x) (function Option x -> Some x | _ -> None);
      case 6 s (fun x -> List x) (function List x -> Some x | _ -> None);
      case 7 (list s) (fun l -> Tuple l) (function Tuple l -> Some l | _ -> None);
      case 8 (pair string s) (fun (n, x) -> Named (n, x))
        (function Named (n, x) -> Some (n, x) | _ -> None);
      case 9 (list (triple int string s)) (fun l -> Variant l)
        (function Variant l -> Some l | _ -> None);
      case 10 (pair string s) (fun (n, x) -> Rec (n, x))
        (function Rec (n, x) -> Some (n, x) | _ -> None);
      case 11 string (fun n -> Var n) (function Var n -> Some n | _ -> None) ])

let writer () = Buffer.create 64
let write w c x = c.write w x
let contents = Buffer.contents

let reader s = { s; pos = 0 }
let read r c = c.read r
let at_end r = r.pos = String.length r.s

let to_string c x = let w = writer () in c.write w x; contents w

let of_string c s =
  let r = reader s in
  let x = c.read r in
  if not (at_end r) then fail "%d bytes left over" (remaining r);
  x
