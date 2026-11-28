(* ChaCha20 (D. J. Bernstein; RFC 8439): each 32-bit word as two halves of
   16 bits in plain ints, so that nothing is boxed and nothing overflows
   MyNOS's 31-bit ints on i386. Words 12 to 15 of the state are given as
   16 bytes: OpenSSH's chacha20-poly1305 has a 64-bit counter and a
   64-bit nonce there, RFC 8439 a 32-bit counter and a 96-bit nonce; the
   counter (word 12, carrying into 13) goes up by one a block. *)

let sigma = "expand 32-byte k"

type t = {
  init_h : int array; init_l : int array;     (* the state, before a block *)
  xh : int array; xl : int array;             (* the block's work *)
}

let word s i = (Char.code s.[i] lor (Char.code s.[i + 1] lsl 8)),
               (Char.code s.[i + 2] lor (Char.code s.[i + 3] lsl 8))

(* the state from a key (32 bytes) and words 12-15 (16 bytes) *)
let create ~key ~iv =
  if String.length key <> 32 || String.length iv <> 16 then invalid_arg "Chacha20.create";
  let init_h = Array.make 16 0 and init_l = Array.make 16 0 in
  let set n s i = let l, h = word s i in init_l.(n) <- l; init_h.(n) <- h in
  for n = 0 to 3 do set n sigma (4 * n) done;
  for n = 0 to 7 do set (4 + n) key (4 * n) done;
  for n = 0 to 3 do set (12 + n) iv (4 * n) done;
  { init_h; init_l; xh = Array.make 16 0; xl = Array.make 16 0 }

let quarter xh xl a b c d =
  (* x.(p) <- x.(p) + x.(q) *)
  let add p q =
    let l = xl.(p) + xl.(q) in
    xh.(p) <- (xh.(p) + xh.(q) + (l lsr 16)) land 0xFFFF;
    xl.(p) <- l land 0xFFFF in
  (* x.(p) <- (x.(p) xor x.(q)) rotated left by r *)
  let xor_rot p q r =
    let h = xh.(p) lxor xh.(q) and l = xl.(p) lxor xl.(q) in
    if r = 16 then begin xh.(p) <- l; xl.(p) <- h end
    else begin
      xh.(p) <- ((h lsl r) lor (l lsr (16 - r))) land 0xFFFF;
      xl.(p) <- ((l lsl r) lor (h lsr (16 - r))) land 0xFFFF
    end in
  add a b; xor_rot d a 16;
  add c d; xor_rot b c 12;
  add a b; xor_rot d a 8;
  add c d; xor_rot b c 7

(* the next block of key stream into [out] at [o]; the counter goes on *)
let block t out o =
  let xh = t.xh and xl = t.xl in
  Array.blit t.init_h 0 xh 0 16; Array.blit t.init_l 0 xl 0 16;
  for _ = 1 to 10 do
    quarter xh xl 0 4 8 12; quarter xh xl 1 5 9 13;
    quarter xh xl 2 6 10 14; quarter xh xl 3 7 11 15;
    quarter xh xl 0 5 10 15; quarter xh xl 1 6 11 12;
    quarter xh xl 2 7 8 13; quarter xh xl 3 4 9 14
  done;
  for i = 0 to 15 do
    let l = xl.(i) + t.init_l.(i) in
    let h = (xh.(i) + t.init_h.(i) + (l lsr 16)) land 0xFFFF and l = l land 0xFFFF in
    Bytes.unsafe_set out (o + 4 * i) (Char.unsafe_chr (l land 0xFF));
    Bytes.unsafe_set out (o + 4 * i + 1) (Char.unsafe_chr (l lsr 8));
    Bytes.unsafe_set out (o + 4 * i + 2) (Char.unsafe_chr (h land 0xFF));
    Bytes.unsafe_set out (o + 4 * i + 3) (Char.unsafe_chr (h lsr 8))
  done;
  (* the counter: word 12, carrying into word 13 *)
  let inc n =
    let l = t.init_l.(n) + 1 in
    if l < 0x10000 then (t.init_l.(n) <- l; false)
    else begin
      t.init_l.(n) <- 0;
      let h = t.init_h.(n) + 1 in
      if h < 0x10000 then (t.init_h.(n) <- h; false) else (t.init_h.(n) <- 0; true)
    end in
  if inc 12 then ignore (inc 13)

(* [s] xor the key stream (its next bytes, whole blocks of 64 used) *)
let xor t s =
  let n = String.length s in
  let out = Bytes.create n and ks = Bytes.create 64 in
  let i = ref 0 in
  while !i < n do
    block t ks 0;
    let m = min 64 (n - !i) in
    for j = 0 to m - 1 do
      Bytes.unsafe_set out (!i + j)
        (Char.unsafe_chr (Char.code (String.unsafe_get s (!i + j)) lxor Char.code (Bytes.unsafe_get ks j)))
    done;
    i := !i + m
  done;
  Bytes.unsafe_to_string out

(* the key stream's next [n] bytes *)
let stream t n = xor t (String.make n '\000')
