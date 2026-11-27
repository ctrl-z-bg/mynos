(* An inline <svg> element as a picture: serialized into an SVG document of
   its own, given to imaged (NanoSVG) as a data: URL, so that it goes the
   pictures' way (size, fetch, decode, cache). NanoSVG has no <use>: a
   <use href="#id"> is replaced by what it names (a <symbol>'s children,
   its viewBox the picture's when it is all there is). currentColor
   becomes the element's colour, which is the outer fill too (icons are
   drawn in the text's colour). No input or output here. *)

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

let attrs_text ~color (n : Dom.node) ~skip =
  String.concat "" (List.filter_map (fun (a : Dom.attr) ->
      if List.mem a.name skip then None
      else
        let v = if String.lowercase_ascii (String.trim a.value) = "currentcolor" then hex color else a.value in
        let name = if a.ans = Dom.Xlink && a.name = "href" then "xlink:href" else a.name in
        Some (Printf.sprintf " %s=\"%s\"" name (escape v))) (Dom.attrs n))

(* the children of [n], serialized (a loop's depth: SVG trees are small,
   but uses can chain: at most 8 deep) *)
let rec children ~color ~depth b (n : Dom.node) =
  List.iter (fun c -> node ~color ~depth b c) (Dom.children n)

and node ~color ~depth b (c : Dom.node) =
  match c.kind with
  | Element { name = "use"; _ } when depth < 8 ->
    (match target c with
     | Some t ->
       let x = Option.value (Dom.attr c "x") ~default:"0" and y = Option.value (Dom.attr c "y") ~default:"0" in
       Printf.bprintf b "<g transform=\"translate(%s,%s)\"%s>" (escape x) (escape y)
         (attrs_text ~color c ~skip:[ "href"; "xlink:href"; "x"; "y"; "width"; "height" ]);
       (match t.kind with
        | Element { name = "symbol"; _ } -> children ~color ~depth:(depth + 1) b t
        | _ -> node ~color ~depth:(depth + 1) b t);
       Buffer.add_string b "</g>"
     | None -> ())
  | Element { name = ("script" | "style" | "title" | "desc" | "foreignObject" | "symbol"); _ } -> ()
  | Element { name; _ } ->
    Printf.bprintf b "<%s%s>" name (attrs_text ~color c ~skip:[]);
    children ~color ~depth b c;
    Printf.bprintf b "</%s>" name
  | Text { data } -> Buffer.add_string b (escape data)
  | _ -> ()

(* the elements (not blank text) of a node *)
let elements (n : Dom.node) =
  List.filter (fun (c : Dom.node) -> match c.kind with
      | Element _ -> true
      | Text { data } -> String.trim data <> "" | _ -> false) (Dom.children n)

(* the picture's text, [w] x [h] pixels *)
let document ~color ~w ~h (svg : Dom.node) =
  let b = Buffer.create 1024 in
  (* a lone <use> of a <symbol>: its viewBox the picture's *)
  let lone_symbol = match elements svg with
    | [ u ] when Dom.name u = "use" ->
      (match target u with Some t when Dom.name t = "symbol" -> Some t | _ -> None)
    | _ -> None in
  let view_box = match Dom.attr svg "viewBox", lone_symbol with
    | Some v, _ -> Some v
    | None, Some s -> Dom.attr s "viewBox"
    | None, None -> None in
  Printf.bprintf b "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\"%s%s%s>" w h
    (match view_box with Some v -> " viewBox=\"" ^ escape v ^ "\"" | None -> "")
    (if Dom.attr svg "fill" = None then " fill=\"" ^ hex color ^ "\"" else "")
    (attrs_text ~color svg ~skip:[ "width"; "height"; "viewBox"; "xmlns"; "style"; "class"; "id" ]);
  (match lone_symbol with
   | Some s -> children ~color ~depth:1 b s
   | None -> children ~color ~depth:0 b svg);
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

let data_url ~color ~w ~h svg = "data:image/svg+xml;base64," ^ base64 (document ~color ~w ~h svg)

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
