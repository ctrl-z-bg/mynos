(* Poly1305 (RFC 8439): a one-time authenticator, with Num's big integers
   (their arithmetic is C, in MyNOS's runtime). *)

open Big_int

let p = sub_big_int (shift_left_big_int unit_big_int 130) (big_int_of_int 5)
let two128 = shift_left_big_int unit_big_int 128

(* the little-endian number of [n] bytes of [s] at [o] *)
let le s o n =
  let x = ref zero_big_int in
  let i = ref (n - 1) in
  while !i >= 1 do
    let v = (Char.code s.[o + !i] lsl 8) lor Char.code s.[o + !i - 1] in
    x := add_int_big_int v (shift_left_big_int !x 16);
    i := !i - 2
  done;
  if !i = 0 then x := add_int_big_int (Char.code s.[o]) (shift_left_big_int !x 8);
  !x

(* [n] little-endian bytes of [x] *)
let to_le x n =
  String.init n (fun i -> Char.chr (int_of_big_int (extract_big_int x (8 * i) 8)))

let clamp = le "\xff\xff\xff\x0f\xfc\xff\xff\x0f\xfc\xff\xff\x0f\xfc\xff\xff\x0f" 0 16

(* the tag (16 bytes) of [msg] with the key (32 bytes) *)
let mac ~key msg =
  if String.length key <> 32 then invalid_arg "Poly1305.mac";
  let r = and_big_int (le key 0 16) clamp and s = le key 16 16 in
  let h = ref zero_big_int in
  let n = String.length msg in
  let i = ref 0 in
  while !i < n do
    let m = min 16 (n - !i) in
    let c = add_big_int (le msg !i m) (shift_left_big_int unit_big_int (8 * m)) in
    h := mod_big_int (mult_big_int (add_big_int !h c) r) p;
    i := !i + m
  done;
  to_le (mod_big_int (add_big_int !h s) two128) 16

(* the tags compared in a time that does not depend on where they differ *)
let equal a b =
  String.length a = String.length b
  && (let d = ref 0 in
      String.iteri (fun i c -> d := !d lor (Char.code c lxor Char.code b.[i])) a;
      !d = 0)
