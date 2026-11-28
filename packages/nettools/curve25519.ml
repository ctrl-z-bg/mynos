(* Curve25519: X25519, the key agreement (RFC 7748), and Ed25519, the
   signatures (RFC 8032), over the field of 2^255 - 19, with Num's big
   integers. Straight from the RFCs, not in constant time: bytecode could
   not promise it anyway. *)

open Big_int

let big = big_int_of_int
let p = sub_big_int (shift_left_big_int unit_big_int 255) (big 19)
let ( +: ) a b = let s = add_big_int a b in if ge_big_int s p then sub_big_int s p else s
let ( -: ) a b = let s = sub_big_int a b in if sign_big_int s < 0 then add_big_int s p else s
let ( *: ) a b = mod_big_int (mult_big_int a b) p
let sq a = mod_big_int (square_big_int a) p

let pow_mod b e m =
  let r = ref unit_big_int in
  for i = num_bits_big_int e - 1 downto 0 do
    r := mod_big_int (square_big_int !r) m;
    if sign_big_int (extract_big_int e i 1) <> 0 then r := mod_big_int (mult_big_int !r b) m
  done;
  !r

let inv a = pow_mod a (sub_big_int p (big 2)) p

let le = Poly1305.le
let to_le = Poly1305.to_le
let bit k i = sign_big_int (extract_big_int k i 1) <> 0

(* {1 X25519} *)

let clamp_scalar s =
  let b = Bytes.of_string s in
  Bytes.set b 0 (Char.chr (Char.code s.[0] land 248));
  Bytes.set b 31 (Char.chr (Char.code s.[31] land 127 lor 64));
  le (Bytes.to_string b) 0 32

let a24 = big 121665

(* [x25519 scalar u]: both 32 bytes, the result too *)
let x25519 scalar u =
  if String.length scalar <> 32 || String.length u <> 32 then invalid_arg "x25519";
  let k = clamp_scalar scalar in
  let x1 = mod_big_int (extract_big_int (le u 0 32) 0 255) p in
  let x2 = ref unit_big_int and z2 = ref zero_big_int
  and x3 = ref x1 and z3 = ref unit_big_int in
  let swap = ref false in
  let cswap () =
    let t = !x2 in x2 := !x3; x3 := t;
    let t = !z2 in z2 := !z3; z3 := t in
  for t = 254 downto 0 do
    let kt = bit k t in
    if kt <> !swap then cswap ();
    swap := kt;
    let a = !x2 +: !z2 and b = !x2 -: !z2 in
    let aa = sq a and bb = sq b in
    let e = aa -: bb in
    let c = !x3 +: !z3 and d = !x3 -: !z3 in
    let da = d *: a and cb = c *: b in
    x3 := sq (da +: cb);
    z3 := x1 *: sq (da -: cb);
    x2 := aa *: bb;
    z2 := e *: (aa +: (a24 *: e))
  done;
  if !swap then cswap ();
  to_le (!x2 *: inv !z2) 32

let base_u = "\009" ^ String.make 31 '\000'

(* the public key of a secret (32 random bytes) *)
let x25519_public secret = x25519 secret base_u

(* {1 Ed25519} *)

(* the group's order *)
let l = add_big_int (shift_left_big_int unit_big_int 252)
    (big_int_of_string "27742317777372353535851937790883648493")
let d = (big 0 -: big 121665) *: inv (big 121666)
let d2 = d +: d
let sqrt_m1 = pow_mod (big 2) (div_big_int (sub_big_int p unit_big_int) (big 4)) p

(* extended coordinates: x = X/Z, y = Y/Z, x y = T/Z *)
type point = { x : big_int; y : big_int; z : big_int; t : big_int }

let add_pt a b =
  let ca = (a.y -: a.x) *: (b.y -: b.x) and cb = (a.y +: a.x) *: (b.y +: b.x) in
  let cc = a.t *: d2 *: b.t and dd = (a.z +: a.z) *: b.z in
  let e = cb -: ca and f = dd -: cc and g = dd +: cc and h = cb +: ca in
  { x = e *: f; y = g *: h; t = e *: h; z = f *: g }

let zero = { x = zero_big_int; y = unit_big_int; z = unit_big_int; t = zero_big_int }

let mul_pt k pt =
  let r = ref zero in
  for i = num_bits_big_int k - 1 downto 0 do
    r := add_pt !r !r;
    if bit k i then r := add_pt !r pt
  done;
  !r

(* x from y and x's low bit; None: not a point *)
let recover_x y sign =
  if ge_big_int y p then None else
  let x2 = (sq y -: unit_big_int) *: inv ((d *: sq y) +: unit_big_int) in
  if sign_big_int x2 = 0 then (if sign then None else Some zero_big_int) else
  let x = pow_mod x2 (div_big_int (add_big_int p (big 3)) (big 8)) p in
  let x = if eq_big_int (sq x) x2 then x else x *: sqrt_m1 in
  if not (eq_big_int (sq x) x2) then None
  else Some (if bit x 0 <> sign then p -: x else x)

let base =
  let y = big 4 *: inv (big 5) in
  match recover_x y false with
  | Some x -> { x; y; z = unit_big_int; t = x *: y }
  | None -> assert false

let encode pt =
  let zi = inv pt.z in
  let x = pt.x *: zi and y = pt.y *: zi in
  let y = if bit x 0 then add_big_int y (shift_left_big_int unit_big_int 255) else y in
  to_le y 32

let decode s =
  if String.length s <> 32 then None else
  let v = le s 0 32 in
  let y = extract_big_int v 0 255 in
  match recover_x y (bit v 255) with
  | Some x -> Some { x; y; z = unit_big_int; t = x *: y }
  | None -> None

let hash_mod_l s = mod_big_int (le (Sha2.sha512 s) 0 64) l

(* a key from its seed (32 random bytes): the scalar, the prefix, the
   public key *)
let expand seed =
  let h = Sha2.sha512 seed in
  let a = clamp_scalar (String.sub h 0 32) in
  a, String.sub h 32 32, encode (mul_pt a base)

let ed25519_public seed = let _, _, pub = expand seed in pub

let sign ~seed msg =
  let a, prefix, pub = expand seed in
  let r = hash_mod_l (prefix ^ msg) in
  let rr = encode (mul_pt r base) in
  let k = hash_mod_l (rr ^ pub ^ msg) in
  let s = mod_big_int (add_big_int r (mult_big_int k a)) l in
  rr ^ to_le s 32

let verify ~pub msg signature =
  String.length signature = 64 && String.length pub = 32 &&
  match decode pub, decode (String.sub signature 0 32) with
  | Some a, Some r ->
    let s = le signature 32 32 in
    lt_big_int s l &&
    let k = hash_mod_l (String.sub signature 0 32 ^ pub ^ msg) in
    encode (mul_pt s base) = encode (add_pt r (mul_pt k a))
  | _ -> false
