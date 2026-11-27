(* TrueType fonts: the tables a browser needs to measure and draw text
   (Apple's TrueType Reference Manual, OpenType's spec), in pure OCaml:
   head, hhea, maxp, hmtx, cmap (formats 4 and 12), loca, glyf (simple and
   composite glyphs), kern (format 0). No hinting: outlines are scaled and
   rasterized with antialiasing.

   The rasterizer accumulates signed area, as font-rs does: every edge of
   the outline adds, to the cells it crosses, how much of them it covers
   and how much it covers to their right; one running sum over the cells
   then gives each pixel's coverage. A glyph costs a pass over its edges
   and one over its pixels. Self-contained: no other module of Ariadne. *)

type t = {
  data : string;
  tables : (string, int * int) Hashtbl.t;    (* tag -> offset, length *)
  upem : int;
  ascent : int;                              (* font units *)
  descent : int;                             (* negative *)
  line_gap : int;
  glyphs : int;
  long_loca : bool;
  metrics : int;                             (* numberOfHMetrics *)
  cmap : int -> int;                         (* code point -> glyph *)
  kerning : (int, int) Hashtbl.t;            (* left lsl 16 lor right -> adjustment *)
}

exception Bad of string

let u8 d o = Char.code (String.unsafe_get d o)
let u16 d o = (u8 d o lsl 8) lor u8 d (o + 1)
let i16 d o = let v = u16 d o in if v >= 0x8000 then v - 0x10000 else v
let u32 d o = (u16 d o lsl 16) lor u16 d (o + 2)

let table t tag = match Hashtbl.find_opt t tag with Some x -> x | None -> raise (Bad ("no " ^ tag ^ " table"))

(* the best Unicode subtable: format 12 (all planes), else format 4 *)
let read_cmap d off =
  let n = u16 d (off + 2) in
  let subs = List.init n (fun i ->
      let r = off + 4 + 8 * i in
      (u16 d r, u16 d (r + 2), off + u32 d (r + 4))) in
  let fmt (_, _, o) = u16 d o in
  let unicode (p, e, _) = (p = 3 && (e = 1 || e = 10)) || p = 0 in
  let pick = match List.find_opt (fun s -> unicode s && fmt s = 12) subs with
    | Some s -> Some s
    | None -> List.find_opt (fun s -> unicode s && fmt s = 4) subs in
  match pick with
  | Some (_, _, o) when fmt (0, 0, o) = 12 ->
    let groups = u32 d (o + 12) in
    let g = Array.init groups (fun i ->
        let r = o + 16 + 12 * i in (u32 d r, u32 d (r + 4), u32 d (r + 8))) in
    (fun cp ->
       let rec bs lo hi =
         if lo > hi then 0
         else let mid = (lo + hi) / 2 in
           let s, e, gl = g.(mid) in
           if cp < s then bs lo (mid - 1) else if cp > e then bs (mid + 1) hi else gl + cp - s in
       bs 0 (groups - 1))
  | Some (_, _, o) ->
    let segs = u16 d (o + 6) / 2 in
    let ends = o + 14 in
    let starts = ends + 2 * segs + 2 in
    let deltas = starts + 2 * segs in
    let ranges = deltas + 2 * segs in
    (fun cp ->
       if cp > 0xFFFF then 0
       else
         let rec bs lo hi =
           if lo > hi then 0
           else let mid = (lo + hi) / 2 in
             if u16 d (ends + 2 * mid) < cp then bs (mid + 1) hi
             else if mid > 0 && u16 d (ends + 2 * (mid - 1)) >= cp then bs lo (mid - 1)
             else begin
               let start = u16 d (starts + 2 * mid) in
               if cp < start then 0
               else
                 let ro = u16 d (ranges + 2 * mid) in
                 if ro = 0 then (cp + u16 d (deltas + 2 * mid)) land 0xFFFF
                 else
                   let a = ranges + 2 * mid + ro + 2 * (cp - start) in
                   let g = u16 d a in
                   if g = 0 then 0 else (g + u16 d (deltas + 2 * mid)) land 0xFFFF
             end in
         bs 0 (segs - 1))
  | None -> (fun _ -> 0)

let read_kern d tables =
  let k = Hashtbl.create 1024 in
  (match Hashtbl.find_opt tables "kern" with
   | Some (off, _) when u16 d off = 0 ->
     let n = u16 d (off + 2) in
     let o = ref (off + 4) in
     for _ = 1 to n do
       let len = u16 d (!o + 2) and coverage = u16 d (!o + 4) in
       (* format 0, horizontal, not cross-stream *)
       if coverage lsr 8 = 0 && coverage land 1 = 1 && coverage land 4 = 0 then begin
         let pairs = u16 d (!o + 6) in
         for i = 0 to pairs - 1 do
           let r = !o + 14 + 6 * i in
           Hashtbl.replace k ((u16 d r lsl 16) lor u16 d (r + 2)) (i16 d (r + 4))
         done
       end;
       o := !o + len
     done
   | _ -> ());
  k

let load data =
  let d = data in
  if String.length d < 12 then raise (Bad "too short");
  let n = u16 d 4 in
  let tables = Hashtbl.create 32 in
  for i = 0 to n - 1 do
    let r = 12 + 16 * i in
    Hashtbl.replace tables (String.sub d r 4) (u32 d (r + 8), u32 d (r + 12))
  done;
  let head, _ = table tables "head" and hhea, _ = table tables "hhea" and maxp, _ = table tables "maxp" in
  let cmap, _ = table tables "cmap" in
  { data = d; tables; upem = u16 d (head + 18); long_loca = i16 d (head + 50) = 1;
    ascent = i16 d (hhea + 4); descent = i16 d (hhea + 6); line_gap = i16 d (hhea + 8);
    metrics = u16 d (hhea + 34); glyphs = u16 d (maxp + 4);
    cmap = read_cmap d cmap; kerning = read_kern d tables }

let glyph_index t cp = t.cmap cp

let advance t g =
  let hmtx, _ = table t.tables "hmtx" in
  let i = if g < t.metrics then g else t.metrics - 1 in
  u16 t.data (hmtx + 4 * i)

let kern t a b = Option.value (Hashtbl.find_opt t.kerning ((a lsl 16) lor b)) ~default:0

(* ---- outlines ---- *)

(* a glyph's data: offset and length in glyf *)
let glyph_range t g =
  if g < 0 || g >= t.glyphs then None
  else
    let loca, _ = table t.tables "loca" and glyf, _ = table t.tables "glyf" in
    let at i = if t.long_loca then u32 t.data (loca + 4 * i) else 2 * u16 t.data (loca + 2 * i) in
    let a = at g and b = at (g + 1) in
    if b <= a then None else Some (glyf + a, b - a)

(* contours: arrays of points (x, y, on-curve), in font units *)
let rec contours ?(depth = 0) t g : (float * float * bool) array list =
  match glyph_range t g with
  | None -> []
  | Some (o, _) ->
    let d = t.data in
    let n = i16 d o in
    if n >= 0 then begin
      (* a simple glyph *)
      let ends = Array.init n (fun i -> u16 d (o + 10 + 2 * i)) in
      let npts = if n = 0 then 0 else ends.(n - 1) + 1 in
      let ilen = u16 d (o + 10 + 2 * n) in
      let p = ref (o + 12 + 2 * n + ilen) in
      let flags = Array.make npts 0 in
      let i = ref 0 in
      while !i < npts do
        let f = u8 d !p in
        incr p;
        flags.(!i) <- f; incr i;
        if f land 8 <> 0 then begin
          let r = u8 d !p in
          incr p;
          for _ = 1 to r do if !i < npts then (flags.(!i) <- f; incr i) done
        end
      done;
      let coords short same =
        let v = Array.make npts 0 and cur = ref 0 in
        for i = 0 to npts - 1 do
          let f = flags.(i) in
          if f land short <> 0 then begin
            let dv = u8 d !p in incr p;
            cur := !cur + (if f land same <> 0 then dv else - dv)
          end else if f land same = 0 then begin
            cur := !cur + i16 d !p; p := !p + 2
          end;
          v.(i) <- !cur
        done;
        v in
      let xs = coords 2 16 in
      let ys = coords 4 32 in
      let start = ref 0 in
      Array.to_list (Array.map (fun e ->
          let c = Array.init (e - !start + 1) (fun k ->
              let j = !start + k in (float xs.(j), float ys.(j), flags.(j) land 1 <> 0)) in
          start := e + 1;
          c) ends)
    end else if depth < 8 then begin
      (* a composite glyph: its components, moved and scaled *)
      let out = ref [] in
      let p = ref (o + 10) in
      let more = ref true in
      while !more do
        let flags = u16 d !p and gi = u16 d (!p + 2) in
        p := !p + 4;
        let dx, dy =
          if flags land 1 <> 0 then (let a = i16 d !p and b = i16 d (!p + 2) in p := !p + 4; (a, b))
          else (let a = u8 d !p and b = u8 d (!p + 1) in p := !p + 2;
                ((if a >= 128 then a - 256 else a), (if b >= 128 then b - 256 else b))) in
        let f2 o = float (i16 d o) /. 16384. in
        let a, b, c, dd =
          if flags land 8 <> 0 then (let s = f2 !p in p := !p + 2; (s, 0., 0., s))
          else if flags land 0x40 <> 0 then (let sx = f2 !p and sy = f2 (!p + 2) in p := !p + 4; (sx, 0., 0., sy))
          else if flags land 0x80 <> 0 then
            (let a = f2 !p and b = f2 (!p + 2) and c = f2 (!p + 4) and dd = f2 (!p + 6) in p := !p + 8; (a, b, c, dd))
          else (1., 0., 0., 1.) in
        let dx, dy = if flags land 2 <> 0 then (float dx, float dy) else (0., 0.) in
        List.iter (fun ctr ->
            out := Array.map (fun (x, y, on) -> (a *. x +. c *. y +. dx, b *. x +. dd *. y +. dy, on)) ctr :: !out)
          (contours ~depth:(depth + 1) t gi);
        more := flags land 0x20 <> 0
      done;
      List.rev !out
    end else []

(* ---- the rasterizer ---- *)

type bitmap = {
  left : int;       (* from the pen to the bitmap's left, in pixels *)
  top : int;        (* from the baseline up to its top (positive: above) *)
  width : int;
  height : int;
  grey : string;    (* width x height, 0: full ink, 255: none (Gfx.draw_mask's) *)
}

let empty = { left = 0; top = 0; width = 0; height = 0; grey = "" }

(* a contour's points, the implied on-curve ones added: lines and
   quadratic curves, as a list of segments in pixel space *)
let segments ~scale ~ox ~oy (ctr : (float * float * bool) array) emit =
  let n = Array.length ctr in
  if n >= 2 then begin
    let pt i = let x, y, on = ctr.(i mod n) in (x *. scale -. ox, oy -. y *. scale, on) in
    (* start at an on-curve point, or the middle of the first two off ones *)
    let first =
      match List.find_opt (fun i -> let _, _, on = ctr.(i) in on) (List.init n Fun.id) with
      | Some i -> i
      | None -> -1 in
    let start_pt, start_i =
      if first >= 0 then (let x, y, _ = pt first in (x, y), first)
      else (let x0, y0, _ = pt 0 and x1, y1, _ = pt 1 in (((x0 +. x1) /. 2., (y0 +. y1) /. 2.), 0)) in
    let cur = ref start_pt and ctrl = ref None in
    let quad (x0, y0) (cx, cy) (x1, y1) =
      let dd = Float.abs (x0 -. 2. *. cx +. x1) +. Float.abs (y0 -. 2. *. cy +. y1) in
      let k = max 1 (min 16 (int_of_float (Float.ceil (Float.sqrt (dd *. 1.5))))) in
      let prev = ref (x0, y0) in
      for i = 1 to k do
        let t = float i /. float k in
        let u = 1. -. t in
        let p = (u *. u *. x0 +. 2. *. u *. t *. cx +. t *. t *. x1, u *. u *. y0 +. 2. *. u *. t *. cy +. t *. t *. y1) in
        emit !prev p; prev := p
      done in
    for k = 1 to n do
      let x, y, on = pt (start_i + k) in
      match on, !ctrl with
      | true, None -> emit !cur (x, y); cur := (x, y)
      | true, Some c -> quad !cur c (x, y); cur := (x, y); ctrl := None
      | false, None -> ctrl := Some (x, y)
      | false, Some (cx, cy) ->
        let mid = ((cx +. x) /. 2., (cy +. y) /. 2.) in
        quad !cur (cx, cy) mid; cur := mid; ctrl := Some (x, y)
    done;
    (match !ctrl with
     | Some c -> quad !cur c start_pt
     | None -> if !cur <> start_pt then emit !cur start_pt)
  end

let rasterize t g ~size =
  let ctrs = contours t g in
  if ctrs = [] then empty
  else begin
    let scale = float size /. float t.upem in
    let xmin = ref infinity and xmax = ref neg_infinity and ymin = ref infinity and ymax = ref neg_infinity in
    List.iter (Array.iter (fun (x, y, _) ->
        xmin := Float.min !xmin x; xmax := Float.max !xmax x;
        ymin := Float.min !ymin y; ymax := Float.max !ymax y)) ctrs;
    let left = int_of_float (Float.floor (!xmin *. scale)) and right = int_of_float (Float.ceil (!xmax *. scale)) in
    let top = int_of_float (Float.ceil (!ymax *. scale)) and bottom = int_of_float (Float.floor (!ymin *. scale)) in
    let w = max 1 (right - left) and h = max 1 (top - bottom) in
    let stride = w + 2 in
    let acc = Array.make (stride * h + 2) 0. in
    let line (x0, y0) (x1, y1) =
      if y0 <> y1 then begin
        let dir, x0, y0, x1, y1 = if y0 < y1 then (1., x0, y0, x1, y1) else (-1., x1, y1, x0, y0) in
        let dxdy = (x1 -. x0) /. (y1 -. y0) in
        let x = ref (if y0 < 0. then x0 -. y0 *. dxdy else x0) in
        let ystart = max 0 (int_of_float (Float.floor y0)) in
        let yend = min h (int_of_float (Float.ceil y1)) in
        for yi = ystart to yend - 1 do
          let fy = float yi in
          let dy = Float.min (fy +. 1.) y1 -. Float.max fy y0 in
          let xnext = !x +. dxdy *. dy in
          let d = dy *. dir in
          let xa, xb = if !x < xnext then (!x, xnext) else (xnext, !x) in
          let xa = Float.max 0. (Float.min (float w) xa) and xb = Float.max 0. (Float.min (float w) xb) in
          let base = yi * stride in
          let x0f = Float.floor xa in
          let x0i = int_of_float x0f in
          let x1c = Float.ceil xb in
          let x1i = int_of_float x1c in
          if x1i <= x0i + 1 then begin
            let xmf = 0.5 *. (xa +. xb) -. x0f in
            acc.(base + x0i) <- acc.(base + x0i) +. d -. d *. xmf;
            acc.(base + x0i + 1) <- acc.(base + x0i + 1) +. d *. xmf
          end else begin
            let s = 1. /. (xb -. xa) in
            let x0fr = xa -. x0f in
            let a0 = 0.5 *. s *. (1. -. x0fr) *. (1. -. x0fr) in
            let x1fr = xb -. x1c +. 1. in
            let am = 0.5 *. s *. x1fr *. x1fr in
            acc.(base + x0i) <- acc.(base + x0i) +. d *. a0;
            if x1i = x0i + 2 then
              acc.(base + x0i + 1) <- acc.(base + x0i + 1) +. d *. (1. -. a0 -. am)
            else begin
              let a1 = s *. (1.5 -. x0fr) in
              acc.(base + x0i + 1) <- acc.(base + x0i + 1) +. d *. (a1 -. a0);
              for xi = x0i + 2 to x1i - 2 do acc.(base + xi) <- acc.(base + xi) +. d *. s done;
              let a2 = a1 +. float (x1i - x0i - 3) *. s in
              acc.(base + x1i - 1) <- acc.(base + x1i - 1) +. d *. (1. -. a2 -. am)
            end;
            acc.(base + x1i) <- acc.(base + x1i) +. d *. am
          end;
          x := xnext
        done
      end in
    List.iter (fun c -> segments ~scale ~ox:(float left) ~oy:(float top) c line) ctrs;
    let grey = Bytes.make (w * h) '\255' in
    let sum = ref 0. in
    for yi = 0 to h - 1 do
      for xi = 0 to stride - 1 do
        sum := !sum +. acc.(yi * stride + xi);
        if xi < w then begin
          let a = Float.min 1. (Float.abs !sum) in
          Bytes.unsafe_set grey (yi * w + xi) (Char.unsafe_chr (255 - int_of_float (a *. 255. +. 0.5)))
        end
      done
    done;
    { left; top; width = w; height = h; grey = Bytes.unsafe_to_string grey }
  end
