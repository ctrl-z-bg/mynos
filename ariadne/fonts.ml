(* The fonts text is measured and drawn in (M2): the Liberation families
   (third_party/liberation-fonts), chosen from CSS's font-family,
   font-weight and font-style; their files read once, from the system RAM
   disk in MyNOS or from third_party on the host (ARIADNE_FONTS overrides).

   Text is measured with the fonts' advances and kerning, at whole pixel
   sizes; each glyph is rasterized once per size (Ttf) and kept as a grey
   mask, which the window draws with Gfx.draw_mask. Without the font files,
   text is measured as Terminus (8 x 16), and the window draws it so.
   The caches are shared by the threads that lay pages out: a mutex keeps
   them whole. *)

type family = Sans | Serif | Mono

type font = {
  ttf : Ttf.t option;
  key : string;          (* "sans-bold 16": for the caches and the tests *)
  size : int;            (* pixels per em *)
  ascent : int;          (* pixels, above the baseline *)
  descent : int;         (* pixels, below it (positive) *)
  line : int;            (* the normal line height *)
}

let lock = Mutex.create ()
let locked f = Mutex.protect lock f

(* ---- the files ---- *)

let dirs () =
  (match Sys.getenv_opt "ARIADNE_FONTS" with Some d -> [ d ] | None -> [])
  @ [ "/"; "../third_party/liberation-fonts"; "third_party/liberation-fonts";
      "../../third_party/liberation-fonts" ]

let file_name family bold italic =
  let fam = match family with Sans -> "Sans" | Serif -> "Serif" | Mono -> "Mono" in
  let style = match bold, italic with
    | false, false -> "Regular" | true, false -> "Bold" | false, true -> "Italic" | true, true -> "BoldItalic" in
  Printf.sprintf "Liberation%s-%s.ttf" fam style

let faces : (string, Ttf.t option) Hashtbl.t = Hashtbl.create 16

let face name =
  match Hashtbl.find_opt faces name with
  | Some f -> f
  | None ->
    let f = List.find_map (fun d ->
        let path = Filename.concat d name in
        if Sys.file_exists path then
          (try Some (Ttf.load (In_channel.with_open_bin path In_channel.input_all))
           with _ -> None)
        else None) (dirs ()) in
    Hashtbl.replace faces name f;
    f

(* ---- font-family to a family ---- *)

let family_of_uncached css =
  let names = List.map (fun n ->
      let n = String.trim n in
      let n = if String.length n >= 2 && (n.[0] = '"' || n.[0] = '\'') then String.sub n 1 (String.length n - 2) else n in
      String.lowercase_ascii n) (String.split_on_char ',' css) in
  let contains s sub =
    let ls = String.length s and lsub = String.length sub in
    let rec go i = i + lsub <= ls && (String.sub s i lsub = sub || go (i + 1)) in
    go 0 in
  let classify n =
    if n = "monospace" || contains n "mono" || contains n "courier" || contains n "consol"
       || contains n "menlo" || contains n "monaco" || contains n "code" then Some Mono
    else if n = "sans-serif" || n = "system-ui" || n = "-apple-system" || n = "blinkmacsystemfont"
            || contains n "sans" || contains n "arial" || contains n "helvetica" || contains n "verdana"
            || contains n "tahoma" || contains n "segoe" || contains n "roboto" || contains n "inter"
            || contains n "lato" || contains n "ubuntu" || contains n "trebuchet" || contains n "geneva"
            || contains n "lucida" || contains n "cantarell" || contains n "noto" then Some Sans
    else if n = "serif" || contains n "times" || contains n "georgia" || contains n "serif"
            || contains n "garamond" || contains n "palatino" || contains n "libertine"
            || contains n "cambria" || contains n "book" || contains n "baskerville" then Some Serif
    else None in
  match List.find_map classify names with Some f -> f | None -> Serif

let families : (string, family) Hashtbl.t = Hashtbl.create 64

let family_of css =
  match locked (fun () -> Hashtbl.find_opt families css) with
  | Some f -> f
  | None -> let f = family_of_uncached css in locked (fun () -> Hashtbl.replace families css f); f

(* ---- fonts ---- *)

let fonts : (string, font) Hashtbl.t = Hashtbl.create 64

let get ~family ~bold ~italic ~size =
  let size = max 1 size in
  let fam = match family with Sans -> "sans" | Serif -> "serif" | Mono -> "mono" in
  let key = Printf.sprintf "%s%s%s %d" fam (if bold then "-bold" else "") (if italic then "-italic" else "") size in
  locked (fun () ->
      match Hashtbl.find_opt fonts key with
      | Some f -> f
      | None ->
        let ttf = face (file_name family bold italic) in
        let f = match ttf with
          | Some t ->
            let s v = float v *. float size /. float t.Ttf.upem in
            let ascent = int_of_float (Float.ceil (s t.ascent)) in
            let descent = int_of_float (Float.ceil (s (- t.descent))) in
            { ttf; key; size; ascent; descent;
              line = int_of_float (Float.round (s (t.ascent - t.descent + t.line_gap))) }
          | None -> { ttf = None; key; size; ascent = 12; descent = 4; line = 16 } in
        Hashtbl.replace fonts key f;
        f)

(* ---- code points ---- *)

let decode s f =
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let b = Char.code s.[!i] in
    let len, cp =
      if b < 0x80 then (1, b)
      else if b < 0xE0 && !i + 1 < n then (2, ((b land 0x1F) lsl 6) lor (Char.code s.[!i + 1] land 0x3F))
      else if b < 0xF0 && !i + 2 < n then
        (3, ((b land 0x0F) lsl 12) lor ((Char.code s.[!i + 1] land 0x3F) lsl 6) lor (Char.code s.[!i + 2] land 0x3F))
      else if !i + 3 < n then
        (4, ((b land 0x07) lsl 18) lor ((Char.code s.[!i + 1] land 0x3F) lsl 12)
            lor ((Char.code s.[!i + 2] land 0x3F) lsl 6) lor (Char.code s.[!i + 3] land 0x3F))
      else (1, 0xFFFD) in
    f !i len cp;
    i := !i + len
  done

(* ---- measuring ---- *)

(* the pen's positions: each code point's glyph and x offset (float px) *)
let glyph_run font s =
  match font.ttf with
  | None ->
    let out = ref [] and x = ref 0. in
    decode s (fun _ _ cp -> out := (cp, !x) :: !out; x := !x +. 8.);
    (List.rev !out, !x)
  | Some t ->
    let scale = float font.size /. float t.Ttf.upem in
    let out = ref [] and x = ref 0. and prev = ref (-1) in
    decode s (fun _ _ cp ->
        let g = Ttf.glyph_index t cp in
        if !prev >= 0 then x := !x +. float (Ttf.kern t !prev g) *. scale;
        out := (g, !x) :: !out;
        x := !x +. float (Ttf.advance t g) *. scale;
        prev := g);
    (List.rev !out, !x)

let widths : (string, int) Hashtbl.t = Hashtbl.create 4096

let width font s =
  if s = "" then 0
  else
    let k = font.key ^ "\000" ^ s in
    match locked (fun () -> Hashtbl.find_opt widths k) with
    | Some w -> w
    | None ->
      let _, w = glyph_run font s in
      let w = int_of_float (Float.round w) in
      locked (fun () -> if Hashtbl.length widths > 200_000 then Hashtbl.reset widths; Hashtbl.replace widths k w);
      w

(* the width of each code point's prefix: where a too long word may be cut *)
let prefix_widths font s =
  let out = ref [] in
  let acc = Buffer.create (String.length s) in
  decode s (fun i len _ ->
      Buffer.add_string acc (String.sub s i len);
      out := (Buffer.contents acc, width font (Buffer.contents acc)) :: !out);
  List.rev !out

(* ---- drawing ---- *)

let masks : (string * int, Ttf.bitmap) Hashtbl.t = Hashtbl.create 1024

(* each glyph's mask and where it goes: (x from the text's start, y from
   the baseline to the mask's top (negative: above), the bitmap) *)
let runs : (string, (int * int * Ttf.bitmap) list) Hashtbl.t = Hashtbl.create 4096

let rec glyphs font s =
  let k = font.key ^ "\000" ^ s in
  match locked (fun () -> Hashtbl.find_opt runs k) with
  | Some r -> r
  | None ->
    let r = glyphs_uncached font s in
    locked (fun () -> if Hashtbl.length runs > 50_000 then Hashtbl.reset runs; Hashtbl.replace runs k r);
    r

and glyphs_uncached font s =
  match font.ttf with
  | None -> []
  | Some t ->
    let run, _ = glyph_run font s in
    List.filter_map (fun (g, x) ->
        let k = (font.key, g) in
        let b = match locked (fun () -> Hashtbl.find_opt masks k) with
          | Some b -> b
          | None ->
            let b = Ttf.rasterize t g ~size:font.size in
            locked (fun () -> Hashtbl.replace masks k b);
            b in
        if b.Ttf.width = 0 then None
        else Some (int_of_float (Float.round x) + b.left, - b.top, b)) run

let available () = face (file_name Sans false false) <> None
