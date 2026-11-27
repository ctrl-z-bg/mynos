(* The cascade and computed values (CSS Cascade 4, CSS Values 4, the HTML
   Standard's rendering section for the browser's own style sheet).

   Style sheets are flattened to rules with the media conditions they sit
   in, so a new window width only re-evaluates the conditions. Rules are
   indexed by their rightmost compound's id, class or tag (Selector.key):
   an element is matched only against the rules that could apply to it.
   Lengths are resolved to pixels here, except percentages, which layout
   resolves against the containing block. *)

open Css

(* ---- computed values ---- *)

type length = Auto | Len of float * float          (* px + percent of the reference *)

type display =
  | None_ | Contents | Block | Inline | Inline_block | List_item
  | Table | Table_row | Table_cell | Table_group | Table_caption | Table_column
  | Flex | Inline_flex | Grid | Inline_grid

type position = Static | Relative | Absolute | Fixed | Sticky
type align = Left | Right | Center | Justify
type white_space = Normal | Pre | Nowrap | Pre_wrap | Pre_line
type transform = No_transform | Upper | Lower | Capitalize
type line_height = Lh_normal | Lh_px of float | Lh_factor of float

(* a picture painted in a box: background-image's, or mask-image's (its
   alpha, in the background's colour) *)
type layer_size = Size_auto | Cover | Contain | Size of length * length   (* Auto: from the ratio *)
type layer = {
  mutable image : string option;    (* its URL (resolved against its sheet's, if it had one) *)
  mutable rep_x : bool;
  mutable rep_y : bool;
  mutable pos_x : length;           (* a percentage: of the box less the picture *)
  mutable pos_y : length;
  mutable size : layer_size;
}

let new_layer () = { image = None; rep_x = true; rep_y = true; pos_x = Len (0., 0.); pos_y = Len (0., 0.);
                     size = Size_auto }
let copy_layer l = { l with image = l.image }

type t = {
  mutable display : display;
  mutable position : position;
  mutable float_ : string;
  mutable color : int;                (* 0xRRGGBB *)
  mutable background : int;           (* 0xAARRGGBB; alpha 0: transparent *)
  mutable font_size : float;
  mutable font_weight : int;
  mutable italic : bool;
  mutable font_family : string;
  mutable line_height : line_height;
  mutable text_align : align;
  mutable text_indent : length;
  mutable white_space : white_space;
  mutable underline : bool;
  mutable line_through : bool;
  mutable overline : bool;
  mutable transform : transform;
  mutable margin : length array;      (* top right bottom left *)
  mutable padding : length array;
  mutable border_width : float array;
  mutable border_style : bool array;  (* a visible style (not none or hidden) *)
  mutable border_color : int array;   (* -1: currentcolor *)
  mutable width : length;
  mutable height : length;
  mutable min_width : length;
  mutable max_width : length;         (* Auto: none *)
  mutable min_height : length;
  mutable max_height : length;
  mutable border_box : bool;
  mutable visible : bool;
  mutable list_style : string;
  mutable custom : (string * cv list) list;
  (* M5: floats, positioning, overflow *)
  mutable clear : string;
  mutable inset : length array;       (* top right bottom left; Auto when not given *)
  mutable overflow_clip : bool;       (* hidden or clip: the content is clipped *)
  mutable overflow_bfc : bool;        (* anything but visible: a new formatting context *)
  mutable clipped : bool;             (* clip: rect(...), clip-path: inset(50%): not shown *)
  mutable vertical_align : string;
  (* flexbox *)
  mutable flex_direction : string;
  mutable flex_wrap : bool;
  mutable justify : string;           (* justify-content *)
  mutable align_items : string;
  mutable align_self : string;
  mutable flex_grow : float;
  mutable flex_shrink : float;
  mutable flex_basis : length;        (* Auto: from width, else the content *)
  mutable order : int;
  mutable row_gap : length;
  mutable column_gap : length;
  (* grid *)
  mutable grid_columns : cv list;
  mutable grid_rows : cv list;
  mutable grid_areas : string list list;
  mutable grid_area : cv list;
  mutable grid_column : cv list;
  mutable grid_row : cv list;
  (* tables *)
  mutable border_spacing : float;
  mutable border_collapse : bool;
  mutable masked : bool;              (* a mask-image: the background is painted through it (mask) *)
  mutable bg : layer;                 (* background-image and the rest *)
  mutable shift : (length * length) option;  (* transform's translations (a percentage: of the box) *)
  mutable mask : layer;               (* mask-image and the rest *)
  mutable transparent : bool;         (* opacity: 0 here or on an ancestor: nothing painted *)
  mutable content : cv list option;   (* a ::before's or ::after's content *)
  mutable caption_bottom : bool;      (* caption-side: bottom *)
}

let initial () = {
  display = Inline; position = Static; float_ = "none"; color = 0x000000; background = 0;
  font_size = 16.; font_weight = 400; italic = false; font_family = "serif";
  line_height = Lh_normal; text_align = Left; text_indent = Len (0., 0.); white_space = Normal;
  underline = false; line_through = false; overline = false; transform = No_transform;
  margin = Array.make 4 (Len (0., 0.)); padding = Array.make 4 (Len (0., 0.));
  border_width = Array.make 4 3.; border_style = Array.make 4 false; border_color = Array.make 4 (-1);
  width = Auto; height = Auto; min_width = Len (0., 0.); max_width = Auto;
  min_height = Len (0., 0.); max_height = Auto; border_box = false; visible = true;
  list_style = "disc"; custom = [];
  clear = "none"; inset = Array.make 4 Auto; overflow_clip = false; overflow_bfc = false;
  clipped = false; vertical_align = "baseline";
  flex_direction = "row"; flex_wrap = false; justify = "normal"; align_items = "normal";
  align_self = "auto"; flex_grow = 0.; flex_shrink = 1.; flex_basis = Auto; order = 0;
  row_gap = Len (0., 0.); column_gap = Len (0., 0.);
  grid_columns = []; grid_rows = []; grid_areas = []; grid_area = []; grid_column = []; grid_row = [];
  border_spacing = 0.; border_collapse = false; masked = false; transparent = false;
  content = None; caption_bottom = false; bg = new_layer (); mask = new_layer (); shift = None }

(* a child's start: the inherited properties from its parent, the others initial *)
let inherit_from p =
  let s = initial () in
  s.color <- p.color; s.font_size <- p.font_size; s.font_weight <- p.font_weight;
  s.italic <- p.italic; s.font_family <- p.font_family; s.line_height <- p.line_height;
  s.text_align <- p.text_align; s.text_indent <- p.text_indent; s.white_space <- p.white_space;
  s.transform <- p.transform; s.visible <- p.visible; s.list_style <- p.list_style;
  s.custom <- p.custom;
  s.border_spacing <- p.border_spacing;
  s.border_collapse <- p.border_collapse;
  s.transparent <- p.transparent;
  s.caption_bottom <- p.caption_bottom;
  (* text decorations are drawn through descendants: inherited here *)
  s.underline <- p.underline; s.line_through <- p.line_through; s.overline <- p.overline;
  s

let copy s = { s with margin = Array.copy s.margin; padding = Array.copy s.padding;
                      border_width = Array.copy s.border_width; border_style = Array.copy s.border_style;
                      border_color = Array.copy s.border_color }

(* the border's used width: 0 without a visible style *)
let border s i = if s.border_style.(i) then s.border_width.(i) else 0.

(* ---- the context values are resolved in ---- *)

type ctx = {
  vw : float; vh : float;           (* the viewport *)
  root_fs : float;                  (* the root element's font size, for rem *)
  fs : float;                       (* the element's font size, for em *)
  parent_fs : float;
}

(* ---- colours ---- *)

let named_colors = [
  "aliceblue", 0xF0F8FF; "antiquewhite", 0xFAEBD7; "aqua", 0x00FFFF; "aquamarine", 0x7FFFD4;
  "azure", 0xF0FFFF; "beige", 0xF5F5DC; "bisque", 0xFFE4C4; "black", 0x000000;
  "blanchedalmond", 0xFFEBCD; "blue", 0x0000FF; "blueviolet", 0x8A2BE2; "brown", 0xA52A2A;
  "burlywood", 0xDEB887; "cadetblue", 0x5F9EA0; "chartreuse", 0x7FFF00; "chocolate", 0xD2691E;
  "coral", 0xFF7F50; "cornflowerblue", 0x6495ED; "cornsilk", 0xFFF8DC; "crimson", 0xDC143C;
  "cyan", 0x00FFFF; "darkblue", 0x00008B; "darkcyan", 0x008B8B; "darkgoldenrod", 0xB8860B;
  "darkgray", 0xA9A9A9; "darkgreen", 0x006400; "darkgrey", 0xA9A9A9; "darkkhaki", 0xBDB76B;
  "darkmagenta", 0x8B008B; "darkolivegreen", 0x556B2F; "darkorange", 0xFF8C00;
  "darkorchid", 0x9932CC; "darkred", 0x8B0000; "darksalmon", 0xE9967A; "darkseagreen", 0x8FBC8F;
  "darkslateblue", 0x483D8B; "darkslategray", 0x2F4F4F; "darkslategrey", 0x2F4F4F;
  "darkturquoise", 0x00CED1; "darkviolet", 0x9400D3; "deeppink", 0xFF1493; "deepskyblue", 0x00BFFF;
  "dimgray", 0x696969; "dimgrey", 0x696969; "dodgerblue", 0x1E90FF; "firebrick", 0xB22222;
  "floralwhite", 0xFFFAF0; "forestgreen", 0x228B22; "fuchsia", 0xFF00FF; "gainsboro", 0xDCDCDC;
  "ghostwhite", 0xF8F8FF; "gold", 0xFFD700; "goldenrod", 0xDAA520; "gray", 0x808080;
  "green", 0x008000; "greenyellow", 0xADFF2F; "grey", 0x808080; "honeydew", 0xF0FFF0;
  "hotpink", 0xFF69B4; "indianred", 0xCD5C5C; "indigo", 0x4B0082; "ivory", 0xFFFFF0;
  "khaki", 0xF0E68C; "lavender", 0xE6E6FA; "lavenderblush", 0xFFF0F5; "lawngreen", 0x7CFC00;
  "lemonchiffon", 0xFFFACD; "lightblue", 0xADD8E6; "lightcoral", 0xF08080; "lightcyan", 0xE0FFFF;
  "lightgoldenrodyellow", 0xFAFAD2; "lightgray", 0xD3D3D3; "lightgreen", 0x90EE90;
  "lightgrey", 0xD3D3D3; "lightpink", 0xFFB6C1; "lightsalmon", 0xFFA07A; "lightseagreen", 0x20B2AA;
  "lightskyblue", 0x87CEFA; "lightslategray", 0x778899; "lightslategrey", 0x778899;
  "lightsteelblue", 0xB0C4DE; "lightyellow", 0xFFFFE0; "lime", 0x00FF00; "limegreen", 0x32CD32;
  "linen", 0xFAF0E6; "magenta", 0xFF00FF; "maroon", 0x800000; "mediumaquamarine", 0x66CDAA;
  "mediumblue", 0x0000CD; "mediumorchid", 0xBA55D3; "mediumpurple", 0x9370DB;
  "mediumseagreen", 0x3CB371; "mediumslateblue", 0x7B68EE; "mediumspringgreen", 0x00FA9A;
  "mediumturquoise", 0x48D1CC; "mediumvioletred", 0xC71585; "midnightblue", 0x191970;
  "mintcream", 0xF5FFFA; "mistyrose", 0xFFE4E1; "moccasin", 0xFFE4B5; "navajowhite", 0xFFDEAD;
  "navy", 0x000080; "oldlace", 0xFDF5E6; "olive", 0x808000; "olivedrab", 0x6B8E23;
  "orange", 0xFFA500; "orangered", 0xFF4500; "orchid", 0xDA70D6; "palegoldenrod", 0xEEE8AA;
  "palegreen", 0x98FB98; "paleturquoise", 0xAFEEEE; "palevioletred", 0xDB7093;
  "papayawhip", 0xFFEFD5; "peachpuff", 0xFFDAB9; "peru", 0xCD853F; "pink", 0xFFC0CB;
  "plum", 0xDDA0DD; "powderblue", 0xB0E0E6; "purple", 0x800080; "rebeccapurple", 0x663399;
  "red", 0xFF0000; "rosybrown", 0xBC8F8F; "royalblue", 0x4169E1; "saddlebrown", 0x8B4513;
  "salmon", 0xFA8072; "sandybrown", 0xF4A460; "seagreen", 0x2E8B57; "seashell", 0xFFF5EE;
  "sienna", 0xA0522D; "silver", 0xC0C0C0; "skyblue", 0x87CEEB; "slateblue", 0x6A5ACD;
  "slategray", 0x708090; "slategrey", 0x708090; "snow", 0xFFFAFA; "springgreen", 0x00FF7F;
  "steelblue", 0x4682B4; "tan", 0xD2B48C; "teal", 0x008080; "thistle", 0xD8BFD8;
  "tomato", 0xFF6347; "turquoise", 0x40E0D0; "violet", 0xEE82EE; "wheat", 0xF5DEB3;
  "white", 0xFFFFFF; "whitesmoke", 0xF5F5F5; "yellow", 0xFFFF00; "yellowgreen", 0x9ACD32;
  (* system colours, as a light theme draws them *)
  "canvas", 0xFFFFFF; "canvastext", 0x000000; "linktext", 0x0000EE; "visitedtext", 0x551A8B;
  "activetext", 0xFF0000; "buttonface", 0xEFEFEF; "buttontext", 0x000000;
  "buttonborder", 0x767676; "field", 0xFFFFFF; "fieldtext", 0x000000; "graytext", 0x808080;
  "highlight", 0x3399FF; "highlighttext", 0xFFFFFF; "mark", 0xFFFF00; "marktext", 0x000000 ]

let opaque rgb = 0xFF000000 lor rgb
let clamp lo hi v = if v < lo then lo else if v > hi then hi else v

(* the numbers of rgb() and hsl(), with commas or not, and "/ alpha" *)
let numbers args =
  List.filter_map (function
      | Tok (Number (v, _)) -> Some (`N v) | Tok (Percentage v) -> Some (`P v)
      | Tok (Dimension (v, "deg")) -> Some (`N v)
      | Tok (Dimension (v, "turn")) -> Some (`N (v *. 360.))
      | Tok (Ident "none") -> Some (`N 0.)
      | _ -> None) args

let hsl_to_rgb h s l =
  let h = Float.rem (Float.rem h 360. +. 360.) 360. /. 360. and s = s /. 100. and l = l /. 100. in
  let q = if l < 0.5 then l *. (1. +. s) else l +. s -. l *. s in
  let p = 2. *. l -. q in
  let hue t = let t = if t < 0. then t +. 1. else if t > 1. then t -. 1. else t in
    if t < 1. /. 6. then p +. (q -. p) *. 6. *. t
    else if t < 0.5 then q
    else if t < 2. /. 3. then p +. (q -. p) *. (2. /. 3. -. t) *. 6.
    else p in
  let c v = clamp 0 255 (int_of_float (Float.round (v *. 255.))) in
  (c (hue (h +. 1. /. 3.)) lsl 16) lor (c (hue h) lsl 8) lor c (hue (h -. 1. /. 3.))

(* a colour, as 0xAARRGGBB; [current] for currentcolor *)
let rec color ~current (v : cv list) : int option =
  match List.filter (fun c -> c <> Tok Whitespace) v with
  | [ Tok (Ident name) ] ->
    (match String.lowercase_ascii name with
     | "transparent" -> Some 0
     | "currentcolor" -> Some (opaque current)
     | n -> Option.map opaque (List.assoc_opt n named_colors))
  | [ Tok (Hash (h, _)) ] ->
    let hex s = int_of_string_opt ("0x" ^ s) in
    let d i = String.make 2 h.[i] in
    (match String.length h with
     | 3 -> Option.map opaque (hex (d 0 ^ d 1 ^ d 2))
     | 4 -> (match hex (d 0 ^ d 1 ^ d 2), hex (d 3) with
         | Some rgb, Some a -> Some ((a lsl 24) lor rgb) | _ -> None)
     | 6 -> Option.map opaque (hex h)
     | 8 -> (match hex (String.sub h 0 6), hex (String.sub h 6 2) with
         | Some rgb, Some a -> Some ((a lsl 24) lor rgb) | _ -> None)
     | _ -> None)
  | [ Func (("rgb" | "rgba"), args) ] ->
    let ch = function `N v -> clamp 0 255 (int_of_float (Float.round v))
                    | `P p -> clamp 0 255 (int_of_float (Float.round (p *. 2.55))) in
    let alpha = function `N a -> clamp 0 255 (int_of_float (Float.round (a *. 255.)))
                       | `P p -> clamp 0 255 (int_of_float (Float.round (p *. 2.55))) in
    (match numbers args with
     | [ r; g; b ] -> Some (opaque ((ch r lsl 16) lor (ch g lsl 8) lor ch b))
     | [ r; g; b; a ] -> Some ((alpha a lsl 24) lor (ch r lsl 16) lor (ch g lsl 8) lor ch b)
     | _ -> None)
  | [ Func (("hsl" | "hsla"), args) ] ->
    let v = function `N v | `P v -> v in
    (match numbers args with
     | [ h; s; l ] -> Some (opaque (hsl_to_rgb (v h) (v s) (v l)))
     | [ h; s; l; a ] ->
       let a = match a with `N a -> a | `P p -> p /. 100. in
       Some ((clamp 0 255 (int_of_float (a *. 255.)) lsl 24) lor hsl_to_rgb (v h) (v s) (v l))
     | _ -> None)
  | [ Func ("light-dark", args) ] ->
    (* a light theme: the first *)
    let rec first acc = function
      | Tok Comma :: _ -> List.rev acc | c :: r -> first (c :: acc) r | [] -> List.rev acc in
    color ~current (first [] args)
  | _ -> None

(* ---- lengths, with calc() ---- *)

(* a linear form: px + pct% ; or a plain number *)
type num = Px of float * float | Num of float

let rec length_value ctx (v : cv) : num option =
  match v with
  | Tok (Dimension (x, unit)) ->
    let px = match unit with
      | "px" -> Some x | "em" -> Some (x *. ctx.fs) | "rem" -> Some (x *. ctx.root_fs)
      | "ex" | "ch" | "ic" | "cap" -> Some (x *. ctx.fs *. 0.5) | "lh" -> Some (x *. ctx.fs *. 1.2)
      | "rlh" -> Some (x *. ctx.root_fs *. 1.2)
      | "vw" | "svw" | "lvw" | "dvw" -> Some (x *. ctx.vw /. 100.)
      | "vh" | "svh" | "lvh" | "dvh" -> Some (x *. ctx.vh /. 100.)
      | "vmin" -> Some (x *. Float.min ctx.vw ctx.vh /. 100.)
      | "vmax" -> Some (x *. Float.max ctx.vw ctx.vh /. 100.)
      | "pt" -> Some (x *. 4. /. 3.) | "pc" -> Some (x *. 16.) | "in" -> Some (x *. 96.)
      | "cm" -> Some (x *. 96. /. 2.54) | "mm" -> Some (x *. 96. /. 25.4) | "q" -> Some (x *. 96. /. 101.6)
      | _ -> None in
    Option.map (fun p -> Px (p, 0.)) px
  | Tok (Percentage p) -> Some (Px (0., p))
  | Tok (Number (x, _)) -> Some (Num x)
  | Func ("calc", args) -> calc ctx args
  | Css.Block ('(', args) -> calc ctx args
  | Func (("min" | "max" as f), args) ->
    let parts = split_commas args in
    let vals = List.filter_map (calc ctx) parts in
    if List.length vals <> List.length parts || vals = [] then None
    else if List.for_all (function Px (_, 0.) -> true | Num _ -> true | _ -> false) vals then
      let v = List.map (function Px (p, _) -> p | Num n -> n) vals in
      let pick = if f = "min" then List.fold_left Float.min Float.infinity v
        else List.fold_left Float.max Float.neg_infinity v in
      Some (Px (pick, 0.))
    else Some (List.hd vals)
  | Func ("clamp", args) ->
    (match List.map (calc ctx) (split_commas args) with
     | [ Some (Px (lo, 0.)); Some (Px (v, 0.)); Some (Px (hi, 0.)) ] -> Some (Px (Float.max lo (Float.min v hi), 0.))
     | [ _; Some v; _ ] -> Some v
     | _ -> None)
  | _ -> None

and split_commas args =
  let rec go acc cur = function
    | [] -> List.rev (List.rev cur :: acc)
    | Tok Comma :: r -> go (List.rev cur :: acc) [] r
    | c :: r -> go acc (c :: cur) r in
  go [] [] args

(* + - * / with the usual precedence; the operands lengths or numbers *)
and calc ctx (args : cv list) : num option =
  let toks = List.filter (fun c -> c <> Tok Whitespace) args in
  let mul a b = match a, b with
    | Px (p, q), Num n | Num n, Px (p, q) -> Some (Px (p *. n, q *. n))
    | Num a, Num b -> Some (Num (a *. b)) | _ -> None in
  let div a b = match a, b with
    | Px (p, q), Num n when n <> 0. -> Some (Px (p /. n, q /. n))
    | Num a, Num b when b <> 0. -> Some (Num (a /. b)) | _ -> None in
  let add a b sign = match a, b with
    | Px (p, q), Px (r, s) -> Some (Px (p +. sign *. r, q +. sign *. s))
    | Num a, Num b -> Some (Num (a +. sign *. b))
    | Px (p, q), Num 0. | Num 0., Px (p, q) -> Some (Px (p, q))
    | _ -> None in
  (* a product: operand (op operand)* *)
  let rec product = function
    | x :: rest ->
      (match length_value ctx x with
       | None -> (None, [])
       | Some v ->
         let rec more v = function
           | Tok (Delim "*") :: y :: r -> (match Option.bind (length_value ctx y) (mul v) with
               | Some v -> more v r | None -> (None, []))
           | Tok (Delim "/") :: y :: r -> (match Option.bind (length_value ctx y) (div v) with
               | Some v -> more v r | None -> (None, []))
           | r -> (Some v, r) in
         more v rest)
    | [] -> (None, []) in
  let rec sum acc = function
    | [] -> acc
    | Tok (Delim "+") :: r -> (match product r with
        | Some v, r -> (match Option.bind acc (fun a -> add a v 1.) with Some s -> sum (Some s) r | None -> None)
        | None, _ -> None)
    | Tok (Delim "-") :: r -> (match product r with
        | Some v, r -> (match Option.bind acc (fun a -> add a v (-1.)) with Some s -> sum (Some s) r | None -> None)
        | None, _ -> None)
    | Tok (Number (x, _)) :: r when x < 0. && acc <> None ->
      (* "a -2px" written without a space after the sign: a sum too *)
      sum acc (Tok (Delim "-") :: Tok (Number (-. x, true)) :: r)
    | Tok (Dimension (x, u)) :: r when x < 0. && acc <> None ->
      sum acc (Tok (Delim "-") :: Tok (Dimension (-. x, u)) :: r)
    | _ -> None in
  match product toks with
  | Some v, rest -> sum (Some v) rest
  | None, _ -> None

let length ctx (v : cv list) : length option =
  match List.filter (fun c -> c <> Tok Whitespace) v with
  | [ Tok (Ident "auto") ] | [ Tok (Ident "none") ] -> Some Auto
  | [ Tok (Ident ("fit-content" | "max-content" | "min-content" | "stretch" | "-webkit-fill-available")) ] -> Some Auto
  | [ x ] -> (match length_value ctx x with
      | Some (Px (p, q)) -> Some (Len (p, q))
      | Some (Num 0.) -> Some (Len (0., 0.))
      | _ -> None)
  | _ -> None

(* ---- var() ---- *)

(* var(--name, fallback) replaced by the custom property's value; [None]
   when a reference has no value and no fallback (the declaration is then
   invalid at computed-value time: as if unset). A custom property that
   refers to itself, directly or not (Wikipedia's [--x: var(--x, 1rem)]),
   or whose value cannot be substituted, has no value: the fallback holds
   (CSS Variables, 2.3: dependency cycles) *)
let rec substitute ?(seen = []) custom depth (v : cv list) : cv list option =
  if depth > 16 then None
  else
    let failed = ref false in
    let rec go = function
      | Func ("var", args) ->
        let name, fallback = match Css.trim args with
          | Tok (Ident n) :: rest ->
            let rec after_comma = function
              | Tok Comma :: r -> Some r | Tok Whitespace :: r -> after_comma r | _ -> None in
            (n, after_comma rest)
          | _ -> ("", None) in
        let value =
          if List.mem name seen then None
          else Option.bind (List.assoc_opt name custom)
              (substitute ~seen:(name :: seen) custom (depth + 1)) in
        (match value with
         | Some v -> v
         | None -> (match fallback with
             | Some f -> (match substitute ~seen custom (depth + 1) f with Some v -> v | None -> failed := true; [])
             | None -> failed := true; []))
      | Func (f, args) -> [ Func (f, List.concat_map go args) ]
      | Css.Block (c, inner) -> [ Css.Block (c, List.concat_map go inner) ]
      | t -> [ t ] in
    let out = List.concat_map go v in
    if !failed then None else Some out

let rec has_var = function
  | [] -> false
  | Func ("var", _) :: _ -> true
  | (Func (_, a) | Css.Block (_, a)) :: r -> has_var a || has_var r
  | _ :: r -> has_var r

(* ---- applying a declaration ---- *)

let idents v = List.filter_map (function Tok (Ident i) -> Some (String.lowercase_ascii i) | _ -> None) v
let ident v = match List.filter (fun c -> c <> Tok Whitespace) v with
  | [ Tok (Ident i) ] -> Some (String.lowercase_ascii i) | _ -> None

(* the space-separated parts of a value (top level) *)
let parts v =
  let rec go acc cur = function
    | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
    | Tok Whitespace :: r -> go (if cur = [] then acc else List.rev cur :: acc) [] r
    | c :: r -> go acc (c :: cur) r in
  go [] [] v

(* 1 to 4 values for top, right, bottom, left *)
let four = function
  | [ a ] -> Some [| a; a; a; a |]
  | [ a; b ] -> Some [| a; b; a; b |]
  | [ a; b; c ] -> Some [| a; b; c; b |]
  | [ a; b; c; d ] -> Some [| a; b; c; d |]
  | _ -> None

let display_of = function
  | "none" -> Some None_ | "contents" -> Some Contents | "block" | "flow-root" | "flow" -> Some Block
  | "inline" -> Some Inline | "inline-block" -> Some Inline_block | "list-item" -> Some List_item
  | "table" | "inline-table" -> Some Table | "table-row" -> Some Table_row | "table-cell" -> Some Table_cell
  | "table-row-group" | "table-header-group" | "table-footer-group" -> Some Table_group
  | "table-caption" -> Some Table_caption | "table-column" | "table-column-group" -> Some Table_column
  | "flex" | "-webkit-box" | "-webkit-flex" | "-ms-flexbox" -> Some Flex
  | "inline-flex" | "-webkit-inline-flex" -> Some Inline_flex
  | "grid" | "-ms-grid" -> Some Grid | "inline-grid" -> Some Inline_grid
  | "ruby" | "ruby-base" | "ruby-text" -> Some Inline
  | _ -> None

let font_size_of ctx v =
  match ident v with
  | Some "xx-small" -> Some 9. | Some "x-small" -> Some 10. | Some "small" -> Some 13.
  | Some "medium" -> Some 16. | Some "large" -> Some 18. | Some "x-large" -> Some 24.
  | Some "xx-large" -> Some 32. | Some "xxx-large" -> Some 48.
  | Some "smaller" -> Some (ctx.parent_fs /. 1.2) | Some "larger" -> Some (ctx.parent_fs *. 1.2)
  | _ ->
    (* em and % of the parent's size *)
    let ctx' = { ctx with fs = ctx.parent_fs } in
    match length ctx' v with
    | Some (Len (px, pct)) -> Some (px +. pct *. ctx.parent_fs /. 100.)
    | _ -> None

let weight_of = function
  | "normal" -> Some 400 | "bold" -> Some 700 | "bolder" -> Some 700 | "lighter" -> Some 300
  | _ -> None

let apply_font_shorthand ctx s v =
  (* [style] [variant] [weight] size[/line-height] family *)
  let rec go = function
    | Tok (Ident i) :: r when List.mem (String.lowercase_ascii i) [ "italic"; "oblique" ] -> s.italic <- true; go r
    | Tok (Ident i) :: r when List.mem (String.lowercase_ascii i) [ "normal"; "small-caps" ] -> go r
    | Tok (Ident i) :: r when weight_of (String.lowercase_ascii i) <> None ->
      s.font_weight <- Option.get (weight_of (String.lowercase_ascii i)); go r
    | Tok (Number (w, true)) :: r when w >= 100. && w <= 1000. -> s.font_weight <- int_of_float w; go r
    | Tok Whitespace :: r -> go r
    | r -> r in
  (* the shorthand resets what it does not give *)
  s.italic <- false; s.font_weight <- 400; s.line_height <- Lh_normal;
  let rest = go v in
  let skip_ws = List.filter (fun c -> c <> Tok Whitespace) in
  match rest with
  | size :: r ->
    (match font_size_of ctx [ size ] with
     | Some fs -> s.font_size <- fs;
       let r = match r with Tok Whitespace :: r -> r | r -> r in
       let family =
         match r with
         | Tok (Delim "/") :: r ->
           (match skip_ws (List.filteri (fun i _ -> i < 2) r) |> List.hd |> fun lh -> lh with
            | Tok (Number (f, _)) -> s.line_height <- Lh_factor f
            | Tok (Ident "normal") -> s.line_height <- Lh_normal
            | x -> (match length { ctx with fs } [ x ] with
                | Some (Len (px, pct)) -> s.line_height <- Lh_px (px +. pct *. fs /. 100.)
                | _ -> ())
            | exception _ -> ());
           (* past the line height *)
           let rec drop = function Tok Whitespace :: r -> drop r | _ :: r -> r | [] -> [] in
           drop r
         | r -> r in
       let fam = String.trim (Css.to_string family) in
       if fam <> "" then s.font_family <- fam
     | None -> ())
  | [] -> ()

let set_border_width ctx s i v =
  match ident v with
  | Some "thin" -> s.border_width.(i) <- 1.
  | Some "medium" -> s.border_width.(i) <- 3.
  | Some "thick" -> s.border_width.(i) <- 5.
  | _ -> (match length ctx v with Some (Len (px, _)) -> s.border_width.(i) <- Float.max 0. px | _ -> ())

let set_border_style s i v =
  match ident v with
  | Some st -> s.border_style.(i) <- st <> "none" && st <> "hidden"
  | None -> ()

let set_border_color s i v =
  match color ~current:s.color v with Some c -> s.border_color.(i) <- c | None -> ()

(* a border shorthand: its parts in any order *)
let border_shorthand ctx s sides v =
  List.iter (fun p ->
      match p with
      | [ Tok (Ident st) ] when List.mem (String.lowercase_ascii st)
            [ "none"; "hidden"; "solid"; "dashed"; "dotted"; "double"; "groove"; "ridge"; "inset"; "outset" ] ->
        List.iter (fun i -> set_border_style s i p) sides
      | [ Tok (Ident w) ] when List.mem (String.lowercase_ascii w) [ "thin"; "medium"; "thick" ] ->
        List.iter (fun i -> set_border_width ctx s i p) sides
      | _ ->
        (match length ctx p with
         | Some (Len _) -> List.iter (fun i -> set_border_width ctx s i p) sides
         | _ -> List.iter (fun i -> set_border_color s i p) sides)) (parts v)

let side_index = function "top" -> 0 | "right" -> 1 | "bottom" -> 2 | "left" -> 3 | _ -> -1

(* ---- backgrounds and masks ---- *)

(* the first layer of a value (layers are separated by commas) *)
let first_layer (v : cv list) =
  let rec go acc = function
    | Tok Comma :: _ | [] -> List.rev acc
    | c :: r -> go (c :: acc) r in
  go [] v

let url_of (c : cv) = match c with
  | Tok (Url u) | Func ("url", [ Tok (String u) ]) -> Some u
  | Func ("url", args) -> (match Css.trim args with [ Tok (String u) ] -> Some u | _ -> None)
  | _ -> None

let layer_image (l : layer) v =
  match List.filter (fun c -> c <> Tok Whitespace) (first_layer v) with
  | [ c ] -> (match url_of c with Some u -> l.image <- Some u | None -> l.image <- None)
  | _ -> l.image <- None

let layer_repeat (l : layer) words =
  match words with
  | [ "repeat-x" ] -> l.rep_x <- true; l.rep_y <- false
  | [ "repeat-y" ] -> l.rep_x <- false; l.rep_y <- true
  | [ w ] -> let r = w <> "no-repeat" in l.rep_x <- r; l.rep_y <- r
  | [ a; b ] -> l.rep_x <- a <> "no-repeat"; l.rep_y <- b <> "no-repeat"
  | _ -> ()

let is_repeat w = List.mem w [ "repeat"; "no-repeat"; "repeat-x"; "repeat-y"; "space"; "round" ]

(* a position's parts (one or two: keywords, lengths, percentages) *)
let layer_position ctx (l : layer) (ps : cv list list) =
  let kw = function
    | [ Tok (Ident i) ] -> Some (String.lowercase_ascii i) | _ -> None in
  let pct p = Len (0., p) in
  let horiz = function "left" -> Some (pct 0.) | "center" -> Some (pct 50.) | "right" -> Some (pct 100.) | _ -> None in
  let vert = function "top" -> Some (pct 0.) | "center" -> Some (pct 50.) | "bottom" -> Some (pct 100.) | _ -> None in
  let len p = match length ctx p with Some (Len _ as l) -> Some l | _ -> None in
  match ps with
  | [ a ] ->
    (match kw a with
     | Some ("top" | "bottom" as k) -> l.pos_x <- pct 50.; Option.iter (fun y -> l.pos_y <- y) (vert k)
     | Some k -> Option.iter (fun x -> l.pos_x <- x) (horiz k); l.pos_y <- pct 50.
     | None -> Option.iter (fun x -> l.pos_x <- x; l.pos_y <- pct 50.) (len a))
  | a :: b :: _ ->
    let a, b = match kw a, kw b with
      | Some ("top" | "bottom"), _ | _, Some ("left" | "right") -> (b, a)
      | _ -> (a, b) in
    (match kw a with Some k -> Option.iter (fun x -> l.pos_x <- x) (horiz k)
                   | None -> Option.iter (fun x -> l.pos_x <- x) (len a));
    (match kw b with Some k -> Option.iter (fun y -> l.pos_y <- y) (vert k)
                   | None -> Option.iter (fun y -> l.pos_y <- y) (len b))
  | [] -> ()

let layer_size ctx (l : layer) (ps : cv list list) =
  match ps with
  | [ [ Tok (Ident i) ] ] when String.lowercase_ascii i = "cover" -> l.size <- Cover
  | [ [ Tok (Ident i) ] ] when String.lowercase_ascii i = "contain" -> l.size <- Contain
  | [ a ] -> (match length ctx a with Some Auto -> l.size <- Size_auto | Some w -> l.size <- Size (w, Auto) | None -> ())
  | [ a; b ] -> (match length ctx a, length ctx b with
      | Some Auto, Some Auto -> l.size <- Size_auto
      | Some w, Some h -> l.size <- Size (w, h) | _ -> ())
  | _ -> ()

(* background's or mask's shorthand: picture, repeat, position [/ size] *)
let layer_shorthand ctx (l : layer) v =
  let v = first_layer v in
  let rec split acc = function
    | Tok (Delim "/") :: r -> (List.rev acc, r)
    | c :: r -> split (c :: acc) r
    | [] -> (List.rev acc, []) in
  let before, after = split [] v in
  let ps = parts before in
  l.image <- List.find_map (function [ c ] -> url_of c | _ -> None) ps;
  let words = List.filter_map (function [ Tok (Ident i) ] -> Some (String.lowercase_ascii i) | _ -> None) ps in
  layer_repeat l (List.filter is_repeat words);
  let position = List.filter (fun p ->
      match p with
      | [ Tok (Ident i) ] -> List.mem (String.lowercase_ascii i) [ "left"; "right"; "top"; "bottom"; "center" ]
      | [ Tok (Percentage _) ] | [ Tok (Dimension _) ] | [ Tok (Number _) ] -> true
      | [ Func ("calc", _) ] -> true
      | _ -> false) ps in
  layer_position ctx l position;
  if after <> [] then layer_size ctx l (parts after)

let rec apply ctx (s : t) (parent : t) name (v : cv list) =
  let len f = match length ctx v with Some l -> f l | None -> () in
  match name with
  | "display" ->
    (* flow-root: a block with a formatting context of its own *)
    if List.mem "flow-root" (idents v) then s.overflow_bfc <- true;
    (match idents v with
     | [ d ] -> Option.iter (fun d -> s.display <- d) (display_of d)
     | [ "block"; "flow-root" ] | [ "block"; "flow" ] -> s.display <- Block
     | [ "inline"; "flow-root" ] -> s.display <- Inline_block
     | [ "block"; "flex" ] -> s.display <- Flex | [ "inline"; "flex" ] -> s.display <- Inline_flex
     | [ "block"; "grid" ] -> s.display <- Grid | [ "inline"; "grid" ] -> s.display <- Inline_grid
     | [ "list-item"; "block" ] | [ "block"; "list-item" ] -> s.display <- List_item
     | _ -> ())
  | "position" ->
    (match ident v with
     | Some "static" -> s.position <- Static | Some "relative" -> s.position <- Relative
     | Some "absolute" -> s.position <- Absolute | Some "fixed" -> s.position <- Fixed
     | Some "sticky" | Some "-webkit-sticky" -> s.position <- Sticky | _ -> ())
  | "float" -> Option.iter (fun f -> s.float_ <- f) (ident v)
  | "color" -> Option.iter (fun c -> if c lsr 24 <> 0 then s.color <- c land 0xFFFFFF) (color ~current:parent.color v)
  | "background-color" -> Option.iter (fun c -> s.background <- c) (color ~current:s.color v)
  | "background" ->
    s.background <- 0;
    List.iter (fun p -> match color ~current:s.color p with Some c -> s.background <- c | None -> ()) (parts v);
    s.bg <- new_layer ();
    layer_shorthand ctx s.bg v
  | "background-image" -> layer_image s.bg v
  | "background-repeat" -> layer_repeat s.bg (idents (first_layer v))
  | "background-position" -> layer_position ctx s.bg (parts (first_layer v))
  | "background-size" -> layer_size ctx s.bg (parts (first_layer v))
  | "mask-repeat" | "-webkit-mask-repeat" -> layer_repeat s.mask (idents (first_layer v))
  | "mask-position" | "-webkit-mask-position" -> layer_position ctx s.mask (parts (first_layer v))
  | "mask-size" | "-webkit-mask-size" -> layer_size ctx s.mask (parts (first_layer v))
  | "font-size" -> Option.iter (fun fs -> s.font_size <- fs) (font_size_of ctx v)
  | "font-weight" ->
    (match v with
     | [ Tok (Number (w, _)) ] -> s.font_weight <- int_of_float w
     | _ -> Option.iter (fun w -> s.font_weight <- w) (Option.bind (ident v) weight_of))
  | "font-style" ->
    (match ident v with
     | Some ("italic" | "oblique") -> s.italic <- true | Some "normal" -> s.italic <- false | _ -> ())
  | "font-family" -> s.font_family <- Css.to_string v
  | "font" -> apply_font_shorthand ctx s v
  | "line-height" ->
    (match List.filter (fun c -> c <> Tok Whitespace) v with
     | [ Tok (Ident "normal") ] -> s.line_height <- Lh_normal
     | [ Tok (Number (f, _)) ] -> s.line_height <- Lh_factor f
     | _ -> (match length ctx v with
         | Some (Len (px, pct)) -> s.line_height <- Lh_px (px +. pct *. s.font_size /. 100.)
         | _ -> ()))
  | "text-align" ->
    (match ident v with
     | Some ("left" | "start" | "-webkit-left" | "-moz-left") -> s.text_align <- Left
     | Some ("right" | "end" | "-webkit-right" | "-moz-right") -> s.text_align <- Right
     | Some ("center" | "-webkit-center" | "-moz-center") -> s.text_align <- Center
     | Some "justify" -> s.text_align <- Justify
     | _ -> ())
  | "text-indent" -> len (fun l -> s.text_indent <- l)
  | "white-space" | "white-space-collapse" ->
    (match idents v with
     | [ "normal" ] -> s.white_space <- Normal | [ "pre" ] -> s.white_space <- Pre
     | [ "nowrap" ] -> s.white_space <- Nowrap | [ "pre-wrap" ] | [ "break-spaces" ] -> s.white_space <- Pre_wrap
     | [ "pre-line" ] -> s.white_space <- Pre_line
     | [ "preserve" ] -> s.white_space <- Pre_wrap | [ "collapse" ] -> s.white_space <- Normal
     | _ -> ())
  | "text-wrap" | "text-wrap-mode" ->
    (match ident v with
     | Some "nowrap" -> if s.white_space = Normal then s.white_space <- Nowrap
     | Some "wrap" -> if s.white_space = Nowrap then s.white_space <- Normal
     | _ -> ())
  | "text-decoration" | "text-decoration-line" ->
    let ids = idents v in
    if List.mem "none" ids then (s.underline <- false; s.line_through <- false; s.overline <- false)
    else begin
      if List.mem "underline" ids then s.underline <- true;
      if List.mem "line-through" ids then s.line_through <- true;
      if List.mem "overline" ids then s.overline <- true
    end
  | "text-transform" ->
    (match ident v with
     | Some "uppercase" -> s.transform <- Upper | Some "lowercase" -> s.transform <- Lower
     | Some "capitalize" -> s.transform <- Capitalize | Some "none" -> s.transform <- No_transform
     | _ -> ())
  | "margin" | "padding" ->
    (match four (List.map (fun p -> length ctx p) (parts v)) with
     | Some ls when Array.for_all Option.is_some ls ->
       let ls = Array.map Option.get ls in
       if name = "margin" then s.margin <- ls else s.padding <- Array.map (function Auto -> Len (0., 0.) | l -> l) ls
     | _ -> ())
  | "margin-top" | "margin-right" | "margin-bottom" | "margin-left" ->
    len (fun l -> s.margin.(side_index (String.sub name 7 (String.length name - 7))) <- l)
  | "padding-top" | "padding-right" | "padding-bottom" | "padding-left" ->
    len (fun l -> s.padding.(side_index (String.sub name 8 (String.length name - 8))) <- l)
  | "margin-block" | "margin-inline" | "padding-block" | "padding-inline" ->
    let is_margin = String.starts_with ~prefix:"margin" name in
    let sides = if String.ends_with ~suffix:"block" name then (0, 2) else (3, 1) in
    (match List.map (length ctx) (parts v) with
     | [ Some a ] -> apply_pair s is_margin sides a a
     | [ Some a; Some b ] -> apply_pair s is_margin sides a b
     | _ -> ())
  | "margin-block-start" -> len (fun l -> s.margin.(0) <- l)
  | "margin-block-end" -> len (fun l -> s.margin.(2) <- l)
  | "margin-inline-start" -> len (fun l -> s.margin.(3) <- l)
  | "margin-inline-end" -> len (fun l -> s.margin.(1) <- l)
  | "padding-block-start" -> len (fun l -> s.padding.(0) <- l)
  | "padding-block-end" -> len (fun l -> s.padding.(2) <- l)
  | "padding-inline-start" -> len (fun l -> s.padding.(3) <- l)
  | "padding-inline-end" -> len (fun l -> s.padding.(1) <- l)
  | "border" -> border_shorthand ctx s [ 0; 1; 2; 3 ] v
  | "border-top" | "border-right" | "border-bottom" | "border-left" ->
    border_shorthand ctx s [ side_index (String.sub name 7 (String.length name - 7)) ] v
  | "border-block" -> border_shorthand ctx s [ 0; 2 ] v
  | "border-inline" -> border_shorthand ctx s [ 1; 3 ] v
  | "border-block-start" -> border_shorthand ctx s [ 0 ] v
  | "border-block-end" -> border_shorthand ctx s [ 2 ] v
  | "border-inline-start" -> border_shorthand ctx s [ 3 ] v
  | "border-inline-end" -> border_shorthand ctx s [ 1 ] v
  | "border-width" | "border-style" | "border-color" ->
    (match four (parts v) with
     | Some ps ->
       Array.iteri (fun i p ->
           match name with
           | "border-width" -> set_border_width ctx s i p
           | "border-style" -> set_border_style s i p
           | _ -> set_border_color s i p) ps
     | None -> ())
  | "border-top-width" | "border-right-width" | "border-bottom-width" | "border-left-width" ->
    set_border_width ctx s (side_index (List.nth (String.split_on_char '-' name) 1)) v
  | "border-top-style" | "border-right-style" | "border-bottom-style" | "border-left-style" ->
    set_border_style s (side_index (List.nth (String.split_on_char '-' name) 1)) v
  | "border-top-color" | "border-right-color" | "border-bottom-color" | "border-left-color" ->
    set_border_color s (side_index (List.nth (String.split_on_char '-' name) 1)) v
  | "width" -> len (fun l -> s.width <- l)
  | "height" -> len (fun l -> s.height <- l)
  | "min-width" -> len (fun l -> s.min_width <- (match l with Auto -> Len (0., 0.) | l -> l))
  | "max-width" -> len (fun l -> s.max_width <- l)
  | "min-height" -> len (fun l -> s.min_height <- (match l with Auto -> Len (0., 0.) | l -> l))
  | "max-height" -> len (fun l -> s.max_height <- l)
  | "inline-size" -> apply ctx s parent "width" v
  | "block-size" -> apply ctx s parent "height" v
  | "max-inline-size" -> apply ctx s parent "max-width" v
  | "min-inline-size" -> apply ctx s parent "min-width" v
  | "box-sizing" ->
    (match ident v with Some "border-box" -> s.border_box <- true | Some "content-box" -> s.border_box <- false | _ -> ())
  | "visibility" ->
    (match ident v with
     | Some "visible" -> s.visible <- true | Some ("hidden" | "collapse") -> s.visible <- false | _ -> ())
  | "list-style-type" -> Option.iter (fun t -> s.list_style <- t) (ident v)
  | "clear" -> Option.iter (fun c -> s.clear <- c) (ident v)
  | "top" | "right" | "bottom" | "left" -> len (fun l -> s.inset.(side_index name) <- l)
  | "inset" ->
    (match four (List.map (length ctx) (parts v)) with
     | Some ls when Array.for_all Option.is_some ls -> s.inset <- Array.map Option.get ls
     | _ -> ())
  | "overflow" | "overflow-x" | "overflow-y" ->
    let ids = idents v in
    let any k = List.exists (fun i -> List.mem i k) ids in
    if any [ "hidden"; "clip" ] then (s.overflow_clip <- true; s.overflow_bfc <- true)
    else if any [ "auto"; "scroll"; "overlay" ] then s.overflow_bfc <- true
    else if ids = [ "visible" ] && name = "overflow" then (s.overflow_clip <- false; s.overflow_bfc <- false)
  | "clip" ->
    (match v with
     | [ Func ("rect", _) ] -> s.clipped <- true
     | _ -> if ident v = Some "auto" then s.clipped <- false)
  | "clip-path" ->
    (match List.filter (fun c -> c <> Tok Whitespace) v with
     | [ Func ("inset", [ Tok (Percentage p) ]) ] when p >= 50. -> s.clipped <- true
     | [ Func ("inset", _) ] -> ()
     | _ -> if ident v = Some "none" then s.clipped <- false)
  | "vertical-align" ->
    (match ident v with Some a -> s.vertical_align <- a | None -> ())
  | "flex-direction" -> Option.iter (fun d -> s.flex_direction <- d) (ident v)
  | "flex-wrap" -> Option.iter (fun w -> s.flex_wrap <- w <> "nowrap") (ident v)
  | "flex-flow" ->
    List.iter (fun i ->
        if List.mem i [ "row"; "row-reverse"; "column"; "column-reverse" ] then s.flex_direction <- i
        else if List.mem i [ "wrap"; "wrap-reverse" ] then s.flex_wrap <- true
        else if i = "nowrap" then s.flex_wrap <- false) (idents v)
  | "justify-content" ->
    (match List.rev (idents v) with i :: _ -> s.justify <- i | [] -> ())
  | "align-items" ->
    (match List.rev (idents v) with i :: _ -> s.align_items <- i | [] -> ())
  | "align-self" ->
    (match List.rev (idents v) with i :: _ -> s.align_self <- i | [] -> ())
  | "place-items" ->
    (match idents v with i :: _ -> s.align_items <- i | [] -> ())
  | "place-content" ->
    (match idents v with
     | [ a ] -> s.justify <- a | [ _; j ] -> s.justify <- j | _ -> ())
  | "flex-grow" -> (match v with [ Tok (Number (g, _)) ] -> s.flex_grow <- g | _ -> ())
  | "flex-shrink" -> (match v with [ Tok (Number (g, _)) ] -> s.flex_shrink <- g | _ -> ())
  | "flex-basis" ->
    (match ident v with
     | Some ("auto" | "content") -> s.flex_basis <- Auto
     | _ -> len (fun l -> s.flex_basis <- l))
  | "flex" ->
    (match List.filter (fun c -> c <> Tok Whitespace) v with
     | [ Tok (Ident n) ] when String.lowercase_ascii n = "none" ->
       s.flex_grow <- 0.; s.flex_shrink <- 0.; s.flex_basis <- Auto
     | [ Tok (Ident n) ] when String.lowercase_ascii n = "auto" ->
       s.flex_grow <- 1.; s.flex_shrink <- 1.; s.flex_basis <- Auto
     | [ Tok (Ident n) ] when String.lowercase_ascii n = "initial" ->
       s.flex_grow <- 0.; s.flex_shrink <- 1.; s.flex_basis <- Auto
     | parts ->
       let nums = List.filter_map (function Tok (Number (g, _)) -> Some g | _ -> None) parts in
       let basis = List.find_map (fun c -> match c with
           | Tok (Number _) -> None
           | c -> length ctx [ c ]) parts in
       (match nums with
        | g :: rest -> s.flex_grow <- g; s.flex_shrink <- (match rest with sh :: _ -> sh | [] -> 1.);
          s.flex_basis <- (match basis with Some b -> b | None -> Len (0., 0.))
        | [] -> (match basis with Some b -> s.flex_grow <- 1.; s.flex_shrink <- 1.; s.flex_basis <- b | None -> ())))
  | "order" -> (match v with [ Tok (Number (o, _)) ] -> s.order <- int_of_float o | _ -> ())
  | "gap" | "grid-gap" ->
    (match List.map (length ctx) (parts v) with
     | [ Some a ] -> s.row_gap <- a; s.column_gap <- a
     | [ Some a; Some b ] -> s.row_gap <- a; s.column_gap <- b
     | _ -> ())
  | "row-gap" | "grid-row-gap" -> len (fun l -> s.row_gap <- l)
  | "column-gap" | "grid-column-gap" -> len (fun l -> s.column_gap <- l)
  | "grid-template-columns" -> s.grid_columns <- v
  | "grid-template-rows" -> s.grid_rows <- v
  | "grid-template-areas" ->
    s.grid_areas <- List.filter_map (function
        | Tok (String row) -> Some (List.filter (fun x -> x <> "") (String.split_on_char ' ' row))
        | _ -> None) v
  | "grid-template" -> ()
  | "grid-area" -> s.grid_area <- v
  | "grid-column" -> s.grid_column <- v
  | "grid-row" -> s.grid_row <- v
  | "grid-column-start" -> s.grid_column <- v
  | "grid-row-start" -> s.grid_row <- v
  | "content" -> s.content <- Some v
  | "caption-side" -> Option.iter (fun c -> s.caption_bottom <- c = "bottom") (ident v)
  | "opacity" ->
    (match v with
     | [ Tok (Number (a, _)) ] -> if a <= 0.01 then s.transparent <- true
     | [ Tok (Percentage a) ] -> if a <= 1. then s.transparent <- true
     | _ -> ())
  | "transform" | "-webkit-transform" | "-ms-transform" ->
    (* the translations, added up; the other functions (scale, rotate...)
       are not drawn, nor do they move the box *)
    if ident v = Some "none" then s.shift <- None
    else begin
      let zero = Len (0., 0.) in
      let add (a, b) (c, d) = match a, c, b, d with
        | Len (p, q), Len (p', q'), Len (r, t), Len (r', t') -> (Len (p +. p', q +. q'), Len (r +. r', t +. t'))
        | _ -> (a, b) in
      let len args = match length ctx args with Some (Len _ as l) -> l | _ -> zero in
      let total = List.fold_left (fun acc c -> match c with
          | Func (("translatex"), args) -> add acc (len args, zero)
          | Func ("translatey", args) -> add acc (zero, len args)
          | Func (("translate" | "translate3d"), args) ->
            (match split_commas args with
             | x :: y :: _ -> add acc (len x, len y)
             | [ x ] -> add acc (len x, zero)
             | [] -> acc)
          | _ -> acc) (zero, zero) v in
      s.shift <- (if total = (zero, zero) then None else Some total)
    end
  | "translate" ->
    (match List.map (fun p -> Option.value (length ctx p) ~default:(Len (0., 0.))) (parts v) with
     | [ x ] -> s.shift <- Some (x, Len (0., 0.))
     | x :: y :: _ -> s.shift <- Some (x, y)
     | [] -> ())
  | "mask-image" | "-webkit-mask-image" ->
    s.masked <- ident v <> Some "none";
    layer_image s.mask v
  | "mask" | "-webkit-mask" ->
    s.masked <- ident v <> Some "none";
    s.mask <- new_layer ();
    layer_shorthand ctx s.mask v
  | "border-collapse" -> Option.iter (fun c -> s.border_collapse <- c = "collapse") (ident v)
  | "border-spacing" ->
    (match List.map (length ctx) (parts v) with
     | Some (Len (p, _)) :: _ -> s.border_spacing <- p | _ -> ())
  | "list-style" ->
    List.iter (fun i -> if not (List.mem i [ "inside"; "outside" ]) then s.list_style <- i) (idents v)
  | _ -> ()

and apply_pair s is_margin (a_side, b_side) a b =
  let arr = if is_margin then s.margin else s.padding in
  let fix = if is_margin then Fun.id else (function Auto -> Len (0., 0.) | l -> l) in
  arr.(a_side) <- fix a; arr.(b_side) <- fix b

(* the properties Ariadne knows, for @supports *)
let known = [
  "display"; "position"; "float"; "color"; "background"; "background-color"; "font"; "font-size";
  "font-weight"; "font-style"; "font-family"; "line-height"; "text-align"; "text-indent";
  "white-space"; "text-decoration"; "text-transform"; "margin"; "padding"; "border"; "width";
  "height"; "min-width"; "max-width"; "min-height"; "max-height"; "box-sizing"; "visibility";
  "list-style"; "list-style-type"; "background-image"; "background-repeat"; "background-position";
  "background-size"; "mask"; "mask-image"; "mask-size"; "mask-position"; "mask-repeat" ]

(* ---- media queries ---- *)

let media_feature ~width ~height (inner : cv list) =
  let ctx = { vw = float width; vh = float height; root_fs = 16.; fs = 16.; parent_fs = 16. } in
  let px v = match length ctx [ v ] with Some (Len (p, _)) -> Some p | _ -> None in
  let toks = List.filter (fun c -> c <> Tok Whitespace) inner in
  let value_of name = match name with
    | "width" -> Some (float width) | "height" -> Some (float height)
    | "aspect-ratio" -> Some (float width /. float (max 1 height))
    | "resolution" -> Some 1. | _ -> None in
  let cmp op a b = match op with
    | "<" -> a < b | "<=" -> a <= b | ">" -> a > b | ">=" -> a >= b | _ -> a = b in
  match toks with
  | [ Tok (Ident f) ] ->
    (match String.lowercase_ascii f with
     | "color" | "hover" | "any-hover" | "pointer" | "any-pointer" | "grid" -> f <> "grid"
     | _ -> false)
  | Tok (Ident f) :: Tok Colon :: v ->
    let f = String.lowercase_ascii f in
    let id = match v with [ Tok (Ident i) ] -> Some (String.lowercase_ascii i) | _ -> None in
    let num () = match v with [ x ] -> px x | _ -> None in
    (match f with
     | "min-width" -> (match num () with Some p -> float width >= p | None -> false)
     | "max-width" -> (match num () with Some p -> float width <= p | None -> false)
     | "width" -> (match num () with Some p -> float width = p | None -> false)
     | "min-height" -> (match num () with Some p -> float height >= p | None -> false)
     | "max-height" -> (match num () with Some p -> float height <= p | None -> false)
     | "orientation" -> id = Some (if width >= height then "landscape" else "portrait")
     | "prefers-color-scheme" -> id = Some "light"
     | "prefers-reduced-motion" | "prefers-reduced-transparency" | "prefers-contrast"
     | "forced-colors" | "inverted-colors" -> id = Some "no-preference" || id = Some "none"
     | "hover" | "any-hover" -> id = Some "hover"
     | "pointer" | "any-pointer" -> id = Some "fine"
     | "scripting" -> id = Some "none"
     | "display-mode" -> id = Some "browser"
     | "min-resolution" | "-webkit-min-device-pixel-ratio" | "min--moz-device-pixel-ratio" ->
       (match v with
        | [ Tok (Dimension (r, ("dppx" | "x"))) ] -> r <= 1.
        | [ Tok (Dimension (r, "dpi")) ] -> r <= 96.
        | [ Tok (Number (r, _)) ] -> r <= 1.
        | _ -> false)
     | "max-resolution" | "-webkit-max-device-pixel-ratio" -> true
     | "update" -> id = Some "fast"
     | "color-gamut" -> id = Some "srgb"
     | _ -> false)
  (* ranges: (width >= 600px), (400px < width <= 800px) *)
  | [ Tok (Ident f); Tok (Delim d1); Tok (Delim "="); x ] ->
    (match value_of (String.lowercase_ascii f), px x with Some a, Some b -> cmp (d1 ^ "=") a b | _ -> false)
  | [ Tok (Ident f); Tok (Delim d1); x ] ->
    (match value_of (String.lowercase_ascii f), px x with Some a, Some b -> cmp d1 a b | _ -> false)
  | [ x; Tok (Delim d1); Tok (Delim "="); Tok (Ident f) ] ->
    (match value_of (String.lowercase_ascii f), px x with Some a, Some b -> cmp (d1 ^ "=") b a | _ -> false)
  | [ x; Tok (Delim d1); Tok (Ident f) ] ->
    (match value_of (String.lowercase_ascii f), px x with Some a, Some b -> cmp d1 b a | _ -> false)
  | x :: Tok (Delim d1) :: rest ->
    (* a < width < b, with or without "=" *)
    let op1, rest = match rest with Tok (Delim "=") :: r -> (d1 ^ "=", r) | r -> (d1, r) in
    (match rest with
     | Tok (Ident f) :: Tok (Delim d2) :: rest2 ->
       let op2, rest2 = match rest2 with Tok (Delim "=") :: r -> (d2 ^ "=", r) | r -> (d2, r) in
       (match rest2, value_of (String.lowercase_ascii f), px x with
        | [ y ], Some a, Some lo -> (match px y with Some hi -> cmp op1 lo a && cmp op2 a hi | None -> false)
        | _ -> false)
     | _ -> false)
  | _ -> false

(* a media query list: true if one of its queries holds *)
let media_ok ~width ~height (cvs : cv list) =
  let queries = split_commas cvs in
  cvs = [] || List.exists (fun q ->
      let toks = List.filter (fun c -> c <> Tok Whitespace) q in
      let negate, toks = match toks with
        | Tok (Ident n) :: r when String.lowercase_ascii n = "not" -> (true, r)
        | Tok (Ident o) :: r when String.lowercase_ascii o = "only" -> (false, r)
        | t -> (false, t) in
      let rec conds = function
        | [] -> true
        | Tok (Ident a) :: r when String.lowercase_ascii a = "and" -> conds r
        | Tok (Ident o) :: _ when String.lowercase_ascii o = "or" -> true
        | Tok (Ident t) :: r ->
          (match String.lowercase_ascii t with
           | "all" | "screen" -> conds r
           | "not" -> (match r with Css.Block ('(', inner) :: r2 -> not (media_feature ~width ~height inner) && conds r2 | _ -> false)
           | _ -> false)
        | Css.Block ('(', inner) :: r ->
          (* a nested condition, or a feature *)
          let nested = List.exists (function Css.Block ('(', _) -> true | _ -> false) inner in
          (if nested then conds (List.filter (fun c -> c <> Tok Whitespace) inner)
           else media_feature ~width ~height inner) && conds r
        | _ -> false in
      let r = conds toks in
      if negate then not r else r) queries

(* @supports: a declaration Ariadne knows, a selector it parses *)
let rec supports (cvs : cv list) =
  match List.filter (fun c -> c <> Tok Whitespace) cvs with
  | Tok (Ident n) :: r when String.lowercase_ascii n = "not" -> not (supports r)
  | [ Css.Block ('(', inner) ] -> supports_one inner
  | Css.Block ('(', inner) :: Tok (Ident op) :: rest ->
    let a = supports_one inner and b = supports rest in
    if String.lowercase_ascii op = "or" then a || b else a && b
  | [ Func ("selector", args) ] -> Selector.parse_list args <> None
  | _ -> false

and supports_one inner =
  match Css.trim inner with
  | Tok (Ident p) :: _ when List.exists (function Tok Colon -> true | _ -> false) inner ->
    let p = String.lowercase_ascii p in
    List.mem p known
    && (match Css.declaration inner with
        | Some d -> (match p with
            | "display" -> List.for_all (fun i -> display_of i <> None
                                                  && not (List.mem i [ "grid"; "inline-grid"; "flex"; "inline-flex" ])) (idents d.value)
            | _ -> true)
        | None -> false)
  | l -> supports l

(* ---- style sheets ---- *)

type origin = User_agent | Author

type rule = {
  sel : Selector.complex;
  anc : string list;            (* the ancestor filter's keys (Selector.ancestor_keys) *)
  spec : int;
  order : int;
  decls : decl list;
  media : cv list list;         (* the conditions it sits in: all must hold *)
  origin : origin;
  pseudo : string option;       (* "before", "after": a pseudo-element's rule *)
}

type sheet = { rules : rule list; imports : (string * cv list) list }

let counter = ref 0

(* url()s made absolute: against the sheet's own URL (a data: URL, or a
   fragment, as they are) *)
let rec resolve_urls base (decls : decl list) =
  let res u = if u = "" || u.[0] = '#' || (String.length u > 5 && String.lowercase_ascii (String.sub u 0 5) = "data:")
    then u else Url.resolve base u in
  let rec go (c : cv) = match c with
    | Tok (Url u) -> Tok (Url (res u))
    | Func ("url", args) -> Func ("url", List.map (function Tok (String u) -> Tok (String (res u)) | a -> a) args)
    | Func (f, args) -> Func (f, List.map go args)
    | Css.Block (ch, inner) -> Css.Block (ch, List.map go inner)
    | t -> t in
  List.map (fun (d : decl) -> if has_url d.value then { d with value = List.map go d.value } else d) decls

and has_url = function
  | [] -> false
  | (Tok (Url _) | Func ("url", _)) :: _ -> true
  | (Func (_, a) | Css.Block (_, a)) :: r -> has_url a || has_url r
  | _ :: r -> has_url r

let flatten ~origin ?base ?(media = []) rules_in =
  let out = ref [] and imports = ref [] in
  let rec go media = function
    | [] -> ()
    | Css.Style { prelude; decls } :: rest ->
      let decls = match base with Some b -> resolve_urls b decls | None -> decls in
      (match Selector.parse_list prelude with
       | Some sels ->
         List.iter (fun sel ->
             let pseudo = Selector.pseudo_element sel in
             if pseudo = None || pseudo = Some "before" || pseudo = Some "after" then begin
               incr counter;
               out := { sel; anc = Selector.ancestor_keys sel; spec = Selector.specificity sel;
                        order = !counter; decls; media; origin; pseudo } :: !out
             end) sels
       | None -> ());
      go media rest
    | Css.At { name = "media"; prelude; block = Some b } :: rest ->
      go (prelude :: media) (Css.block_rules b); go media rest
    | Css.At { name = "supports"; prelude; block = Some b } :: rest ->
      if supports prelude then go media (Css.block_rules b);
      go media rest
    | Css.At { name = ("layer" | "scope" | "document" | "-moz-document"); block = Some b; _ } :: rest ->
      go media (Css.block_rules b); go media rest
    | Css.At { name = "import"; prelude; block = None } :: rest ->
      (match prelude with
       | (Tok (Url u) | Tok (String u) | Func ("url", [ Tok (String u) ])) :: q ->
         imports := (u, Css.trim q) :: !imports
       | _ -> ());
      go media rest
    | _ :: rest -> go media rest in
  go media rules_in;
  { rules = List.rev !out; imports = List.rev !imports }

let parse_sheet ?(origin = Author) ?base ?media text =
  let media = match media with
    | Some m when String.trim m <> "" -> [ Css.parse_values m ]
    | _ -> [] in
  flatten ~origin ?base ~media (Css.parse_stylesheet text)

(* the browser's own style sheet (the HTML Standard's rendering section,
   15.3), for a screen *)
let ua_text = {|
html, address, blockquote, body, center, dialog, div, figure, figcaption, footer, form, header,
hr, legend, listing, main, p, plaintext, pre, search, xmp, details, summary, article, aside,
h1, h2, h3, h4, h5, h6, hgroup, nav, section, dir, dd, dl, dt, menu, ol, ul, fieldset,
optgroup, frameset, frame, address { display: block }
area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp, script,
style, template, title, [hidden]:not([hidden=until-found i]), input[type=hidden i],
dialog:not([open]), slot, embed[hidden] { display: none }
li { display: list-item }
table { display: table } caption { display: table-caption }
colgroup, col { display: table-column }
thead, tbody, tfoot { display: table-row-group } tr { display: table-row }
td, th { display: table-cell }
ruby { display: ruby } rt { display: ruby-text }
html { color: canvastext; background: canvas }
body { margin: 8px }
p, blockquote, figure, listing, plaintext, pre, xmp, dl, menu, ol, ul { margin-top: 1em; margin-bottom: 1em }
blockquote, figure { margin-left: 40px; margin-right: 40px }
dd { margin-left: 40px }
dir, dl dl, ol dl, ul dl, menu dl, dl ol, dl ul, dl menu, ol ol, ol ul, ol menu, ul ol, ul ul,
ul menu, menu ol, menu ul, menu menu { margin-top: 0; margin-bottom: 0 }
ol, ul, menu, dir { padding-left: 40px }
ol { list-style-type: decimal }
ul ul, ol ul, menu ul { list-style-type: circle }
ul ul ul, ul ol ul, ol ul ul, ol ol ul { list-style-type: square }
h1 { margin: 0.67em 0; font-size: 2em; font-weight: bold }
h2 { margin: 0.83em 0; font-size: 1.5em; font-weight: bold }
h3 { margin: 1em 0; font-size: 1.17em; font-weight: bold }
h4 { margin: 1.33em 0; font-size: 1em; font-weight: bold }
h5 { margin: 1.67em 0; font-size: 0.83em; font-weight: bold }
h6 { margin: 2.33em 0; font-size: 0.67em; font-weight: bold }
hr { margin: 0.5em auto; border: 1px inset gray; color: gray }
fieldset { margin: 0 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove threedface }
legend { padding: 0 2px }
address, cite, dfn, em, i, var { font-style: italic }
b, strong, th { font-weight: bold }
code, kbd, samp, tt, pre, listing, plaintext, xmp { font-family: monospace }
pre, listing, plaintext, xmp { white-space: pre }
textarea { white-space: pre-wrap }
small { font-size: smaller } big { font-size: larger }
sub, sup { font-size: smaller }
u, ins { text-decoration: underline }
s, strike, del { text-decoration: line-through }
mark { background: yellow; color: black }
center { text-align: center }
th { text-align: center }
td, th { padding: 1px }
table { border-spacing: 2px; box-sizing: border-box }
thead, tbody, tfoot, tr { vertical-align: middle }
td, th { vertical-align: inherit }
sub { vertical-align: sub } sup { vertical-align: super }
img, svg, video, canvas, iframe, input, button, select, textarea { display: inline-block }
input, button, select, textarea { overflow: hidden }
input, button, select, textarea { font: 13.3333px sans-serif; color: fieldtext; letter-spacing: normal }
input, select, textarea { background-color: field }
textarea { font-family: monospace }
button, input[type=submit i], input[type=reset i], input[type=button i], select { background-color: buttonface }
input[disabled], button[disabled], select[disabled], textarea[disabled] { color: graytext }
caption { text-align: center }
a:link, a:visited { color: linktext; text-decoration: underline }
abbr[title], acronym[title] { text-decoration: underline }
nobr { white-space: nowrap }
img:is([alt=""]) { display: none }
summary { display: list-item }
details > :not(summary) { display: none }
details[open] > :not(summary) { display: block }
noscript { display: block }
q::before { content: open-quote }
br { display: inline }
|}

let ua_sheet = lazy (parse_sheet ~origin:User_agent ua_text)

(* quirks mode (no doctype, an old one): tables do not inherit these
   (the rendering section, 15.3.7) *)
let ua_quirks = lazy (parse_sheet ~origin:User_agent {|
table { font-weight: initial; font-style: initial; font-size: initial; line-height: initial;
        white-space: initial; text-align: initial }
|})

(* the HTML attributes that act as CSS (the rendering section's
   "presentational hints"): author origin, specificity 0, before the rest *)
let hints (n : Dom.node) =
  let a = Dom.attr n in
  let d name value = { name; value = Css.parse_values value; important = false } in
  let dim name v =
    let v = String.trim v in
    if v = "" then []
    else if String.ends_with ~suffix:"%" v then [ d name v ]
    else match float_of_string_opt v with
      | Some f -> [ d name (Printf.sprintf "%gpx" f) ]
      | None -> [] in
  let name = Dom.name n in
  List.concat [
    (match a "bgcolor" with Some c -> [ d "background-color" c ] | None -> []);
    (match name, a "color" with "font", Some c -> [ d "color" c ] | _ -> []);
    (match name, a "text" with "body", Some c -> [ d "color" c ] | _ -> []);
    (match name, a "size" with
     | "font", Some sz ->
       let base = match int_of_string_opt (String.trim sz) with
         | Some k when String.length (String.trim sz) > 0 && (sz.[0] = '+' || sz.[0] = '-') -> 3 + k
         | Some k -> k | None -> 3 in
       let px = [| 10; 13; 16; 18; 24; 32; 48 |].(max 1 (min 7 base) - 1) in
       [ d "font-size" (string_of_int px ^ "px") ]
     | _ -> []);
    (match a "align" with
     | Some al when List.mem name [ "p"; "div"; "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "td"; "th"; "tr";
                                    "tbody"; "thead"; "tfoot"; "caption" ] ->
       (match String.lowercase_ascii al with
        | "center" | "middle" -> [ d "text-align" "center" ]
        | "left" | "right" | "justify" -> [ d "text-align" (String.lowercase_ascii al) ]
        | _ -> [])
     | Some al when name = "table" && String.lowercase_ascii al = "center" ->
       [ d "margin-left" "auto"; d "margin-right" "auto" ]
     | _ -> []);
    (if List.mem name [ "img"; "table"; "td"; "th"; "col"; "iframe"; "video"; "canvas"; "embed"; "object"; "hr" ]
     then (match a "width" with Some w -> dim "width" w | None -> [])
          @ (match a "height" with Some h when name <> "td" && name <> "th" -> dim "height" h | _ -> [])
     else []);
    (match name, a "border" with
     | "table", Some b ->
       let w = Option.value (int_of_string_opt (String.trim b)) ~default:1 in
       if w > 0 then [ d "border" (Printf.sprintf "%dpx outset gray" w) ] else []
     | _ -> []);
    (match name, a "cellpadding" with
     | "table", Some _ -> []
     | _ -> []);
    (match name, a "nowrap" with ("td" | "th"), Some _ -> [ d "white-space" "nowrap" ] | _ -> []);
  ]

(* ---- the cascade ---- *)

type index = {
  by_id : (string, rule list) Hashtbl.t;
  by_class : (string, rule list) Hashtbl.t;
  by_tag : (string, rule list) Hashtbl.t;
  mutable any : rule list;
}

(* the elements' rules, or (with [~pseudo:true]) the pseudo-elements' *)
let build_index ?(pseudo = false) ~width ~height sheets =
  let ix = { by_id = Hashtbl.create 256; by_class = Hashtbl.create 1024; by_tag = Hashtbl.create 64; any = [] } in
  let add tbl k r = Hashtbl.replace tbl k (r :: Option.value (Hashtbl.find_opt tbl k) ~default:[]) in
  List.iter (fun sh ->
      List.iter (fun r ->
          if (r.pseudo <> None) = pseudo && List.for_all (media_ok ~width ~height) r.media then
            match Selector.key r.sel with
            | Selector.K_id i -> add ix.by_id i r
            | Selector.K_class c -> add ix.by_class c r
            | Selector.K_tag t -> add ix.by_tag t r
            | Selector.K_any -> ix.any <- r :: ix.any) sh.rules) sheets;
  ix

type styles = {
  table : (int, t) Hashtbl.t;
  pseudos : (int * string, t * string) Hashtbl.t;    (* an element's ::before, ::after: style, text *)
  root : t;
}

let get st (n : Dom.node) = Hashtbl.find_opt st.table n.id

(* an element's ::before or ::after, if it has one: its style and its text *)
let pseudo st (n : Dom.node) which = Hashtbl.find_opt st.pseudos (n.id, which)

let classes = Dom.classes

(* the ancestor filter: how many of the current element's ancestors have
   each tag, class and id; a rule whose ancestor keys are not all there
   cannot match, and is not tried *)
type filter = (string, int) Hashtbl.t

let filter_keys n =
  Dom.name n :: (match Dom.attr n "id" with Some i -> [ "#" ^ i ] | None -> [])
  @ List.map (fun c -> "." ^ c) (classes n)

let filter_add (f : filter) n d =
  List.iter (fun k ->
      let v = Option.value (Hashtbl.find_opt f k) ~default:0 + d in
      if v = 0 then Hashtbl.remove f k else Hashtbl.replace f k v) (filter_keys n)

let may_match (f : filter) r = List.for_all (fun k -> Hashtbl.mem f k) r.anc

(* the declarations that apply to an element, from the lowest priority to
   the highest: the browser's, the hints, the author's, the style
   attribute; then the important ones *)
let declarations_for ?(filter = Hashtbl.create 1) ?pseudo ix (n : Dom.node) =
  let candidates = ref [] in
  let take l = List.iter (fun r ->
      if (pseudo = None || r.pseudo = pseudo) && may_match filter r && Selector.matches r.sel n then
        candidates := r :: !candidates) l in
  take ix.any;
  (match Dom.attr n "id" with Some i -> take (Option.value (Hashtbl.find_opt ix.by_id i) ~default:[]) | None -> ());
  List.iter (fun c -> take (Option.value (Hashtbl.find_opt ix.by_class c) ~default:[])) (List.sort_uniq compare (classes n));
  take (Option.value (Hashtbl.find_opt ix.by_tag (Dom.name n)) ~default:[]);
  (* one rule matched through two keys counts once *)
  let matched = List.sort_uniq (fun a b -> compare (a.origin = Author, a.spec, a.order) (b.origin = Author, b.spec, b.order))
      !candidates in
  let ua = List.filter (fun r -> r.origin = User_agent) matched
  and author = List.filter (fun r -> r.origin = Author) matched in
  let inline = match Dom.attr n "style", pseudo with Some s, None -> Css.parse_declarations s | _ -> [] in
  let normal ds = List.filter (fun d -> not d.important) ds
  and important ds = List.filter (fun d -> d.important) ds in
  let all_of rules = List.concat_map (fun r -> r.decls) rules in
  normal (all_of ua) @ (if pseudo = None then hints n else []) @ normal (all_of author) @ normal inline
  @ important (all_of author) @ important inline @ important (all_of ua)

(* a ::before's or ::after's content, as text: strings, attr(), quotes;
   None for none, normal, or nothing to show *)
let content_text (n : Dom.node) (v : cv list) =
  match List.filter (fun c -> c <> Tok Whitespace) v with
  | [ Tok (Ident ("none" | "normal")) ] -> None
  | parts ->
    let b = Buffer.create 16 in
    List.iter (function
        | Tok (String s) -> Buffer.add_string b s
        | Func ("attr", args) ->
          (match Css.trim args with
           | Tok (Ident a) :: _ -> Buffer.add_string b (Option.value (Dom.attr n (String.lowercase_ascii a)) ~default:"")
           | _ -> ())
        | Tok (Ident "open-quote") -> Buffer.add_string b "\xe2\x80\x9c"
        | Tok (Ident "close-quote") -> Buffer.add_string b "\xe2\x80\x9d"
        | _ -> ()) parts;
    let t = Buffer.contents b in
    if t = "" then None else Some t

let compute ~width ~height sheets (doc : Dom.node) =
  let quirks = match doc.kind with Document { quirks = Dom.Quirks; _ } -> true | _ -> false in
  let sheets = Lazy.force ua_sheet :: (if quirks then [ Lazy.force ua_quirks ] else []) @ sheets in
  let ix = build_index ~width ~height sheets in
  let pix = build_index ~pseudo:true ~width ~height sheets in
  let has_pseudo = pix.any <> [] || Hashtbl.length pix.by_id > 0 || Hashtbl.length pix.by_class > 0
                   || Hashtbl.length pix.by_tag > 0 in
  let table = Hashtbl.create 4096 and pseudos = Hashtbl.create 256 in
  let root_style = initial () in
  let root_fs = ref 16. in
  (* the parents' styles, as the walk goes down *)
  let stack = ref [ root_style ] in
  let filter : filter = Hashtbl.create 256 in
  (* a style from its parent's and the declarations that apply *)
  let cascade ~is_root parent decls =
      let s = inherit_from parent in
      let ctx0 = { vw = float width; vh = float height; root_fs = !root_fs; fs = parent.font_size;
                   parent_fs = parent.font_size } in
      (* custom properties first, then font-size, then the rest *)
      List.iter (fun d ->
          if String.length d.name > 2 && String.sub d.name 0 2 = "--" then
            s.custom <- (d.name, d.value) :: List.remove_assoc d.name s.custom) decls;
      let value d =
        if has_var d.value then substitute s.custom 0 d.value else Some d.value in
      let keyword v = match List.filter (fun c -> c <> Tok Whitespace) v with
        | [ Tok (Ident k) ] -> (match String.lowercase_ascii k with
            | ("inherit" | "initial" | "unset" | "revert" | "revert-layer") as k -> Some k | _ -> None)
        | _ -> None in
      let reset d k =
        (* inherit: the parent's value; initial, unset: a fresh style's *)
        let src = match k with "inherit" -> parent | _ -> initial () in
        let src = match k with
          | ("unset" | "revert" | "revert-layer") ->
            (* an inherited property takes its parent's value *)
            if List.mem d.name [ "color"; "font-size"; "font-weight"; "font-style"; "font-family"; "line-height";
                                 "text-align"; "text-indent"; "white-space"; "visibility"; "list-style-type";
                                 "text-transform" ] then parent else src
          | _ -> src in
        match d.name with
        | "display" -> s.display <- src.display
        | "color" -> s.color <- src.color
        | "background" -> s.background <- src.background; s.bg <- copy_layer src.bg
        | "background-color" -> s.background <- src.background
        | "background-image" | "background-repeat" | "background-position" | "background-size" ->
          s.bg <- copy_layer src.bg
        | "mask" | "mask-image" | "-webkit-mask" | "-webkit-mask-image" ->
          s.masked <- src.masked; s.mask <- copy_layer src.mask
        | "font-size" -> s.font_size <- src.font_size
        | "font-weight" -> s.font_weight <- src.font_weight
        | "font-style" -> s.italic <- src.italic
        | "line-height" -> s.line_height <- src.line_height
        | "text-align" -> s.text_align <- src.text_align
        | "white-space" -> s.white_space <- src.white_space
        | "visibility" -> s.visible <- src.visible
        | "text-decoration" | "text-decoration-line" ->
          s.underline <- src.underline; s.line_through <- src.line_through
        | "margin" -> s.margin <- Array.copy src.margin
        | "padding" -> s.padding <- Array.copy src.padding
        | "width" -> s.width <- src.width
        | "height" -> s.height <- src.height
        | "max-width" -> s.max_width <- src.max_width
        | "position" -> s.position <- src.position
        | "vertical-align" -> s.vertical_align <- src.vertical_align
        | "float" -> s.float_ <- src.float_
        | "overflow" -> s.overflow_clip <- src.overflow_clip; s.overflow_bfc <- src.overflow_bfc
        | _ -> () in
      List.iter (fun d ->
          if d.name = "font-size" || d.name = "font" then
            match keyword d.value with
            | Some k -> reset d k
            | None -> Option.iter (fun v -> apply ctx0 s parent d.name v) (value d)) decls;
      let ctx = { ctx0 with fs = s.font_size } in
      if is_root then root_fs := s.font_size;
      List.iter (fun d ->
          if d.name <> "font-size" && d.name <> "font" && not (String.length d.name > 2 && String.sub d.name 0 2 = "--") then
            match keyword d.value with
            | Some k -> reset d k
            | None -> Option.iter (fun v -> apply ctx s parent d.name v) (value d)) decls;
      s in
  let enter (n : Dom.node) =
    match n.kind with
    | Element _ ->
      let parent = List.hd !stack in
      let decls = declarations_for ~filter ix n in
      let is_root = match n.parent with Some { kind = Document _; _ } -> true | _ -> false in
      let s = cascade ~is_root parent decls in
      Hashtbl.replace table n.id s;
      (* its ::before and ::after *)
      if has_pseudo && s.display <> None_ then
        List.iter (fun which ->
            match declarations_for ~filter ~pseudo:which pix n with
            | [] -> ()
            | pdecls ->
              let ps = cascade ~is_root:false s pdecls in
              match Option.bind ps.content (content_text n) with
              | Some text when ps.display <> None_ -> Hashtbl.replace pseudos (n.id, which) (ps, text)
              | _ -> ()) [ "before"; "after" ];
      stack := s :: !stack;
      filter_add filter n 1;
      s.display <> None_
    | Document _ | Fragment -> true
    | _ -> false in
  let leave (n : Dom.node) =
    match n.kind with
    | Element _ -> stack := List.tl !stack; filter_add filter n (-1)
    | _ -> () in
  Dom.walk ~enter ~leave doc;
  { table; pseudos; root = root_style }

(* ---- the style sheets of a document: <style> and <link rel=stylesheet> ---- *)

type source = Inline_sheet of string * string option | Linked of string * string option

let sources (doc : Dom.node) =
  let out = ref [] in
  Dom.iter (fun n ->
      if Dom.is_html n "style" then
        out := Inline_sheet (Dom.text_content n, Dom.attr n "media") :: !out
      else if Dom.is_html n "link" then
        match Dom.attr n "rel", Dom.attr n "href" with
        | Some rel, Some href ->
          let rels = String.split_on_char ' ' (String.lowercase_ascii rel) in
          if List.mem "stylesheet" rels && not (List.mem "alternate" rels) && Dom.attr n "disabled" = None then
            out := Linked (href, Dom.attr n "media") :: !out
        | _ -> ()) doc;
  List.rev !out
