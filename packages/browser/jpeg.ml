(* Jpeg: baseline JPEG (JFIF), decoded into an Image.t: Huffman coding,
   8 x 8 blocks, the inverse DCT, YCbCr to RGB, any sampling of the
   chroma (4:4:4, 4:2:2, 4:2:0...), greyscale, restart markers.
   Progressive and arithmetic-coded JPEGs are refused (Image.Bad). *)

let bad fmt = Printf.ksprintf (fun s -> raise (Image.Bad s)) fmt

let is_jpeg s = String.length s > 3 && s.[0] = '\xff' && s.[1] = '\xd8'

let zigzag = [|
  0; 1; 8; 16; 9; 2; 3; 10; 17; 24; 32; 25; 18; 11; 4; 5; 12; 19; 26; 33; 40; 48;
  41; 34; 27; 20; 13; 6; 7; 14; 21; 28; 35; 42; 49; 56; 57; 50; 43; 36; 29; 22;
  15; 23; 30; 37; 44; 51; 58; 59; 52; 45; 38; 31; 39; 46; 53; 60; 61; 54; 47; 55;
  62; 63 |]

(* a Huffman table: for each code length, the first code, its first
   value's index, how many *)
type huff = { maxcode : int array; valptr : int array; mincode : int array; values : int array }

let build_huff counts values =
  let maxcode = Array.make 18 (-1) and valptr = Array.make 17 0 and mincode = Array.make 17 0 in
  let code = ref 0 and k = ref 0 in
  for l = 1 to 16 do
    let n = counts.(l - 1) in
    valptr.(l) <- !k; mincode.(l) <- !code;
    code := !code + n; k := !k + n;
    maxcode.(l) <- (if n > 0 then !code - 1 else -1);
    code := !code lsl 1
  done;
  maxcode.(17) <- max_int;
  { maxcode; valptr; mincode; values }

type component = {
  cid : int;
  h : int;                         (* sampling factors *)
  v : int;
  tq : int;                        (* its quantization table *)
  mutable td : int;                (* its Huffman tables, DC and AC *)
  mutable ta : int;
  mutable pred : int;              (* the DC's predictor *)
  mutable pixels : Bytes.t;        (* its samples, as decoded *)
  mutable pw : int;                (* their width (in samples) *)
}

(* the inverse DCT of a block (64 coefficients, dequantized): samples
   0..255, separable, in floats *)
let cos_table = Array.init 64 (fun i ->
    let x = i / 8 and u = i mod 8 in
    let cu = if u = 0 then 1. /. sqrt 2. else 1. in
    cu *. cos (float ((2 * x + 1) * u) *. Float.pi /. 16.))

let idct (blk : float array) (out : Bytes.t) off stride =
  let tmp = Array.make 64 0. in
  for y = 0 to 7 do                       (* rows: over u *)
    for x = 0 to 7 do
      let s = ref 0. in
      for u = 0 to 7 do s := !s +. cos_table.(x * 8 + u) *. blk.(y * 8 + u) done;
      tmp.(y * 8 + x) <- !s /. 2.
    done
  done;
  for x = 0 to 7 do                       (* columns: over v *)
    for y = 0 to 7 do
      let s = ref 0. in
      for v = 0 to 7 do s := !s +. cos_table.(y * 8 + v) *. tmp.(v * 8 + x) done;
      let p = truncate (Float.round (!s /. 2. +. 128.)) in
      Bytes.unsafe_set out (off + y * stride + x) (Char.unsafe_chr (max 0 (min 255 p)))
    done
  done

let read s =
  if not (is_jpeg s) then bad "not a JPEG file";
  let n = String.length s in
  let byte i = if i < n then Char.code s.[i] else bad "the file is cut short" in
  let be16 i = (byte i lsl 8) lor byte (i + 1) in
  let qt = Array.make 4 (Array.make 64 1) in
  let dc = Array.make 4 None and ac = Array.make 4 None in
  let comps = ref [||] and width = ref 0 and height = ref 0 in
  let restart = ref 0 in
  let result = ref None in
  let pos = ref 2 in
  while !result = None do
    (* the next marker *)
    while byte !pos <> 0xFF do incr pos done;
    while byte !pos = 0xFF do incr pos done;
    let m = byte !pos in
    incr pos;
    let len = if m = 0xD8 || (m >= 0xD0 && m <= 0xD7) then 0 else be16 !pos in
    let seg = !pos + 2 in
    (match m with
     | 0xDB ->                                          (* quantization tables *)
       let p = ref seg in
       while !p < !pos + len do
         let pq = byte !p lsr 4 and tq = byte !p land 15 in
         incr p;
         let t = Array.make 64 0 in
         for k = 0 to 63 do
           if pq = 0 then (t.(zigzag.(k)) <- byte !p; incr p)
           else (t.(zigzag.(k)) <- be16 !p; p := !p + 2)
         done;
         qt.(tq land 3) <- t
       done
     | 0xC4 ->                                          (* Huffman tables *)
       let p = ref seg in
       while !p < !pos + len do
         let tc = byte !p lsr 4 and th = byte !p land 15 in
         let counts = Array.init 16 (fun i -> byte (!p + 1 + i)) in
         let total = Array.fold_left ( + ) 0 counts in
         let values = Array.init total (fun i -> byte (!p + 17 + i)) in
         p := !p + 17 + total;
         let h = Some (build_huff counts values) in
         if tc = 0 then dc.(th land 3) <- h else ac.(th land 3) <- h
       done
     | 0xDD -> restart := be16 seg
     | 0xC0 | 0xC1 ->                                   (* baseline, extended *)
       if byte seg <> 8 then bad "%d bits a sample" (byte seg);
       height := be16 (seg + 1); width := be16 (seg + 3);
       let nc = byte (seg + 5) in
       comps := Array.init nc (fun i ->
           let o = seg + 6 + 3 * i in
           { cid = byte o; h = byte (o + 1) lsr 4; v = byte (o + 1) land 15; tq = byte (o + 2);
             td = 0; ta = 0; pred = 0; pixels = Bytes.empty; pw = 0 })
     | 0xC2 | 0xC6 | 0xCA | 0xCE -> bad "a progressive JPEG"
     | 0xC3 | 0xC5 | 0xC7 | 0xC9 | 0xCB | 0xCD | 0xCF -> bad "a lossless or arithmetic JPEG"
     | 0xDA ->                                          (* the scan *)
       let cs = !comps in
       if cs = [||] then bad "a scan before the frame";
       let ns = byte seg in
       let scomps = Array.init ns (fun i ->
           let id = byte (seg + 1 + 2 * i) and t = byte (seg + 2 + 2 * i) in
           let c = match Array.find_opt (fun c -> c.cid = id) cs with
             | Some c -> c | None -> bad "a scan of an unknown component" in
           c.td <- t lsr 4; c.ta <- t land 15; c) in
       let hmax = Array.fold_left (fun a c -> max a c.h) 1 cs
       and vmax = Array.fold_left (fun a c -> max a c.v) 1 cs in
       let mcux = (!width + 8 * hmax - 1) / (8 * hmax)
       and mcuy = (!height + 8 * vmax - 1) / (8 * vmax) in
       Array.iter (fun c ->
           c.pw <- mcux * c.h * 8;
           c.pixels <- Bytes.make (c.pw * mcuy * c.v * 8) '\128') cs;
       (* the entropy-coded data, bit by bit *)
       let p = ref (seg + 1 + 2 * ns + 3) in
       let bits = ref 0 and nbits = ref 0 in
       (* at most 24 bits held: OCaml's ints are 31 bits in MyNOS *)
       let rec fill () =
         if !nbits <= 16 then begin
           let b =
             if !p >= n then 0
             else begin
               let b = byte !p in
               if b = 0xFF then begin
                 let next = if !p + 1 < n then byte (!p + 1) else 0 in
                 if next = 0 then (p := !p + 2; 0xFF)
                 else 0                                    (* a marker: zeros *)
               end else (incr p; b)
             end in
           bits := ((!bits lsl 8) lor b) land 0xFFFFFF; nbits := !nbits + 8;
           fill ()
         end in
       let get_bits k =
         if k = 0 then 0
         else begin
           fill ();
           let v = (!bits lsr (!nbits - k)) land ((1 lsl k) - 1) in
           nbits := !nbits - k; v
         end in
       let decode h =
         let h = match h with Some h -> h | None -> bad "a missing Huffman table" in
         let code = ref (get_bits 1) and l = ref 1 in
         while !l <= 16 && !code > h.maxcode.(!l) do
           code := (!code lsl 1) lor get_bits 1; incr l
         done;
         if !l > 16 then bad "a bad Huffman code";
         h.values.(h.valptr.(!l) + !code - h.mincode.(!l)) in
       let extend v t = if t = 0 then 0 else if v < 1 lsl (t - 1) then v - (1 lsl t) + 1 else v in
       let blk = Array.make 64 0. in
       let block c bx by =
         Array.fill blk 0 64 0.;
         let q = qt.(c.tq land 3) in
         let t = decode dc.(c.td land 3) in
         let diff = extend (get_bits t) t in
         c.pred <- c.pred + diff;
         blk.(0) <- float (c.pred * q.(0));
         let k = ref 1 in
         while !k < 64 do
           let rs = decode ac.(c.ta land 3) in
           let r = rs lsr 4 and sz = rs land 15 in
           if sz = 0 then begin
             if r = 15 then k := !k + 16 else k := 64
           end else begin
             k := !k + r;
             if !k < 64 then begin
               let z = zigzag.(!k) in
               blk.(z) <- float (extend (get_bits sz) sz * q.(z))
             end;
             incr k
           end
         done;
         idct blk c.pixels (by * 8 * c.pw + bx * 8) c.pw in
       let mcus = ref 0 in
       for my = 0 to mcuy - 1 do
         for mx = 0 to mcux - 1 do
           (* a restart marker: the bits and the predictors start again *)
           if !restart > 0 && !mcus > 0 && !mcus mod !restart = 0 then begin
             nbits := 0; bits := 0;
             while !p + 1 < n && not (byte !p = 0xFF && byte (!p + 1) >= 0xD0 && byte (!p + 1) <= 0xD7) do
               incr p done;
             p := !p + 2;
             Array.iter (fun c -> c.pred <- 0) cs
           end;
           incr mcus;
           if ns = 1 then begin
             (* a single component: its own blocks, not by MCU *)
             ()
           end;
           Array.iter (fun c ->
               for yy = 0 to c.v - 1 do
                 for xx = 0 to c.h - 1 do
                   block c (mx * c.h + xx) (my * c.v + yy)
                 done
               done) scomps
         done
       done;
       (* to RGB *)
       let w = !width and h = !height in
       let sample c x y =
         let sx = x * c.h / hmax and sy = y * c.v / vmax in
         Char.code (Bytes.unsafe_get c.pixels (sy * c.pw + sx)) in
       let pixels = Array.make (w * h) 0 in
       let clamp v = max 0 (min 255 v) in
       (match cs with
        | [| c |] ->
          for y = 0 to h - 1 do for x = 0 to w - 1 do
              let g = sample c x y in pixels.(y * w + x) <- (g lsl 16) lor (g lsl 8) lor g
            done done
        | [| cy; cb; cr |] ->
          for y = 0 to h - 1 do for x = 0 to w - 1 do
              let yv = float (sample cy x y) and u = float (sample cb x y - 128)
              and v = float (sample cr x y - 128) in
              let r = clamp (truncate (yv +. 1.402 *. v))
              and g = clamp (truncate (yv -. 0.344136 *. u -. 0.714136 *. v))
              and b = clamp (truncate (yv +. 1.772 *. u)) in
              pixels.(y * w + x) <- (r lsl 16) lor (g lsl 8) lor b
            done done
        | _ -> bad "%d components" (Array.length cs));
       result := Some { Image.width = w; height = h; pixels }
     | 0xD9 -> bad "no picture"
     | _ -> ());
    pos := !pos + len
  done;
  Option.get !result
