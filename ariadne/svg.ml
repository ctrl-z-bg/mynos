(* An inline <svg> element as a picture: serialized into an SVG document of
   its own, given to imaged (NanoSVG) as a data: URL, so that it goes the
   pictures' way (size, fetch, decode, cache). Its painting (fill, stroke,
   stroke-width) is the cascade's (Style: CSS rules and presentation
   attributes): the root's computed values, then each element's where it
   sets them, NanoSVG's inheritance doing the rest. NanoSVG has no <use>: a
   <use href="#id"> is replaced by what it names (a <symbol>'s children),
   which inherits from the <use> (SVG's shadow tree), currentColor too. No
   input or output here. *)

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
      | '&' -> Buffer.add_string b "&amp;" | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;" | '"' -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c) s;
  Buffer.contents b

let hex c = Printf.sprintf "#%06x" (c land 0xFFFFFF)

let root (n : Dom.node) = let rec up (x : Dom.node) = match x.parent with Some p -> up p | None -> x in up n

let href (n : Dom.node) =
  match Dom.attr n "href" with
  | Some h -> Some h
  | None ->
    (* xlink:href: its name as the parser keeps it *)
    List.find_map (fun (a : Dom.attr) -> if a.name = "xlink:href" || (a.name = "href" && a.ans = Dom.Xlink) then Some a.value else None)
      (Dom.attrs n)

let target (n : Dom.node) =
  match href n with
  | Some h when String.length h > 1 && h.[0] = '#' ->
    let id = String.sub h 1 (String.length h - 1) in
    Dom.find (fun x -> Dom.attr x "id" = Some id) (root n)
  | _ -> None

(* a paint as SVG writes it; currentColor: [color] (the colour in this
   tree: the use's, through a <use>) *)
let paint ~color (p : Style.paint) = match p with
  | Style.Paint_none -> "none"
  | Paint_color c -> hex c
  | Paint_current -> hex color

let opacity_attrs name (p : Style.paint) = match p with
  | Style.Paint_color c when c lsr 24 < 255 -> Printf.sprintf " %s-opacity=\"%.3f\"" name (float (c lsr 24) /. 255.)
  | _ -> ""

(* the painting properties: written where the element sets them (or all,
   for the picture's root), the rest NanoSVG's inheritance *)
let paint_attrs ?(all = false) ~color (st : Style.t) =
  let b = Buffer.create 64 in
  let px l = match l with Style.Len (p, _) -> p | Auto -> 1. in
  if all || st.svg_set land 1 <> 0 then
    Printf.bprintf b " fill=\"%s\"%s" (paint ~color st.fill) (opacity_attrs "fill" st.fill);
  if all || st.svg_set land 2 <> 0 then
    Printf.bprintf b " stroke=\"%s\"%s" (paint ~color st.stroke) (opacity_attrs "stroke" st.stroke);
  if all || st.svg_set land 4 <> 0 then Printf.bprintf b " stroke-width=\"%g\"" (px st.stroke_width);
  Buffer.contents b

let painting = [ "fill"; "stroke"; "stroke-width"; "color"; "style"; "class"; "id" ]

(* the attributes the element keeps: all but those its style gives (when
   it has one: the cascade, presentation attributes included); currentColor
   as [color] *)
let attrs_text ~color ~styled (n : Dom.node) ~skip =
  String.concat "" (List.filter_map (fun (a : Dom.attr) ->
      if List.mem a.name skip || (styled && List.mem a.name painting) then None
      else
        let v = if String.lowercase_ascii (String.trim a.value) = "currentcolor" then hex color else a.value in
        let name = if a.ans = Dom.Xlink && a.name = "href" then "xlink:href" else a.name in
        Some (Printf.sprintf " %s=\"%s\"" name (escape v))) (Dom.attrs n))

(* an element's colour in this tree: its own if it sets one, else [ctx] *)
let color_of styles ~ctx (n : Dom.node) =
  match Style.get styles n with
  | Some st when st.svg_set land 8 <> 0 -> st.color
  | _ -> ctx

(* the children of [n], serialized (uses can chain: at most 8 deep) *)
let rec children styles ~color ~depth b (n : Dom.node) =
  List.iter (fun c -> node styles ~color ~depth b c) (Dom.children n)

and node styles ~color ~depth b (c : Dom.node) =
  match c.kind with
  | Element { name = "use"; _ } when depth < 8 ->
    (match target c with
     | Some t ->
       (* the content inherits from the <use> (SVG's shadow tree) *)
       let ucolor = color_of styles ~ctx:color c in
       let x = Option.value (Dom.attr c "x") ~default:"0" and y = Option.value (Dom.attr c "y") ~default:"0" in
       let st = Style.get styles c in
       Printf.bprintf b "<g transform=\"translate(%s,%s)\"%s%s>" (escape x) (escape y)
         (match st with Some st -> paint_attrs ~color:ucolor st | None -> "")
         (attrs_text ~color:ucolor ~styled:(st <> None) c ~skip:[ "href"; "xlink:href"; "x"; "y"; "width"; "height" ]);
       (match t.kind with
        | Element { name = "symbol"; _ } -> children styles ~color:ucolor ~depth:(depth + 1) b t
        | _ -> node styles ~color:ucolor ~depth:(depth + 1) b t);
       Buffer.add_string b "</g>"
     | None -> ())
  | Element { name = ("script" | "style" | "title" | "desc" | "foreignObject" | "symbol"); _ } -> ()
  | Element { name; _ } ->
    let color = color_of styles ~ctx:color c in
    let st = Style.get styles c in
    Printf.bprintf b "<%s%s%s>" name
      (match st with Some st -> paint_attrs ~color st | None -> "")
      (attrs_text ~color ~styled:(st <> None) c ~skip:[]);
    children styles ~color ~depth b c;
    Printf.bprintf b "</%s>" name
  | Text { data } -> Buffer.add_string b (escape data)
  | _ -> ()

(* the elements (not blank text) of a node *)
let elements (n : Dom.node) =
  List.filter (fun (c : Dom.node) -> match c.kind with
      | Element _ -> true
      | Text { data } -> String.trim data <> "" | _ -> false) (Dom.children n)

(* the picture's text, [w] x [h] pixels *)
let document styles ~w ~h (svg : Dom.node) =
  let b = Buffer.create 1024 in
  let st = Style.get styles svg in
  let color = match st with Some st -> st.color | None -> 0 in
  (* a lone <use> of a <symbol>: its viewBox the picture's *)
  let lone_symbol = match elements svg with
    | [ u ] when Dom.name u = "use" ->
      (match target u with Some t when Dom.name t = "symbol" -> Some (u, t) | _ -> None)
    | _ -> None in
  let view_box = match Dom.attr svg "viewBox", lone_symbol with
    | Some v, _ -> Some v
    | None, Some (_, s) -> Dom.attr s "viewBox"
    | None, None -> None in
  Printf.bprintf b "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\"%s%s%s>" w h
    (match view_box with Some v -> " viewBox=\"" ^ escape v ^ "\"" | None -> "")
    (match st with Some st -> paint_attrs ~all:true ~color st | None -> "")
    (attrs_text ~color ~styled:(st <> None) svg ~skip:[ "width"; "height"; "viewBox"; "xmlns" ]);
  (match lone_symbol with
   | Some (u, s) ->
     (* the use's own painting, then the symbol's content *)
     let ucolor = color_of styles ~ctx:color u in
     Printf.bprintf b "<g%s>" (match Style.get styles u with Some us -> paint_attrs ~color:ucolor us | None -> "");
     children styles ~color:ucolor ~depth:1 b s;
     Buffer.add_string b "</g>"
   | None -> children styles ~color ~depth:0 b svg);
  Buffer.add_string b "</svg>";
  Buffer.contents b

let base64 s =
  let t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let b = Buffer.create (String.length s * 4 / 3 + 4) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c k = if !i + k < n then Char.code s.[!i + k] else 0 in
    let v = (c 0 lsl 16) lor (c 1 lsl 8) lor c 2 in
    Buffer.add_char b t.[(v lsr 18) land 63];
    Buffer.add_char b t.[(v lsr 12) land 63];
    Buffer.add_char b (if !i + 1 < n then t.[(v lsr 6) land 63] else '=');
    Buffer.add_char b (if !i + 2 < n then t.[v land 63] else '=');
    i := !i + 3
  done;
  Buffer.contents b

let data_url styles ~w ~h svg = "data:image/svg+xml;base64," ^ base64 (document styles ~w ~h svg)

(* its ratio (height / width): the viewBox's, or a lone symbol's *)
let ratio (svg : Dom.node) =
  let vb = match Dom.attr svg "viewBox" with
    | Some v -> Some v
    | None -> (match elements svg with
        | [ u ] when Dom.name u = "use" -> Option.bind (target u) (fun t -> Dom.attr t "viewBox")
        | _ -> None) in
  match Option.map (fun v -> List.filter_map float_of_string_opt
                       (String.split_on_char ' ' (String.map (fun c -> if c = ',' then ' ' else c) v))) vb with
  | Some [ _; _; w; h ] when w > 0. && h > 0. -> Some (h /. w)
  | _ -> None
