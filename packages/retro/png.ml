(* A PNG written from 0xRRGGBB pixels (emu/1's screenshot): 8-bit RGB, no
   filter, zlib's data in stored blocks (no compression: a screen of a
   few hundred KB), each chunk with its CRC. *)

(* CRC and Adler are 32 bits: Int32 (an int is 31 bits on the i386) *)
let crc_table = Array.init 256 (fun n ->
    let c = ref (Int32.of_int n) in
    for _ = 0 to 7 do
      c := if Int32.logand !c 1l <> 0l then Int32.logxor 0xEDB88320l (Int32.shift_right_logical !c 1)
        else Int32.shift_right_logical !c 1
    done;
    !c)

let crc s =
  let c = ref 0xFFFFFFFFl in
  String.iter (fun ch ->
      let i = Int32.to_int (Int32.logand (Int32.logxor !c (Int32.of_int (Char.code ch))) 0xFFl) in
      c := Int32.logxor crc_table.(i) (Int32.shift_right_logical !c 8)) s;
  Int32.logxor !c 0xFFFFFFFFl

let be32l b (v : int32) =
  for k = 3 downto 0 do
    Buffer.add_char b (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical v (8 * k)) 0xFFl)))
  done

let be32 b v = be32l b (Int32.of_int v)

let chunk out kind data =
  be32 out (String.length data);
  Buffer.add_string out kind; Buffer.add_string out data;
  be32l out (crc (kind ^ data))

let to_string ~width ~height (pixels : int array) =
  let raw = Buffer.create ((width * 3 + 1) * height) in
  for y = 0 to height - 1 do
    Buffer.add_char raw '\000';
    for x = 0 to width - 1 do
      let c = pixels.(y * width + x) in
      Buffer.add_char raw (Char.chr ((c lsr 16) land 0xFF));
      Buffer.add_char raw (Char.chr ((c lsr 8) land 0xFF));
      Buffer.add_char raw (Char.chr (c land 0xFF))
    done
  done;
  let raw = Buffer.contents raw in
  let z = Buffer.create (String.length raw + 1024) in
  Buffer.add_string z "\x78\x01";
  let n = String.length raw in
  let i = ref 0 in
  while !i < n do
    let len = min 65535 (n - !i) in
    Buffer.add_char z (if !i + len >= n then '\001' else '\000');
    Buffer.add_char z (Char.chr (len land 0xFF)); Buffer.add_char z (Char.chr (len lsr 8));
    let nl = len lxor 0xFFFF in
    Buffer.add_char z (Char.chr (nl land 0xFF)); Buffer.add_char z (Char.chr (nl lsr 8));
    Buffer.add_string z (String.sub raw !i len);
    i := !i + len
  done;
  let a = ref 1 and b = ref 0 in
  String.iter (fun c -> a := (!a + Char.code c) mod 65521; b := (!b + !a) mod 65521) raw;
  be32l z (Int32.logor (Int32.shift_left (Int32.of_int !b) 16) (Int32.of_int !a));
  let out = Buffer.create (Buffer.length z + 100) in
  Buffer.add_string out "\x89PNG\r\n\x1a\n";
  let ihdr = Buffer.create 13 in
  be32 ihdr width; be32 ihdr height;
  Buffer.add_string ihdr "\x08\x02\x00\x00\x00";
  chunk out "IHDR" (Buffer.contents ihdr);
  chunk out "IDAT" (Buffer.contents z);
  chunk out "IEND" "";
  Buffer.contents out

let save path ~width ~height pixels =
  let oc = open_out_bin path in
  output_string oc (to_string ~width ~height pixels);
  close_out oc
