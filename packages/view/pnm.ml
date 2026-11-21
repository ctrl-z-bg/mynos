(* Pnm: Netpbm's images, P1 to P6 (bitmaps, greys, colours; as text or
   binary), the format of MyNOS's own pictures and of QEMU's screen
   dumps; and BMP (24 and 32 bits, and 8 with a palette, uncompressed). *)

open Image

let is_pnm s = String.length s > 2 && s.[0] = 'P' && s.[1] >= '1' && s.[1] <= '6'

let read_pnm s =
  let n = String.length s in
  let pos = ref 2 in
  let rec skip () =
    if !pos < n then
      match s.[!pos] with
      | ' ' | '\t' | '\r' | '\n' -> incr pos; skip ()
      | '#' -> while !pos < n && s.[!pos] <> '\n' do incr pos done; skip ()
      | _ -> () in
  let number () =
    skip ();
    let start = !pos in
    while !pos < n && s.[!pos] >= '0' && s.[!pos] <= '9' do incr pos done;
    if !pos = start then bad "a number expected";
    int_of_string (String.sub s start (!pos - start)) in
  let kind = s.[1] in
  let w = number () in
  let h = number () in
  let maxv = if kind = '1' || kind = '4' then 1 else number () in
  if w <= 0 || h <= 0 || w * h > 16_000_000 then bad "an image of %d x %d" w h;
  if maxv <= 0 || maxv > 65535 then bad "a bad maximum value";
  incr pos;                                              (* the one blank after the header *)
  let img = create w h 0 in
  let scale v = v * 255 / maxv in
  let wide = maxv > 255 in
  let byte () = if !pos >= n then bad "the file is cut short" else (let c = Char.code s.[!pos] in incr pos; c) in
  let sample () = if wide then (let hi = byte () in let lo = byte () in scale ((hi lsl 8) lor lo)) else scale (byte ()) in
  (match kind with
   | '1' -> pos := !pos - 1;
     for i = 0 to w * h - 1 do
       skip ();
       if !pos >= n then bad "the file is cut short";
       img.pixels.(i) <- (if s.[!pos] = '1' then 0 else 0xFFFFFF); incr pos
     done
   | '2' -> pos := !pos - 1;
     for i = 0 to w * h - 1 do let g = scale (number ()) in img.pixels.(i) <- g * 0x010101 done
   | '3' -> pos := !pos - 1;
     for i = 0 to w * h - 1 do
       let r = scale (number ()) in let g = scale (number ()) in let b = scale (number ()) in
       img.pixels.(i) <- (r lsl 16) lor (g lsl 8) lor b
     done
   | '4' ->
     let stride = (w + 7) / 8 in
     for y = 0 to h - 1 do
       for x = 0 to w - 1 do
         if !pos + x / 8 >= n then bad "the file is cut short";
         let bit = (Char.code s.[!pos + x / 8] lsr (7 - x mod 8)) land 1 in
         img.pixels.(y * w + x) <- (if bit = 1 then 0 else 0xFFFFFF)
       done;
       pos := !pos + stride
     done
   | '5' -> for i = 0 to w * h - 1 do img.pixels.(i) <- sample () * 0x010101 done
   | _ ->
     for i = 0 to w * h - 1 do
       let r = sample () in let g = sample () in let b = sample () in
       img.pixels.(i) <- (r lsl 16) lor (g lsl 8) lor b
     done);
  img

let write_ppm img =
  let b = Buffer.create (img.width * img.height * 3 + 32) in
  Printf.bprintf b "P6\n%d %d\n255\n" img.width img.height;
  Array.iter (fun p ->
      Buffer.add_char b (Char.unsafe_chr (p lsr 16));
      Buffer.add_char b (Char.unsafe_chr ((p lsr 8) land 255));
      Buffer.add_char b (Char.unsafe_chr (p land 255))) img.pixels;
  Buffer.contents b

let is_bmp s = String.length s > 54 && String.sub s 0 2 = "BM"

let read_bmp s =
  let le16 o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8) in
  (* signed, through Int32: MyNOS's ints have 31 bits *)
  let le32 o = Int32.to_int (Int32.logor (Int32.of_int (le16 o)) (Int32.shift_left (Int32.of_int (le16 (o + 2))) 16)) in
  let signed v = v in
  let off = le32 10 and hsize = le32 14 in
  let w = signed (le32 18) and h = signed (le32 22) in
  let bpp = le16 28 and compression = le32 30 in
  if compression <> 0 && compression <> 3 then bad "a compressed BMP";
  let top_down = h < 0 in
  let h = abs h in
  if w <= 0 || h = 0 || w * h > 16_000_000 then bad "an image of %d x %d" w h;
  let palette =
    if bpp <= 8 then
      Array.init (1 lsl bpp) (fun i ->
          let o = 14 + hsize + 4 * i in
          if o + 3 < String.length s then
            (Char.code s.[o + 2] lsl 16) lor (Char.code s.[o + 1] lsl 8) lor Char.code s.[o]
          else 0)
    else [||] in
  let stride = (w * bpp + 31) / 32 * 4 in
  if off + stride * h > String.length s then bad "the file is cut short";
  let img = create w h 0 in
  for row = 0 to h - 1 do
    let y = if top_down then row else h - 1 - row in
    let o = off + row * stride in
    for x = 0 to w - 1 do
      img.pixels.(y * w + x) <- (match bpp with
        | 24 | 32 ->
          let p = o + x * (bpp / 8) in
          (Char.code s.[p + 2] lsl 16) lor (Char.code s.[p + 1] lsl 8) lor Char.code s.[p]
        | 8 -> palette.(Char.code s.[o + x])
        | 4 -> palette.((Char.code s.[o + x / 2] lsr (if x land 1 = 0 then 4 else 0)) land 15)
        | 1 -> palette.((Char.code s.[o + x / 8] lsr (7 - x mod 8)) land 1)
        | _ -> bad "%d bits a pixel" bpp)
    done
  done;
  img

(* any of the formats, by its first bytes *)
let read_any s =
  if Png.is_png s then Png.read s
  else if is_pnm s then read_pnm s
  else if is_bmp s then read_bmp s
  else bad "not an image MyNOS reads (PNG, PPM, PGM, PBM, BMP)"
