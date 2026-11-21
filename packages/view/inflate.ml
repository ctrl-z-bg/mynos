(* Inflate: the decompression of DEFLATE (RFC 1951), and of zlib's
   wrapping of it (RFC 1950), as PNG files hold their pixels. After Mark
   Adler's puff.c: canonical Huffman codes decoded a bit at a time. *)

exception Error of string
let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

type input = { data : string; mutable pos : int; mutable bitbuf : int; mutable bitcnt : int }

let bits s need =
  let v = ref s.bitbuf in
  while s.bitcnt < need do
    if s.pos >= String.length s.data then error "the data ends too soon";
    v := !v lor (Char.code s.data.[s.pos] lsl s.bitcnt);
    s.pos <- s.pos + 1;
    s.bitcnt <- s.bitcnt + 8
  done;
  s.bitbuf <- !v lsr need;
  s.bitcnt <- s.bitcnt - need;
  !v land ((1 lsl need) - 1)

(* a code: how many symbols have each length, and the symbols in order *)
type huffman = { count : int array; symbol : int array }

let build lengths n =
  let count = Array.make 16 0 in
  for i = 0 to n - 1 do count.(lengths.(i)) <- count.(lengths.(i)) + 1 done;
  let offs = Array.make 16 0 in
  for len = 1 to 14 do offs.(len + 1) <- offs.(len) + count.(len) done;
  let symbol = Array.make n 0 in
  for i = 0 to n - 1 do
    if lengths.(i) <> 0 then begin
      symbol.(offs.(lengths.(i))) <- i;
      offs.(lengths.(i)) <- offs.(lengths.(i)) + 1
    end
  done;
  count.(0) <- 0;
  { count; symbol }

let decode s h =
  let code = ref 0 and first = ref 0 and index = ref 0 in
  let rec go len =
    if len > 15 then error "a bad code"
    else begin
      code := !code lor bits s 1;
      let c = h.count.(len) in
      if !code - c < !first then h.symbol.(!index + (!code - !first))
      else begin
        index := !index + c;
        first := (!first + c) lsl 1;
        code := !code lsl 1;
        go (len + 1)
      end
    end in
  go 1

let lbase = [| 3; 4; 5; 6; 7; 8; 9; 10; 11; 13; 15; 17; 19; 23; 27; 31; 35; 43; 51; 59;
               67; 83; 99; 115; 131; 163; 195; 227; 258 |]
let lext = [| 0; 0; 0; 0; 0; 0; 0; 0; 1; 1; 1; 1; 2; 2; 2; 2; 3; 3; 3; 3; 4; 4; 4; 4; 5; 5; 5; 5; 0 |]
let dbase = [| 1; 2; 3; 4; 5; 7; 9; 13; 17; 25; 33; 49; 65; 97; 129; 193; 257; 385; 513; 769;
               1025; 1537; 2049; 3073; 4097; 6145; 8193; 12289; 16385; 24577 |]
let dext = [| 0; 0; 0; 0; 1; 1; 2; 2; 3; 3; 4; 4; 5; 5; 6; 6; 7; 7; 8; 8; 9; 9; 10; 10;
              11; 11; 12; 12; 13; 13 |]

let codes s out lencode distcode =
  let rec go () =
    let sym = decode s lencode in
    if sym < 256 then (Buffer.add_char out (Char.unsafe_chr sym); go ())
    else if sym > 256 then begin
      let sym = sym - 257 in
      if sym >= 29 then error "a bad length";
      let len = lbase.(sym) + bits s lext.(sym) in
      let dsym = decode s distcode in
      if dsym >= 30 then error "a bad distance";
      let dist = dbase.(dsym) + bits s dext.(dsym) in
      let start = Buffer.length out - dist in
      if start < 0 then error "a distance too far back";
      for i = 0 to len - 1 do Buffer.add_char out (Buffer.nth out (start + i)) done;
      go ()
    end in
  go ()

let fixed = lazy (
  let l = Array.make 288 0 in
  for i = 0 to 143 do l.(i) <- 8 done;
  for i = 144 to 255 do l.(i) <- 9 done;
  for i = 256 to 279 do l.(i) <- 7 done;
  for i = 280 to 287 do l.(i) <- 8 done;
  build l 288, build (Array.make 30 5) 30)

let order = [| 16; 17; 18; 0; 8; 7; 9; 6; 10; 5; 11; 4; 12; 3; 13; 2; 14; 1; 15 |]

let dynamic s out =
  let nlen = bits s 5 + 257 in
  let ndist = bits s 5 + 1 in
  let ncode = bits s 4 + 4 in
  let lengths = Array.make 320 0 in
  for i = 0 to ncode - 1 do lengths.(order.(i)) <- bits s 3 done;
  let lencode = build lengths 19 in
  let lengths = Array.make 320 0 in
  let i = ref 0 in
  while !i < nlen + ndist do
    let sym = decode s lencode in
    if sym < 16 then (lengths.(!i) <- sym; incr i)
    else begin
      let len, rep = match sym with
        | 16 -> if !i = 0 then error "a repeat with nothing before"; lengths.(!i - 1), 3 + bits s 2
        | 17 -> 0, 3 + bits s 3
        | _ -> 0, 11 + bits s 7 in
      if !i + rep > nlen + ndist then error "too many lengths";
      for _ = 1 to rep do lengths.(!i) <- len; incr i done
    end
  done;
  let lencode = build lengths nlen in
  let distcode = build (Array.sub lengths nlen ndist) ndist in
  codes s out lencode distcode

let stored s out =
  s.bitbuf <- 0; s.bitcnt <- 0;
  if s.pos + 4 > String.length s.data then error "the data ends too soon";
  let b k = Char.code s.data.[s.pos + k] in
  let len = b 0 lor (b 1 lsl 8) in
  s.pos <- s.pos + 4;
  if s.pos + len > String.length s.data then error "the data ends too soon";
  Buffer.add_string out (String.sub s.data s.pos len);
  s.pos <- s.pos + len

let inflate ?(pos = 0) data =
  let s = { data; pos; bitbuf = 0; bitcnt = 0 } in
  let out = Buffer.create (4 * String.length data) in
  let rec go () =
    let last = bits s 1 in
    (match bits s 2 with
     | 0 -> stored s out
     | 1 -> let l, d = Lazy.force fixed in codes s out l d
     | 2 -> dynamic s out
     | _ -> error "a bad block type");
    if last = 0 then go () in
  go ();
  Buffer.contents out

(* zlib: two bytes of header, then DEFLATE *)
let zlib data =
  if String.length data < 2 then error "too short";
  let cmf = Char.code data.[0] and flg = Char.code data.[1] in
  if cmf land 15 <> 8 || ((cmf lsl 8) lor flg) mod 31 <> 0 then error "not zlib data";
  if flg land 0x20 <> 0 then error "a preset dictionary";
  inflate ~pos:2 data

(* {1 Writing: a small deflate}

   One block of fixed Huffman codes; repeats found at distances 1 and 3
   only (a run of one byte, a run of one pixel), which is most of what a
   drawing has. Enough to make a picture small, in a few lines. *)

type bits_out = { buf : Buffer.t; mutable acc : int; mutable n : int }

let put_bits o v len =
  o.acc <- o.acc lor (v lsl o.n);
  o.n <- o.n + len;
  while o.n >= 8 do
    Buffer.add_char o.buf (Char.unsafe_chr (o.acc land 255));
    o.acc <- o.acc lsr 8; o.n <- o.n - 8
  done

(* a Huffman code goes most significant bit first *)
let put_code o code len =
  let r = ref 0 in
  for i = 0 to len - 1 do if code land (1 lsl i) <> 0 then r := !r lor (1 lsl (len - 1 - i)) done;
  put_bits o !r len

let put_symbol o sym =
  if sym < 144 then put_code o (0x30 + sym) 8
  else if sym < 256 then put_code o (0x190 + sym - 144) 9
  else if sym < 280 then put_code o (sym - 256) 7
  else put_code o (0xC0 + sym - 280) 8

let put_length o len =
  let i = ref 28 in
  while lbase.(!i) > len do decr i done;
  put_symbol o (257 + !i);
  if lext.(!i) > 0 then put_bits o (len - lbase.(!i)) lext.(!i)

let put_distance o d =
  let i = ref 29 in
  while dbase.(!i) > d do decr i done;
  put_code o !i 5;
  if dext.(!i) > 0 then put_bits o (d - dbase.(!i)) dext.(!i)

let deflate data =
  let n = String.length data in
  let o = { buf = Buffer.create (n / 4 + 64); acc = 0; n = 0 } in
  put_bits o 1 1; put_bits o 1 2;                    (* the last block, fixed codes *)
  let i = ref 0 in
  while !i < n do
    let best_len = ref 0 and best_d = ref 0 in
    List.iter (fun d ->
        if !i >= d then begin
          let l = ref 0 in
          while !l < 258 && !i + !l < n && data.[!i + !l] = data.[!i + !l - d] do incr l done;
          if !l > !best_len then begin best_len := !l; best_d := d end
        end) [ 1; 3 ];
    if !best_len >= 3 then begin
      put_length o !best_len; put_distance o !best_d; i := !i + !best_len
    end else begin
      put_symbol o (Char.code data.[!i]); incr i
    end
  done;
  put_symbol o 256;
  if o.n > 0 then put_bits o 0 (8 - o.n);
  Buffer.contents o.buf

(* Adler-32, as its two halves: MyNOS's ints have 31 bits *)
let adler32 s =
  let a = ref 1 and b = ref 0 in
  String.iter (fun c -> a := (!a + Char.code c) mod 65521; b := (!b + !a) mod 65521) s;
  (!b, !a)

let zlib_deflate data =
  let out = Buffer.create (String.length data / 4 + 64) in
  Buffer.add_string out "\x78\x01";
  Buffer.add_string out (deflate data);
  let b, a = adler32 data in
  List.iter (fun v -> Buffer.add_char out (Char.chr v)) [ b lsr 8; b land 255; a lsr 8; a land 255 ];
  Buffer.contents out
