(* SHA-256 and SHA-512 (FIPS 180-4), on Int32 and Int64: MyNOS's ints are
   31 bits on i386. The constants are computed, as the standard defines
   them (the first bits of the fractional parts of the square and cube
   roots of the first primes), with Num's big integers: no table to copy
   wrong. *)

open Big_int

let primes n =
  let rec go acc k c =
    if c = n then List.rev acc
    else if List.for_all (fun p -> k mod p <> 0) acc then go (k :: acc) (k + 1) (c + 1)
    else go acc (k + 1) c in
  go [] 2 0

(* the integer cube root (Newton, from above) *)
let icbrt n =
  let three = big_int_of_int 3 in
  let rec go x =
    let y = div_big_int (add_big_int (mult_int_big_int 2 x) (div_big_int n (square_big_int x))) three in
    if ge_big_int y x then x else go y in
  go (shift_left_big_int unit_big_int (num_bits_big_int n / 3 + 1))

let bits x ofs n = extract_big_int x ofs n

let to_int32 x = Int64.to_int32 (int64_of_big_int (bits x 0 32))
let to_int64 x =
  Int64.logor (Int64.shift_left (int64_of_big_int (bits x 32 32)) 32)
    (int64_of_big_int (bits x 0 32))

let root f shift conv n =
  Array.of_list (List.map (fun p -> conv (f (shift_left_big_int (big_int_of_int p) shift))) (primes n))

let k256 = lazy (root icbrt 96 to_int32 64)
let h256 = lazy (root sqrt_big_int 64 to_int32 8)
let k512 = lazy (root icbrt 192 to_int64 80)
let h512 = lazy (root sqrt_big_int 128 to_int64 8)

(* the message, padded: a 1 bit, zeros, its length in bits *)
let pad s block lenbytes =
  let len = String.length s in
  let n = (len + 1 + lenbytes + block - 1) / block * block in
  let m = Bytes.make n '\000' in
  Bytes.blit_string s 0 m 0 len;
  Bytes.set m len '\x80';
  Bytes.set_int64_be m (n - 8) (Int64.mul (Int64.of_int len) 8L);
  m

let sha256 s =
  let open Int32 in
  let k = Lazy.force k256 and h = Array.copy (Lazy.force h256) in
  let m = pad s 64 8 in
  let w = Array.make 64 0l in
  let rotr x n = logor (shift_right_logical x n) (shift_left x (32 - n)) in
  for blk = 0 to Bytes.length m / 64 - 1 do
    for t = 0 to 15 do w.(t) <- Bytes.get_int32_be m (blk * 64 + 4 * t) done;
    for t = 16 to 63 do
      let x = w.(t - 15) and y = w.(t - 2) in
      let s0 = logxor (logxor (rotr x 7) (rotr x 18)) (shift_right_logical x 3) in
      let s1 = logxor (logxor (rotr y 17) (rotr y 19)) (shift_right_logical y 10) in
      w.(t) <- add (add w.(t - 16) s0) (add w.(t - 7) s1)
    done;
    let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) and d = ref h.(3)
    and e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
    for t = 0 to 63 do
      let e' = !e and a' = !a in
      let s1 = logxor (logxor (rotr e' 6) (rotr e' 11)) (rotr e' 25) in
      let ch = logxor (logand e' !f) (logand (lognot e') !g) in
      let t1 = add (add (add !hh s1) (add ch k.(t))) w.(t) in
      let s0 = logxor (logxor (rotr a' 2) (rotr a' 13)) (rotr a' 22) in
      let maj = logxor (logxor (logand a' !b) (logand a' !c)) (logand !b !c) in
      let t2 = add s0 maj in
      hh := !g; g := !f; f := e'; e := add !d t1; d := !c; c := !b; b := a'; a := add t1 t2
    done;
    List.iteri (fun i v -> h.(i) <- add h.(i) v) [ !a; !b; !c; !d; !e; !f; !g; !hh ]
  done;
  let out = Bytes.create 32 in
  Array.iteri (fun i v -> Bytes.set_int32_be out (4 * i) v) h;
  Bytes.unsafe_to_string out

let sha512 s =
  let open Int64 in
  let k = Lazy.force k512 and h = Array.copy (Lazy.force h512) in
  let m = pad s 128 16 in
  let w = Array.make 80 0L in
  let rotr x n = logor (shift_right_logical x n) (shift_left x (64 - n)) in
  for blk = 0 to Bytes.length m / 128 - 1 do
    for t = 0 to 15 do w.(t) <- Bytes.get_int64_be m (blk * 128 + 8 * t) done;
    for t = 16 to 79 do
      let x = w.(t - 15) and y = w.(t - 2) in
      let s0 = logxor (logxor (rotr x 1) (rotr x 8)) (shift_right_logical x 7) in
      let s1 = logxor (logxor (rotr y 19) (rotr y 61)) (shift_right_logical y 6) in
      w.(t) <- add (add w.(t - 16) s0) (add w.(t - 7) s1)
    done;
    let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) and d = ref h.(3)
    and e = ref h.(4) and f = ref h.(5) and g = ref h.(6) and hh = ref h.(7) in
    for t = 0 to 79 do
      let e' = !e and a' = !a in
      let s1 = logxor (logxor (rotr e' 14) (rotr e' 18)) (rotr e' 41) in
      let ch = logxor (logand e' !f) (logand (lognot e') !g) in
      let t1 = add (add (add !hh s1) (add ch k.(t))) w.(t) in
      let s0 = logxor (logxor (rotr a' 28) (rotr a' 34)) (rotr a' 39) in
      let maj = logxor (logxor (logand a' !b) (logand a' !c)) (logand !b !c) in
      let t2 = add s0 maj in
      hh := !g; g := !f; f := e'; e := add !d t1; d := !c; c := !b; b := a'; a := add t1 t2
    done;
    List.iteri (fun i v -> h.(i) <- add h.(i) v) [ !a; !b; !c; !d; !e; !f; !g; !hh ]
  done;
  let out = Bytes.create 64 in
  Array.iteri (fun i v -> Bytes.set_int64_be out (8 * i) v) h;
  Bytes.unsafe_to_string out

(* HMAC (RFC 2104) with SHA-256 *)
let hmac_sha256 ~key msg =
  let key = if String.length key > 64 then sha256 key else key in
  let key = key ^ String.make (64 - String.length key) '\000' in
  let x c = String.map (fun k -> Char.chr (Char.code k lxor c)) key in
  sha256 (x 0x5c ^ sha256 (x 0x36 ^ msg))
