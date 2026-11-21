(* Png: reading PNG images (8 bits a sample, or fewer for grey and
   palettes; 16 read as 8; with or without alpha, laid on white;
   interlaced too), and writing them (RGB, each row filtered against the
   one above, compressed by Inflate's small deflate). *)

open Image

(* a length or a size: PNG keeps them below 2^31 *)
let be32 s o =
  if Char.code s.[o] >= 0x40 then bad "a number too large";
  (Char.code s.[o] lsl 24) lor (Char.code s.[o + 1] lsl 16)
  lor (Char.code s.[o + 2] lsl 8) lor Char.code s.[o + 3]

let signature = "\137PNG\r\n\026\n"

let is_png s = String.length s > 8 && String.sub s 0 8 = signature

(* CRC-32, as two halves of 16 bits: MyNOS's ints have 31 bits, and
   Int32 is boxed (slow) *)
let crc_table = lazy (Array.init 256 (fun n ->
    let hi = ref 0 and lo = ref n in
    for _ = 0 to 7 do
      let odd = !lo land 1 <> 0 in
      lo := ((!lo lsr 1) lor ((!hi land 1) lsl 15)) land 0xFFFF;
      hi := !hi lsr 1;
      if odd then begin hi := !hi lxor 0xEDB8; lo := !lo lxor 0x8320 end
    done;
    (!hi, !lo)))

(* the CRC, as its 4 bytes, most significant first *)
let crc s =
  let t = Lazy.force crc_table in
  let hi = ref 0xFFFF and lo = ref 0xFFFF in
  String.iter (fun ch ->
      let (th, tl) = t.((!lo lxor Char.code ch) land 255) in
      let nlo = ((!lo lsr 8) lor ((!hi land 255) lsl 8)) lxor tl in
      hi := (!hi lsr 8) lxor th; lo := nlo) s;
  let hi = !hi lxor 0xFFFF and lo = !lo lxor 0xFFFF in
  [ hi lsr 8; hi land 255; lo lsr 8; lo land 255 ]

let paeth a b c =
  let p = a + b - c in
  let pa = abs (p - a) and pb = abs (p - b) and pc = abs (p - c) in
  if pa <= pb && pa <= pc then a else if pb <= pc then b else c

let read s =
  if not (is_png s) then bad "not a PNG file";
  let width = ref 0 and height = ref 0 and depth = ref 0 and ctype = ref 0 and interlace = ref 0 in
  let palette = ref [||] and trns = ref [||] and idat = Buffer.create (String.length s) in
  let rec chunks o =
    if o + 8 <= String.length s then begin
      let len = be32 s o and kind = String.sub s (o + 4) 4 in
      if o + 12 + len > String.length s then bad "the file is cut short";
      let d = String.sub s (o + 8) len in
      (match kind with
       | "IHDR" ->
         width := be32 d 0; height := be32 d 4;
         depth := Char.code d.[8]; ctype := Char.code d.[9]; interlace := Char.code d.[12]
       | "PLTE" -> palette := Array.init (len / 3) (fun i ->
           (Char.code d.[3 * i] lsl 16) lor (Char.code d.[3 * i + 1] lsl 8) lor Char.code d.[3 * i + 2])
       | "tRNS" -> trns := Array.init len (fun i -> Char.code d.[i])
       | "IDAT" -> Buffer.add_string idat d
       | _ -> ());
      if kind <> "IEND" then chunks (o + 12 + len)
    end in
  chunks 8;
  let w = !width and h = !height and depth = !depth and ctype = !ctype in
  if w <= 0 || h <= 0 || w * h > 16_000_000 then bad "an image of %d x %d" w h;
  let channels = match ctype with 0 -> 1 | 2 -> 3 | 3 -> 1 | 4 -> 2 | 6 -> 4 | _ -> bad "colour type %d" ctype in
  if ctype = 3 && !palette = [||] then bad "a palette image without its palette";
  let raw = try Inflate.zlib (Buffer.contents idat) with Inflate.Error m -> bad "%s" m in
  let bpp = max 1 (channels * depth / 8) in            (* bytes a pixel, for the filters *)
  let img = create w h 0xFFFFFF in
  let pos = ref 0 in
  (* one pass: the pixels (x0 + i*dx, y0 + j*dy) *)
  let pass x0 y0 dx dy =
    let pw = (w - x0 + dx - 1) / dx and ph = (h - y0 + dy - 1) / dy in
    if pw > 0 && ph > 0 then begin
      let stride = (pw * channels * depth + 7) / 8 in
      let prev = Bytes.make stride '\000' and cur = Bytes.make stride '\000' in
      for j = 0 to ph - 1 do
        if !pos + 1 + stride > String.length raw then bad "the pixels are cut short";
        let ft = Char.code raw.[!pos] in
        for i = 0 to stride - 1 do
          let x = Char.code raw.[!pos + 1 + i] in
          let a = if i >= bpp then Char.code (Bytes.unsafe_get cur (i - bpp)) else 0 in
          let b = Char.code (Bytes.unsafe_get prev i) in
          let c = if i >= bpp then Char.code (Bytes.unsafe_get prev (i - bpp)) else 0 in
          let v = match ft with
            | 0 -> x | 1 -> x + a | 2 -> x + b | 3 -> x + (a + b) / 2 | 4 -> x + paeth a b c
            | _ -> bad "a bad filter" in
          Bytes.unsafe_set cur i (Char.unsafe_chr (v land 255))
        done;
        pos := !pos + 1 + stride;
        (* the samples *)
        let sample k =
          if depth = 8 then Char.code (Bytes.unsafe_get cur k)
          else if depth = 16 then Char.code (Bytes.unsafe_get cur (2 * k))
          else
            let per = 8 / depth in
            let byte = Char.code (Bytes.unsafe_get cur (k / per)) in
            (byte lsr (8 - depth * (k mod per + 1))) land ((1 lsl depth) - 1) in
        let scale v = if depth >= 8 then v else v * 255 / ((1 lsl depth) - 1) in
        let over v alpha = (v * alpha + 255 * (255 - alpha)) / 255 in
        for i = 0 to pw - 1 do
          let k = i * channels in
          let rgb = match ctype with
            | 0 -> let g = scale (sample k) in (g lsl 16) lor (g lsl 8) lor g
            | 2 -> (sample k lsl 16) lor (sample (k + 1) lsl 8) lor sample (k + 2)
            | 3 ->
              let idx = sample k in
              let c = if idx < Array.length !palette then !palette.(idx) else 0 in
              if idx < Array.length !trns then
                let a = !trns.(idx) in
                (over (c lsr 16) a lsl 16) lor (over ((c lsr 8) land 255) a lsl 8) lor over (c land 255) a
              else c
            | 4 -> let g = over (sample k) (sample (k + 1)) in (g lsl 16) lor (g lsl 8) lor g
            | _ ->
              let a = sample (k + 3) in
              (over (sample k) a lsl 16) lor (over (sample (k + 1)) a lsl 8) lor over (sample (k + 2)) a in
          img.pixels.((y0 + j * dy) * w + x0 + i * dx) <- rgb
        done;
        Bytes.blit cur 0 prev 0 stride
      done
    end in
  if !interlace = 1 then
    List.iter (fun (x0, y0, dx, dy) -> pass x0 y0 dx dy)
      [ 0, 0, 8, 8; 4, 0, 8, 8; 0, 4, 4, 8; 2, 0, 4, 4; 0, 2, 2, 4; 1, 0, 2, 2; 0, 1, 1, 2 ]
  else pass 0 0 1 1;
  img

let write img =
  let b = Buffer.create (img.width * img.height * 3 + 1024) in
  Buffer.add_string b signature;
  let chunk kind data =
    let len = String.length data in
    List.iter (fun sh -> Buffer.add_char b (Char.chr ((len lsr sh) land 255))) [ 24; 16; 8; 0 ];
    Buffer.add_string b kind; Buffer.add_string b data;
    List.iter (fun v -> Buffer.add_char b (Char.chr v)) (crc (kind ^ data)) in
  let be n = String.init 4 (fun i -> Char.chr ((n lsr (24 - 8 * i)) land 255)) in
  chunk "IHDR" (be img.width ^ be img.height ^ "\008\002\000\000\000");
  let raw = Bytes.create (img.height * (1 + 3 * img.width)) in
  for y = 0 to img.height - 1 do
    let o = y * (1 + 3 * img.width) in
    (* filter 2, Up: each byte less the one above it; a picture's rows
       are much alike, and what is alike becomes runs of zeros *)
    Bytes.set raw o '\002';
    for x = 0 to img.width - 1 do
      let p = img.pixels.(y * img.width + x) in
      let q = if y = 0 then 0 else img.pixels.((y - 1) * img.width + x) in
      Bytes.set raw (o + 1 + 3 * x) (Char.unsafe_chr (((p lsr 16) - (q lsr 16)) land 255));
      Bytes.set raw (o + 2 + 3 * x) (Char.unsafe_chr ((((p lsr 8) land 255) - ((q lsr 8) land 255)) land 255));
      Bytes.set raw (o + 3 + 3 * x) (Char.unsafe_chr (((p land 255) - (q land 255)) land 255))
    done
  done;
  chunk "IDAT" (Inflate.zlib_deflate (Bytes.unsafe_to_string raw));
  chunk "IEND" "";
  Buffer.contents b
