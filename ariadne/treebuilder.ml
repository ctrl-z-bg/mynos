(* The HTML Standard's tree construction (13.2.6): every insertion mode,
   the adoption agency, foster parenting, templates, foreign content (SVG
   and MathML), fragments. Scripting is off: no script runs while the page
   is parsed (Ariadne has no JavaScript yet), so <noscript> is parsed as
   markup. Parse errors are not reported. *)

open Tokenizer

type mode =
  | Initial | Before_html | Before_head | In_head | In_head_noscript | After_head
  | In_body | Text_mode | In_table | In_table_text | In_caption | In_column_group
  | In_table_body | In_row | In_cell | In_template
  | After_body | In_frameset | After_frameset | After_after_body | After_after_frameset

(* an entry of the list of active formatting elements: the element, and the
   token it was made for (its name and attributes) *)
type fmt = Marker | Fmt of Dom.node * string * (string * string) list

type p = {
  tok : Tokenizer.t;
  doc : Dom.node;
  mutable mode : mode;
  mutable original : mode;
  stack : Dom.node Dynarray.t;            (* the open elements, the bottom first *)
  counts : (string, int) Hashtbl.t;        (* open HTML elements by name *)
  fmt : fmt Dynarray.t;                    (* active formatting elements *)
  mutable templates : mode list;           (* the stack of template insertion modes *)
  mutable head : Dom.node option;
  mutable form : Dom.node option;
  mutable frameset_ok : bool;
  mutable foster : bool;
  pending : Buffer.t;                      (* in table text *)
  mutable context : Dom.node option;       (* the fragment case *)
  mutable skip_lf : bool;                  (* after <pre>, <listing>, <textarea> *)
  mutable stopped : bool;
}

(* ---- the stack of open elements ---- *)

let count p name = Option.value (Hashtbl.find_opt p.counts name) ~default:0
let counted p (n : Dom.node) d =
  match n.kind with
  | Element { ns = Html; name; _ } -> Hashtbl.replace p.counts name (count p name + d)
  | _ -> ()

let push p n = Dynarray.add_last p.stack n; counted p n 1
let pop p = match Dynarray.pop_last_opt p.stack with Some n -> counted p n (-1) | None -> ()
let depth p = Dynarray.length p.stack
let nth p i = Dynarray.get p.stack i
let current p = Dynarray.get_last p.stack
let current_opt p = if depth p = 0 then None else Some (current p)

let index_of p n =
  let rec go i = if i < 0 then None else if nth p i == n then Some i else go (i - 1) in
  go (depth p - 1)

let on_stack p n = index_of p n <> None

let remove_from_stack p n =
  match index_of p n with
  | None -> ()
  | Some i ->
    let rest = List.init (depth p - i - 1) (fun k -> nth p (i + 1 + k)) in
    Dynarray.truncate p.stack i;
    counted p n (-1);
    List.iter (fun x -> Dynarray.add_last p.stack x) rest

let insert_in_stack_after p after n =
  match index_of p after with
  | None -> ()
  | Some i ->
    let rest = List.init (depth p - i - 1) (fun k -> nth p (i + 1 + k)) in
    Dynarray.truncate p.stack (i + 1);
    Dynarray.add_last p.stack n; counted p n 1;
    List.iter (fun x -> Dynarray.add_last p.stack x) rest

let replace_in_stack p old n =
  match index_of p old with
  | Some i -> Dynarray.set p.stack i n; counted p old (-1); counted p n 1
  | None -> ()

let is p n name = Dom.is_html n name
let is_one p n names = match n.Dom.kind with
  | Element { ns = Html; name; _ } -> List.mem name names | _ -> false
let _ = is

let current_is p name = depth p > 0 && Dom.is_html (current p) name
let current_is_one p names = depth p > 0 && is_one p (current p) names

let pop_until p names =
  let rec go () =
    if depth p > 0 then begin
      let n = current p in
      pop p;
      if not (is_one p n names) then go ()
    end in
  go ()

let pop_until_node p n =
  let rec go () = if depth p > 0 then (let c = current p in pop p; if c != n then go ()) in
  go ()

let has_template p = count p "template" > 0

(* ---- categories ---- *)

let special_html = [
  "address"; "applet"; "area"; "article"; "aside"; "base"; "basefont"; "bgsound";
  "blockquote"; "body"; "br"; "button"; "caption"; "center"; "col"; "colgroup"; "dd";
  "details"; "dir"; "div"; "dl"; "dt"; "embed"; "fieldset"; "figcaption"; "figure";
  "footer"; "form"; "frame"; "frameset"; "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "head";
  "header"; "hgroup"; "hr"; "html"; "iframe"; "img"; "input"; "keygen"; "li"; "link";
  "listing"; "main"; "marquee"; "menu"; "meta"; "nav"; "noembed"; "noframes"; "noscript";
  "object"; "ol"; "p"; "param"; "plaintext"; "pre"; "script"; "search"; "section"; "select";
  "source"; "style"; "summary"; "table"; "tbody"; "td"; "template"; "textarea"; "tfoot";
  "th"; "thead"; "title"; "tr"; "track"; "ul"; "wbr"; "xmp" ]

let is_special (n : Dom.node) =
  match n.kind with
  | Element { ns = Html; name; _ } -> List.mem name special_html
  | Element { ns = Mathml; name; _ } -> List.mem name [ "mi"; "mo"; "mn"; "ms"; "mtext"; "annotation-xml" ]
  | Element { ns = Svg; name; _ } -> List.mem name [ "foreignObject"; "desc"; "title" ]
  | _ -> false

let is_mathml_text_ip (n : Dom.node) =
  match n.kind with
  | Element { ns = Mathml; name; _ } -> List.mem name [ "mi"; "mo"; "mn"; "ms"; "mtext" ]
  | _ -> false

let is_html_ip (n : Dom.node) =
  match n.kind with
  | Element { ns = Mathml; name = "annotation-xml"; _ } ->
    (match Dom.attr n "encoding" with
     | Some e -> let e = String.lowercase_ascii e in e = "text/html" || e = "application/xhtml+xml"
     | None -> false)
  | Element { ns = Svg; name; _ } -> List.mem name [ "foreignObject"; "desc"; "title" ]
  | _ -> false

(* ---- scopes ---- *)

let default_scope (n : Dom.node) =
  match n.kind with
  | Element { ns = Html; name; _ } ->
    List.mem name [ "applet"; "caption"; "html"; "table"; "td"; "th"; "marquee"; "object"; "select";
                    "template" ]
  | Element { ns = Mathml; name; _ } -> List.mem name [ "mi"; "mo"; "mn"; "ms"; "mtext"; "annotation-xml" ]
  | Element { ns = Svg; name; _ } -> List.mem name [ "foreignObject"; "desc"; "title" ]
  | _ -> false

type scope = Default | List_item | Button | Table

let boundary kind (n : Dom.node) =
  match kind with
  | Default -> default_scope n
  | List_item -> default_scope n || Dom.is_html n "ol" || Dom.is_html n "ul"
  | Button -> default_scope n || Dom.is_html n "button"
  | Table -> Dom.is_html n "html" || Dom.is_html n "table" || Dom.is_html n "template"

(* one of [names] (HTML elements) in scope; a name with no open element is
   never in scope, without a walk *)
let in_scope ?(kind = Default) p names =
  List.exists (fun nm -> count p nm > 0) names
  && (let rec go i =
        if i < 0 then false
        else
          let n = nth p i in
          if is_one p n names then true
          else if boundary kind n then false
          else go (i - 1) in
      go (depth p - 1))

let node_in_scope p target =
  let rec go i =
    if i < 0 then false
    else
      let n = nth p i in
      if n == target then true else if default_scope n then false else go (i - 1) in
  go (depth p - 1)

(* ---- creating and inserting ---- *)

let svg_tags = [
  "altglyph", "altGlyph"; "altglyphdef", "altGlyphDef"; "altglyphitem", "altGlyphItem";
  "animatecolor", "animateColor"; "animatemotion", "animateMotion";
  "animatetransform", "animateTransform"; "clippath", "clipPath"; "feblend", "feBlend";
  "fecolormatrix", "feColorMatrix"; "fecomponenttransfer", "feComponentTransfer";
  "fecomposite", "feComposite"; "feconvolvematrix", "feConvolveMatrix";
  "fediffuselighting", "feDiffuseLighting"; "fedisplacementmap", "feDisplacementMap";
  "fedistantlight", "feDistantLight"; "fedropshadow", "feDropShadow"; "feflood", "feFlood";
  "fefunca", "feFuncA"; "fefuncb", "feFuncB"; "fefuncg", "feFuncG"; "fefuncr", "feFuncR";
  "fegaussianblur", "feGaussianBlur"; "feimage", "feImage"; "femerge", "feMerge";
  "femergenode", "feMergeNode"; "femorphology", "feMorphology"; "feoffset", "feOffset";
  "fepointlight", "fePointLight"; "fespecularlighting", "feSpecularLighting";
  "fespotlight", "feSpotLight"; "fetile", "feTile"; "feturbulence", "feTurbulence";
  "foreignobject", "foreignObject"; "glyphref", "glyphRef"; "lineargradient", "linearGradient";
  "radialgradient", "radialGradient"; "textpath", "textPath" ]

let svg_attrs = [
  "attributename", "attributeName"; "attributetype", "attributeType";
  "basefrequency", "baseFrequency"; "baseprofile", "baseProfile"; "calcmode", "calcMode";
  "clippathunits", "clipPathUnits"; "diffuseconstant", "diffuseConstant";
  "edgemode", "edgeMode"; "filterunits", "filterUnits"; "glyphref", "glyphRef";
  "gradienttransform", "gradientTransform"; "gradientunits", "gradientUnits";
  "kernelmatrix", "kernelMatrix"; "kernelunitlength", "kernelUnitLength";
  "keypoints", "keyPoints"; "keysplines", "keySplines"; "keytimes", "keyTimes";
  "lengthadjust", "lengthAdjust"; "limitingconeangle", "limitingConeAngle";
  "markerheight", "markerHeight"; "markerunits", "markerUnits"; "markerwidth", "markerWidth";
  "maskcontentunits", "maskContentUnits"; "maskunits", "maskUnits"; "numoctaves", "numOctaves";
  "pathlength", "pathLength"; "patterncontentunits", "patternContentUnits";
  "patterntransform", "patternTransform"; "patternunits", "patternUnits";
  "pointsatx", "pointsAtX"; "pointsaty", "pointsAtY"; "pointsatz", "pointsAtZ";
  "preservealpha", "preserveAlpha"; "preserveaspectratio", "preserveAspectRatio";
  "primitiveunits", "primitiveUnits"; "refx", "refX"; "refy", "refY";
  "repeatcount", "repeatCount"; "repeatdur", "repeatDur";
  "requiredextensions", "requiredExtensions"; "requiredfeatures", "requiredFeatures";
  "specularconstant", "specularConstant"; "specularexponent", "specularExponent";
  "spreadmethod", "spreadMethod"; "startoffset", "startOffset"; "stddeviation", "stdDeviation";
  "stitchtiles", "stitchTiles"; "surfacescale", "surfaceScale";
  "systemlanguage", "systemLanguage"; "tablevalues", "tableValues"; "targetx", "targetX";
  "targety", "targetY"; "textlength", "textLength"; "viewbox", "viewBox";
  "viewtarget", "viewTarget"; "xchannelselector", "xChannelSelector";
  "ychannelselector", "yChannelSelector"; "zoomandpan", "zoomAndPan" ]

let foreign_attr name =
  match name with
  | "xlink:actuate" | "xlink:arcrole" | "xlink:href" | "xlink:role" | "xlink:show"
  | "xlink:title" | "xlink:type" -> Dom.Xlink
  | "xml:lang" | "xml:space" -> Dom.Xml
  | "xmlns" | "xmlns:xlink" -> Dom.Xmlns
  | _ -> Dom.No_ns

let make_attrs ns attrs =
  List.map (fun (name, value) ->
      match ns with
      | Dom.Html -> { Dom.name; value; ans = No_ns }
      | Dom.Svg ->
        let name = Option.value (List.assoc_opt name svg_attrs) ~default:name in
        { Dom.name; value; ans = foreign_attr name }
      | Dom.Mathml ->
        let name = if name = "definitionurl" then "definitionURL" else name in
        { Dom.name; value; ans = foreign_attr name }) attrs

let create p ns name attrs =
  let e = Dom.element_with ns name (make_attrs ns attrs) in
  if ns = Dom.Html && name = "template" then Dom.set_content e (Dom.fragment ());
  ignore p;
  e

(* the appropriate place for inserting a node: a parent, and the node to
   insert before *)
let insertion_place ?override p =
  let target = match override with Some t -> t | None -> current p in
  let parent, before =
    if p.foster && is_one p target [ "table"; "tbody"; "tfoot"; "thead"; "tr" ] then begin
      let last name =
        let rec go i = if i < 0 then None else if Dom.is_html (nth p i) name then Some i else go (i - 1) in
        go (depth p - 1) in
      match last "template", last "table" with
      | Some ti, tb when (match tb with None -> true | Some tbi -> ti > tbi) -> (nth p ti, None)
      | _, None -> (nth p 0, None)
      | _, Some tbi ->
        let table = nth p tbi in
        (match table.parent with
         | Some par -> (par, Some table)
         | None -> (nth p (tbi - 1), None))
    end else (target, None) in
  match parent.Dom.kind, parent.content with
  | Element { ns = Html; name = "template"; _ }, Some c -> (c, None)
  | _ -> (parent, before)

let insert_at (parent, before) n = Dom.insert_before parent n before

let insert_element p ns name attrs =
  let e = create p ns name attrs in
  insert_at (insertion_place p) e;
  push p e;
  e

let insert_html p name attrs = insert_element p Dom.Html name attrs

(* a comment's or a processing instruction's node: they go to the same places *)
let markup_node = function
  | Comment c -> Dom.comment c
  | Pi { target; data } -> Dom.pi target data
  | _ -> invalid_arg "markup_node"

let insert_comment ?at p tok =
  let place = match at with Some n -> (n, None) | None -> insertion_place p in
  insert_at place (markup_node tok)

let insert_chars p s =
  if s <> "" then begin
    let parent, before = insertion_place p in
    match parent.kind with
    | Document _ -> ()
    | _ ->
      let prev = match before with Some b -> b.prev | None -> parent.last_child in
      match prev with
      | Some { kind = Text t; _ } -> t.data <- t.data ^ s
      | _ -> Dom.insert_before parent (Dom.text s) before
  end

(* ---- the list of active formatting elements ---- *)

let push_marker p = Dynarray.add_last p.fmt Marker

let push_fmt p e name attrs =
  (* Noah's Ark: at most three entries alike after the last marker *)
  let same = function
    | Fmt (_, n, a) -> n = name && List.length a = List.length attrs
                       && List.for_all (fun (k, v) -> List.assoc_opt k a = Some v) attrs
    | Marker -> false in
  let rec find i acc =
    if i < 0 then acc
    else match Dynarray.get p.fmt i with
      | Marker -> acc
      | entry -> find (i - 1) (if same entry then i :: acc else acc) in
  let alike = find (Dynarray.length p.fmt - 1) [] in
  if List.length alike >= 3 then begin
    let first = List.hd alike in
    let rest = List.init (Dynarray.length p.fmt - first - 1) (fun k -> Dynarray.get p.fmt (first + 1 + k)) in
    Dynarray.truncate p.fmt first;
    List.iter (Dynarray.add_last p.fmt) rest
  end;
  Dynarray.add_last p.fmt (Fmt (e, name, attrs))

let fmt_index p e =
  let rec go i = if i < 0 then None
    else match Dynarray.get p.fmt i with Fmt (x, _, _) when x == e -> Some i | _ -> go (i - 1) in
  go (Dynarray.length p.fmt - 1)

let remove_fmt p e =
  match fmt_index p e with
  | None -> ()
  | Some i ->
    let rest = List.init (Dynarray.length p.fmt - i - 1) (fun k -> Dynarray.get p.fmt (i + 1 + k)) in
    Dynarray.truncate p.fmt i;
    List.iter (Dynarray.add_last p.fmt) rest

let clear_fmt_to_marker p =
  let rec go () =
    match Dynarray.pop_last_opt p.fmt with
    | Some Marker | None -> ()
    | Some _ -> go () in
  go ()

let reconstruct p =
  let len = Dynarray.length p.fmt in
  let open_or_marker i = match Dynarray.get p.fmt i with
    | Marker -> true | Fmt (e, _, _) -> on_stack p e in
  if len > 0 && not (open_or_marker (len - 1)) then begin
    (* rewind to the entry after the last marker or open element *)
    let i = ref (len - 1) in
    while !i > 0 && not (open_or_marker (!i - 1)) do decr i done;
    for k = !i to len - 1 do
      match Dynarray.get p.fmt k with
      | Fmt (_, name, attrs) ->
        let e = insert_html p name attrs in
        Dynarray.set p.fmt k (Fmt (e, name, attrs))
      | Marker -> ()
    done
  end

(* the last formatting element named [name] after the last marker *)
let fmt_after_marker p name =
  let rec go i = if i < 0 then None
    else match Dynarray.get p.fmt i with
      | Marker -> None
      | Fmt (e, n, _) when n = name -> Some e
      | _ -> go (i - 1) in
  go (Dynarray.length p.fmt - 1)

(* ---- implied end tags ---- *)

let implied = [ "dd"; "dt"; "li"; "optgroup"; "option"; "p"; "rb"; "rp"; "rt"; "rtc" ]
let implied_thoroughly = implied @ [ "caption"; "colgroup"; "tbody"; "td"; "tfoot"; "th"; "thead"; "tr" ]

let generate_implied ?(except = "") p =
  while current_is_one p implied && not (current_is p except) do pop p done

let generate_implied_thoroughly p =
  while current_is_one p implied_thoroughly do pop p done

let close_p p =
  generate_implied ~except:"p" p;
  pop_until p [ "p" ]

let close_p_in_button_scope p = if in_scope ~kind:Button p [ "p" ] then close_p p

(* ---- the adoption agency ---- *)

let any_other_end_tag p name =
  let rec go i =
    if i >= 0 then begin
      let n = nth p i in
      if Dom.is_html n name then begin
        generate_implied ~except:name p;
        pop_until_node p n
      end else if not (is_special n) then go (i - 1)
    end in
  go (depth p - 1)

let adoption_agency p subject =
  if current_is p subject && fmt_index p (current p) = None then pop p
  else begin
    let rec outer k =
      if k < 8 then
        match fmt_after_marker p subject with
        | None -> any_other_end_tag p subject
        | Some fe ->
          if not (on_stack p fe) then remove_fmt p fe
          else if not (node_in_scope p fe) then ()
          else begin
            let fe_i = Option.get (index_of p fe) in
            (* the furthest block: the topmost special element below fe *)
            let rec fb i = if i >= depth p then None
              else if is_special (nth p i) then Some (nth p i) else fb (i + 1) in
            match fb (fe_i + 1) with
            | None ->
              pop_until_node p fe;
              remove_fmt p fe
            | Some furthest ->
              let common = nth p (fe_i - 1) in
              let bookmark = ref (Option.get (fmt_index p fe)) in
              let node = ref furthest and last = ref furthest in
              let inner = ref 0 in
              let node_i = ref (Option.get (index_of p furthest)) in
              let continue = ref true in
              while !continue do
                incr inner;
                node_i := !node_i - 1;
                node := nth p !node_i;
                if !node == fe then continue := false
                else begin
                  if !inner > 3 && fmt_index p !node <> None then begin
                    (match fmt_index p !node with
                     | Some fi -> if fi < !bookmark then decr bookmark | None -> ());
                    remove_fmt p !node
                  end;
                  match fmt_index p !node with
                  | None ->
                    remove_from_stack p !node
                  | Some fi ->
                    (match Dynarray.get p.fmt fi with
                     | Fmt (_, name, attrs) ->
                       let e = create p Dom.Html name attrs in
                       Dynarray.set p.fmt fi (Fmt (e, name, attrs));
                       replace_in_stack p !node e;
                       node := e;
                       if !last == furthest then bookmark := fi + 1;
                       insert_at (!node, None) !last;
                       last := !node
                     | Marker -> ())
                end
              done;
              insert_at (insertion_place ~override:common p) !last;
              (match Dynarray.get p.fmt (Option.get (fmt_index p fe)) with
               | Fmt (_, name, attrs) ->
                 let e = create p Dom.Html name attrs in
                 (* the furthest block's children to the new element *)
                 List.iter (fun c -> Dom.append e c) (Dom.children furthest);
                 Dom.append furthest e;
                 let fi = Option.get (fmt_index p fe) in
                 if fi < !bookmark then decr bookmark;
                 remove_fmt p fe;
                 let b = min !bookmark (Dynarray.length p.fmt) in
                 let rest = List.init (Dynarray.length p.fmt - b) (fun k -> Dynarray.get p.fmt (b + k)) in
                 Dynarray.truncate p.fmt b;
                 Dynarray.add_last p.fmt (Fmt (e, name, attrs));
                 List.iter (Dynarray.add_last p.fmt) rest;
                 remove_from_stack p fe;
                 insert_in_stack_after p furthest e
               | Marker -> ());
              outer (k + 1)
          end in
    outer 0
  end

(* ---- the insertion mode, reset ---- *)

let reset_mode p =
  let rec go i =
    let last = i = 0 in
    let node = if last then (match p.context with Some c -> c | None -> nth p i) else nth p i in
    let name = Dom.name node and html = Dom.ns node = Some Dom.Html in
    if html && (name = "td" || name = "th") && not last then In_cell
    else if html && name = "tr" then In_row
    else if html && (name = "tbody" || name = "thead" || name = "tfoot") then In_table_body
    else if html && name = "caption" then In_caption
    else if html && name = "colgroup" then In_column_group
    else if html && name = "table" then In_table
    else if html && name = "template" then (match p.templates with m :: _ -> m | [] -> In_body)
    else if html && name = "head" && not last then In_head
    else if html && name = "body" then In_body
    else if html && name = "frameset" then In_frameset
    else if html && name = "html" then (if p.head = None then Before_head else After_head)
    else if last then In_body
    else go (i - 1) in
  p.mode <- go (depth p - 1)

(* ---- quirks ---- *)

let quirky_prefixes = List.map String.lowercase_ascii [
  "+//Silmaril//dtd html Pro v0r11 19970101//"; "-//AS//DTD HTML 3.0 asWedit + extensions//";
  "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//"; "-//IETF//DTD HTML 2.0 Level 1//";
  "-//IETF//DTD HTML 2.0 Level 2//"; "-//IETF//DTD HTML 2.0 Strict Level 1//";
  "-//IETF//DTD HTML 2.0 Strict Level 2//"; "-//IETF//DTD HTML 2.0 Strict//";
  "-//IETF//DTD HTML 2.0//"; "-//IETF//DTD HTML 2.1E//"; "-//IETF//DTD HTML 3.0//";
  "-//IETF//DTD HTML 3.2 Final//"; "-//IETF//DTD HTML 3.2//"; "-//IETF//DTD HTML 3//";
  "-//IETF//DTD HTML Level 0//"; "-//IETF//DTD HTML Level 1//"; "-//IETF//DTD HTML Level 2//";
  "-//IETF//DTD HTML Level 3//"; "-//IETF//DTD HTML Strict Level 0//";
  "-//IETF//DTD HTML Strict Level 1//"; "-//IETF//DTD HTML Strict Level 2//";
  "-//IETF//DTD HTML Strict Level 3//"; "-//IETF//DTD HTML Strict//"; "-//IETF//DTD HTML//";
  "-//Metrius//DTD Metrius Presentational//";
  "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//";
  "-//Microsoft//DTD Internet Explorer 2.0 HTML//";
  "-//Microsoft//DTD Internet Explorer 2.0 Tables//";
  "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//";
  "-//Microsoft//DTD Internet Explorer 3.0 HTML//";
  "-//Microsoft//DTD Internet Explorer 3.0 Tables//"; "-//Netscape Comm. Corp.//DTD HTML//";
  "-//Netscape Comm. Corp.//DTD Strict HTML//"; "-//O'Reilly and Associates//DTD HTML 2.0//";
  "-//O'Reilly and Associates//DTD HTML Extended 1.0//";
  "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//";
  "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//";
  "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//";
  "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//";
  "-//Spyglass//DTD HTML 2.0 Extended//"; "-//Sun Microsystems Corp.//DTD HotJava HTML//";
  "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//"; "-//W3C//DTD HTML 3 1995-03-24//";
  "-//W3C//DTD HTML 3.2 Draft//"; "-//W3C//DTD HTML 3.2 Final//"; "-//W3C//DTD HTML 3.2//";
  "-//W3C//DTD HTML 3.2S Draft//"; "-//W3C//DTD HTML 4.0 Frameset//";
  "-//W3C//DTD HTML 4.0 Transitional//"; "-//W3C//DTD HTML Experimental 19960712//";
  "-//W3C//DTD HTML Experimental 970421//"; "-//W3C//DTD W3 HTML//";
  "-//W3O//DTD W3 HTML 3.0//"; "-//WebTechs//DTD Mozilla HTML 2.0//";
  "-//WebTechs//DTD Mozilla HTML//" ]

let quirks_of ~name ~public ~system ~force =
  let pub = Option.map String.lowercase_ascii public in
  let sys = Option.map String.lowercase_ascii system in
  let starts pre = match pub with Some s -> String.starts_with ~prefix:pre s | None -> false in
  if force || name <> Some "html"
     || pub = Some "-//w3o//dtd w3 html strict 3.0//en//"
     || pub = Some "-/w3c/dtd html 4.0 transitional/en" || pub = Some "html"
     || sys = Some "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"
     || List.exists starts quirky_prefixes
     || (sys = None && (starts "-//w3c//dtd html 4.01 frameset//" || starts "-//w3c//dtd html 4.01 transitional//"))
  then Dom.Quirks
  else if starts "-//w3c//dtd xhtml 1.0 frameset//" || starts "-//w3c//dtd xhtml 1.0 transitional//"
          || (sys <> None && (starts "-//w3c//dtd html 4.01 frameset//" || starts "-//w3c//dtd html 4.01 transitional//"))
  then Dom.Limited_quirks
  else Dom.No_quirks

let quirks p = match p.doc.kind with Document { quirks; _ } -> quirks | _ -> Dom.No_quirks

(* ---- characters ---- *)

let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\012' || c = '\r'
let all_ws s = String.for_all is_ws s

(* the leading whitespace, and the rest *)
let split_ws s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && is_ws s.[!i] do incr i done;
  (String.sub s 0 !i, String.sub s !i (n - !i))

let without_nul s = if String.contains s '\000' then String.concat "" (String.split_on_char '\000' s) else s

let generic_text p name attrs st =
  ignore (insert_html p name attrs);
  Tokenizer.set_state p.tok st;
  p.original <- p.mode;
  p.mode <- Text_mode

(* "parsing template contents": a template on the stack, or a template as
   the fragment's context *)
let parsing_template p =
  has_template p || (match p.context with Some c -> Dom.is_html c "template" | None -> false)

(* the fragment case, inside a select *)
let in_select_fragment p = match p.context with Some c -> Dom.is_html c "select" | None -> false

let adjusted_current p =
  match p.context with
  | Some c when depth p = 1 -> Some c
  | _ -> current_opt p

(* ---- the insertion modes ---- *)

let rec process p tok =
  (* the dispatcher: HTML rules, or foreign content's *)
  let html_rules =
    match adjusted_current p with
    | None -> true
    | Some n ->
      Dom.ns n = Some Dom.Html
      || (is_mathml_text_ip n && (match tok with
          | Start_tag { name; _ } -> name <> "mglyph" && name <> "malignmark"
          | Chars _ -> true | _ -> false))
      || (Dom.ns n = Some Dom.Mathml && Dom.name n = "annotation-xml"
          && (match tok with Start_tag { name = "svg"; _ } -> true | _ -> false))
      || (is_html_ip n && (match tok with Start_tag _ | Chars _ -> true | _ -> false))
      || tok = Eof in
  if html_rules then in_mode p p.mode tok else foreign p tok

and in_mode p mode tok =
  match mode with
  | Initial -> initial p tok
  | Before_html -> before_html p tok
  | Before_head -> before_head p tok
  | In_head -> in_head p tok
  | In_head_noscript -> in_head_noscript p tok
  | After_head -> after_head p tok
  | In_body -> in_body p tok
  | Text_mode -> text_mode p tok
  | In_table -> in_table p tok
  | In_table_text -> in_table_text p tok
  | In_caption -> in_caption p tok
  | In_column_group -> in_column_group p tok
  | In_table_body -> in_table_body p tok
  | In_row -> in_row p tok
  | In_cell -> in_cell p tok
  | In_template -> in_template p tok
  | After_body -> after_body p tok
  | In_frameset -> in_frameset p tok
  | After_frameset -> after_frameset p tok
  | After_after_body -> after_after_body p tok
  | After_after_frameset -> after_after_frameset p tok

and initial p tok =
  match tok with
  | Chars s ->
    let _, rest = split_ws s in
    if rest <> "" then (Dom.set_quirks p.doc Dom.Quirks; p.mode <- Before_html; process p (Chars rest))
  | (Comment _ | Pi _) as t -> Dom.append p.doc (markup_node t)
  | Doctype { name; public_id; system_id; force_quirks } ->
    Dom.append p.doc (Dom.doctype ?public_id ?system_id (Option.value name ~default:""));
    Dom.set_quirks p.doc (quirks_of ~name ~public:public_id ~system:system_id ~force:force_quirks);
    p.mode <- Before_html
  | _ ->
    Dom.set_quirks p.doc Dom.Quirks;
    p.mode <- Before_html; process p tok

and before_html p tok =
  let anything_else ?(tok = tok) () =
    let e = create p Dom.Html "html" [] in
    Dom.append p.doc e; push p e;
    p.mode <- Before_head; process p tok in
  match tok with
  | Doctype _ -> ()
  | (Comment _ | Pi _) as t -> Dom.append p.doc (markup_node t)
  | Chars s ->
    let _, rest = split_ws s in
    if rest <> "" then anything_else ~tok:(Chars rest) ()
  | Start_tag { name = "html"; attrs; _ } ->
    let e = create p Dom.Html "html" attrs in
    Dom.append p.doc e; push p e; p.mode <- Before_head
  | End_tag ("head" | "body" | "html" | "br") -> anything_else ()
  | End_tag _ -> ()
  | _ -> anything_else ()

and before_head p tok =
  let anything_else ?(tok = tok) () =
    p.head <- Some (insert_html p "head" []);
    p.mode <- In_head; process p tok in
  match tok with
  | Chars s ->
    let _, rest = split_ws s in
    if rest <> "" then anything_else ~tok:(Chars rest) ()
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | Start_tag { name = "head"; attrs; _ } ->
    p.head <- Some (insert_html p "head" attrs); p.mode <- In_head
  | End_tag ("head" | "body" | "html" | "br") -> anything_else ()
  | End_tag _ -> ()
  | _ -> anything_else ()

and in_head p tok =
  let anything_else () = pop p; p.mode <- After_head; process p tok in
  match tok with
  | Chars s ->
    let ws, rest = split_ws s in
    insert_chars p ws;
    if rest <> "" then (pop p; p.mode <- After_head; process p (Chars rest))
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | Start_tag { name = ("base" | "basefont" | "bgsound" | "link" | "meta") as name; attrs; _ } ->
    ignore (insert_html p name attrs); pop p
  | Start_tag { name = "title"; attrs; _ } -> generic_text p "title" attrs Rcdata
  | Start_tag { name = ("noframes" | "style") as name; attrs; _ } -> generic_text p name attrs Rawtext
  | Start_tag { name = "noscript"; attrs; _ } ->
    ignore (insert_html p "noscript" attrs); p.mode <- In_head_noscript
  | Start_tag { name = "script"; attrs; _ } -> generic_text p "script" attrs Script_data
  | End_tag "head" -> pop p; p.mode <- After_head
  | End_tag ("body" | "html" | "br") -> anything_else ()
  | Start_tag { name = "template"; attrs; _ } ->
    ignore (insert_html p "template" attrs);
    push_marker p;
    p.frameset_ok <- false;
    p.mode <- In_template;
    p.templates <- In_template :: p.templates
  | End_tag "template" ->
    if has_template p then begin
      generate_implied_thoroughly p;
      pop_until p [ "template" ];
      clear_fmt_to_marker p;
      p.templates <- (match p.templates with _ :: r -> r | [] -> []);
      reset_mode p
    end
  | Start_tag { name = "head"; _ } | End_tag _ -> ()
  | _ -> anything_else ()

and in_head_noscript p tok =
  let anything_else () = pop p; p.mode <- In_head; process p tok in
  match tok with
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | End_tag "noscript" -> pop p; p.mode <- In_head
  | Chars s ->
    let ws, rest = split_ws s in
    insert_chars p ws;
    if rest <> "" then (pop p; p.mode <- In_head; process p (Chars rest))
  | Comment _ | Pi _ | Start_tag { name = ("basefont" | "bgsound" | "link" | "meta" | "noframes" | "style"); _ } ->
    in_head p tok
  | End_tag "br" -> anything_else ()
  | Start_tag { name = ("head" | "noscript"); _ } | End_tag _ -> ()
  | _ -> anything_else ()

and after_head p tok =
  let anything_else () =
    ignore (insert_html p "body" []); p.frameset_ok <- true; p.mode <- In_body; process p tok in
  match tok with
  | Chars s ->
    let ws, rest = split_ws s in
    insert_chars p ws;
    if rest <> "" then begin
      ignore (insert_html p "body" []); p.frameset_ok <- true; p.mode <- In_body; process p (Chars rest)
    end
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | Start_tag { name = "body"; attrs; _ } ->
    ignore (insert_html p "body" attrs); p.frameset_ok <- false; p.mode <- In_body
  | Start_tag { name = "frameset"; attrs; _ } ->
    ignore (insert_html p "frameset" attrs); p.mode <- In_frameset
  | Start_tag { name = ("base" | "basefont" | "bgsound" | "link" | "meta" | "noframes" | "script"
                       | "style" | "template" | "title"); _ } ->
    (match p.head with
     | Some h -> push p h; in_head p tok; remove_from_stack p h
     | None -> in_head p tok)
  | End_tag "template" -> in_head p tok
  | End_tag ("body" | "html" | "br") -> anything_else ()
  | Start_tag { name = "head"; _ } | End_tag _ -> ()
  | _ -> anything_else ()

and body_chars p s =
  let s = without_nul s in
  if s <> "" then begin
    reconstruct p;
    insert_chars p s;
    if not (all_ws s) then p.frameset_ok <- false
  end

and in_body p tok =
  match tok with
  | Chars s -> body_chars p s
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; attrs; _ } ->
    if not (has_template p) then begin
      let top = nth p 0 in
      let have = Dom.attrs top in
      let missing = List.filter (fun (k, _) -> not (List.exists (fun (a : Dom.attr) -> a.name = k) have)) attrs in
      Dom.set_attrs top (have @ make_attrs Dom.Html missing)
    end
  | Start_tag { name = ("base" | "basefont" | "bgsound" | "link" | "meta" | "noframes" | "script"
                       | "style" | "template" | "title"); _ }
  | End_tag "template" -> in_head p tok
  | Start_tag { name = "body"; attrs; _ } ->
    if depth p >= 2 && Dom.is_html (nth p 1) "body" && not (has_template p) then begin
      p.frameset_ok <- false;
      let body = nth p 1 in
      let have = Dom.attrs body in
      let missing = List.filter (fun (k, _) -> not (List.exists (fun (a : Dom.attr) -> a.name = k) have)) attrs in
      Dom.set_attrs body (have @ make_attrs Dom.Html missing)
    end
  | Start_tag { name = "frameset"; attrs; _ } ->
    if depth p >= 2 && Dom.is_html (nth p 1) "body" && p.frameset_ok then begin
      Dom.remove (nth p 1);
      while depth p > 1 do pop p done;
      ignore (insert_html p "frameset" attrs);
      p.mode <- In_frameset
    end
  | Eof ->
    if p.templates <> [] then in_template p tok else p.stopped <- true
  | End_tag "body" ->
    if in_scope p [ "body" ] then p.mode <- After_body
  | End_tag "html" ->
    if in_scope p [ "body" ] then (p.mode <- After_body; process p tok)
  | Start_tag { name = ("address" | "article" | "aside" | "blockquote" | "center" | "details"
                       | "dialog" | "dir" | "div" | "dl" | "fieldset" | "figcaption" | "figure"
                       | "footer" | "header" | "hgroup" | "main" | "menu" | "nav" | "ol" | "p"
                       | "search" | "section" | "summary" | "ul") as name; attrs; _ } ->
    close_p_in_button_scope p;
    ignore (insert_html p name attrs)
  | Start_tag { name = ("h1" | "h2" | "h3" | "h4" | "h5" | "h6") as name; attrs; _ } ->
    close_p_in_button_scope p;
    if current_is_one p [ "h1"; "h2"; "h3"; "h4"; "h5"; "h6" ] then pop p;
    ignore (insert_html p name attrs)
  | Start_tag { name = ("pre" | "listing") as name; attrs; _ } ->
    close_p_in_button_scope p;
    ignore (insert_html p name attrs);
    p.skip_lf <- true;
    p.frameset_ok <- false
  | Start_tag { name = "form"; attrs; _ } ->
    if p.form = None || parsing_template p then begin
      close_p_in_button_scope p;
      let e = insert_html p "form" attrs in
      if not (parsing_template p) then p.form <- Some e
    end
  | Start_tag { name = ("li" | "dd" | "dt") as name; attrs; _ } ->
    p.frameset_ok <- false;
    let closes = if name = "li" then [ "li" ] else [ "dd"; "dt" ] in
    let rec loop i =
      if i >= 0 then begin
        let n = nth p i in
        match List.find_opt (fun c -> Dom.is_html n c) closes with
        | Some c -> generate_implied ~except:c p; pop_until p [ c ]
        | None ->
          if is_special n && not (is_one p n [ "address"; "div"; "p" ]) then ()
          else loop (i - 1)
      end in
    loop (depth p - 1);
    close_p_in_button_scope p;
    ignore (insert_html p name attrs)
  | Start_tag { name = "plaintext"; attrs; _ } ->
    close_p_in_button_scope p;
    ignore (insert_html p "plaintext" attrs);
    Tokenizer.set_state p.tok Plaintext
  | Start_tag { name = "button"; attrs; _ } ->
    if in_scope p [ "button" ] then begin
      generate_implied p; pop_until p [ "button" ]
    end;
    reconstruct p;
    ignore (insert_html p "button" attrs);
    p.frameset_ok <- false
  | End_tag ("address" | "article" | "aside" | "blockquote" | "button" | "center" | "details"
            | "dialog" | "dir" | "div" | "dl" | "fieldset" | "figcaption" | "figure" | "footer"
            | "header" | "hgroup" | "listing" | "main" | "menu" | "nav" | "ol" | "pre" | "search"
            | "section" | "select" | "summary" | "ul" as name) ->
    if in_scope p [ name ] then begin
      generate_implied p; pop_until p [ name ]
    end
  | End_tag "form" ->
    if not (parsing_template p) then begin
      let node = p.form in
      p.form <- None;
      match node with
      | Some n when node_in_scope p n ->
        generate_implied p;
        remove_from_stack p n
      | _ -> ()
    end else if in_scope p [ "form" ] then begin
      generate_implied p; pop_until p [ "form" ]
    end
  | End_tag "p" ->
    if not (in_scope ~kind:Button p [ "p" ]) then ignore (insert_html p "p" []);
    close_p p
  | End_tag "li" ->
    if in_scope ~kind:List_item p [ "li" ] then begin
      generate_implied ~except:"li" p; pop_until p [ "li" ]
    end
  | End_tag ("dd" | "dt" as name) ->
    if in_scope p [ name ] then begin
      generate_implied ~except:name p; pop_until p [ name ]
    end
  | End_tag ("h1" | "h2" | "h3" | "h4" | "h5" | "h6") ->
    let hs = [ "h1"; "h2"; "h3"; "h4"; "h5"; "h6" ] in
    if in_scope p hs then begin
      generate_implied p; pop_until p hs
    end
  | Start_tag { name = "a"; attrs; _ } ->
    (match fmt_after_marker p "a" with
     | Some e ->
       adoption_agency p "a";
       remove_fmt p e; remove_from_stack p e
     | None -> ());
    reconstruct p;
    let e = insert_html p "a" attrs in
    push_fmt p e "a" attrs
  | Start_tag { name = ("b" | "big" | "code" | "em" | "font" | "i" | "s" | "small" | "strike"
                       | "strong" | "tt" | "u") as name; attrs; _ } ->
    reconstruct p;
    let e = insert_html p name attrs in
    push_fmt p e name attrs
  | Start_tag { name = "nobr"; attrs; _ } ->
    reconstruct p;
    if in_scope p [ "nobr" ] then begin
      adoption_agency p "nobr"; reconstruct p
    end;
    let e = insert_html p "nobr" attrs in
    push_fmt p e "nobr" attrs
  | End_tag ("a" | "b" | "big" | "code" | "em" | "font" | "i" | "nobr" | "s" | "small" | "strike"
            | "strong" | "tt" | "u" as name) ->
    adoption_agency p name
  | Start_tag { name = ("applet" | "marquee" | "object") as name; attrs; _ } ->
    reconstruct p;
    ignore (insert_html p name attrs);
    push_marker p;
    p.frameset_ok <- false
  | End_tag ("applet" | "marquee" | "object" as name) ->
    if in_scope p [ name ] then begin
      generate_implied p; pop_until p [ name ]; clear_fmt_to_marker p
    end
  | Start_tag { name = "table"; attrs; _ } ->
    if quirks p <> Dom.Quirks then close_p_in_button_scope p;
    ignore (insert_html p "table" attrs);
    p.frameset_ok <- false;
    p.mode <- In_table
  | End_tag "br" -> in_body p (Start_tag { name = "br"; attrs = []; self_closing = false })
  | Start_tag { name = ("area" | "br" | "embed" | "img" | "keygen" | "wbr") as name; attrs; _ } ->
    reconstruct p;
    ignore (insert_html p name attrs); pop p;
    p.frameset_ok <- false
  | Start_tag { name = "input"; _ } when in_select_fragment p -> ()
  | Start_tag { name = "input"; attrs; _ } ->
    if in_scope p [ "select" ] then pop_until p [ "select" ];
    reconstruct p;
    ignore (insert_html p "input" attrs); pop p;
    (match List.assoc_opt "type" attrs with
     | Some t when String.lowercase_ascii t = "hidden" -> ()
     | _ -> p.frameset_ok <- false)
  | Start_tag { name = ("param" | "source" | "track") as name; attrs; _ } ->
    ignore (insert_html p name attrs); pop p
  | Start_tag { name = "hr"; attrs; _ } ->
    close_p_in_button_scope p;
    if in_scope p [ "select" ] then generate_implied p;
    ignore (insert_html p "hr" attrs); pop p;
    p.frameset_ok <- false
  | Start_tag { name = "image"; attrs; self_closing } ->
    in_body p (Start_tag { name = "img"; attrs; self_closing })
  | Start_tag { name = "textarea"; attrs; _ } ->
    ignore (insert_html p "textarea" attrs);
    p.skip_lf <- true;
    Tokenizer.set_state p.tok Rcdata;
    p.original <- p.mode;
    p.frameset_ok <- false;
    p.mode <- Text_mode
  | Start_tag { name = "xmp"; attrs; _ } ->
    close_p_in_button_scope p;
    reconstruct p;
    p.frameset_ok <- false;
    generic_text p "xmp" attrs Rawtext
  | Start_tag { name = "iframe"; attrs; _ } ->
    p.frameset_ok <- false;
    generic_text p "iframe" attrs Rawtext
  | Start_tag { name = "noembed"; attrs; _ } -> generic_text p "noembed" attrs Rawtext
  | Start_tag { name = "select"; attrs; _ } ->
    if in_select_fragment p then ()
    else if in_scope p [ "select" ] then pop_until p [ "select" ]
    else begin
      reconstruct p;
      ignore (insert_html p "select" attrs);
      p.frameset_ok <- false
    end
  | Start_tag { name = "option"; attrs; _ } ->
    if in_scope p [ "select" ] then generate_implied ~except:"optgroup" p
    else if current_is p "option" then pop p;
    reconstruct p;
    ignore (insert_html p "option" attrs)
  | Start_tag { name = "optgroup"; attrs; _ } ->
    if in_scope p [ "select" ] then generate_implied p
    else if current_is p "option" then pop p;
    reconstruct p;
    ignore (insert_html p "optgroup" attrs)
  | Start_tag { name = ("rb" | "rtc") as name; attrs; _ } ->
    if in_scope p [ "ruby" ] then generate_implied p;
    ignore (insert_html p name attrs)
  | Start_tag { name = ("rp" | "rt") as name; attrs; _ } ->
    if in_scope p [ "ruby" ] then generate_implied ~except:"rtc" p;
    ignore (insert_html p name attrs)
  | Start_tag { name = ("math" | "svg") as name; attrs; self_closing } ->
    reconstruct p;
    let ns = if name = "math" then Dom.Mathml else Dom.Svg in
    ignore (insert_element p ns name attrs);
    if self_closing then pop p
  | Start_tag { name = ("caption" | "col" | "colgroup" | "frame" | "head" | "tbody" | "td"
                       | "tfoot" | "th" | "thead" | "tr"); _ } -> ()
  | Start_tag { name; attrs; _ } ->
    reconstruct p;
    ignore (insert_html p name attrs)
  | End_tag name -> any_other_end_tag p name

and text_mode p tok =
  match tok with
  | Chars s -> insert_chars p s
  | Eof -> pop p; p.mode <- p.original; process p tok
  | End_tag _ -> pop p; p.mode <- p.original
  | _ -> ()

and clear_to p names = while not (current_is_one p names) do pop p done
and clear_to_table p = clear_to p [ "table"; "template"; "html" ]
and clear_to_table_body p = clear_to p [ "tbody"; "tfoot"; "thead"; "template"; "html" ]
and clear_to_row p = clear_to p [ "tr"; "template"; "html" ]

and in_table p tok =
  let anything_else () =
    p.foster <- true; in_body p tok; p.foster <- false in
  match tok with
  | Chars _ when current_is_one p [ "table"; "tbody"; "template"; "tfoot"; "thead"; "tr" ] ->
    Buffer.clear p.pending;
    p.original <- p.mode;
    p.mode <- In_table_text;
    process p tok
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "caption"; attrs; _ } ->
    clear_to_table p; push_marker p;
    ignore (insert_html p "caption" attrs); p.mode <- In_caption
  | Start_tag { name = "colgroup"; attrs; _ } ->
    clear_to_table p; ignore (insert_html p "colgroup" attrs); p.mode <- In_column_group
  | Start_tag { name = "col"; _ } ->
    clear_to_table p; ignore (insert_html p "colgroup" []); p.mode <- In_column_group; process p tok
  | Start_tag { name = ("tbody" | "tfoot" | "thead") as name; attrs; _ } ->
    clear_to_table p; ignore (insert_html p name attrs); p.mode <- In_table_body
  | Start_tag { name = ("td" | "th" | "tr"); _ } ->
    clear_to_table p; ignore (insert_html p "tbody" []); p.mode <- In_table_body; process p tok
  | Start_tag { name = "table"; _ } ->
    if in_scope ~kind:Table p [ "table" ] then begin
      pop_until p [ "table" ]; reset_mode p; process p tok
    end
  | End_tag "table" ->
    if in_scope ~kind:Table p [ "table" ] then begin
      pop_until p [ "table" ]; reset_mode p
    end
  | End_tag ("body" | "caption" | "col" | "colgroup" | "html" | "tbody" | "td" | "tfoot" | "th"
            | "thead" | "tr") -> ()
  | Start_tag { name = ("style" | "script" | "template"); _ } | End_tag "template" -> in_head p tok
  | Start_tag { name = "input"; attrs; _ }
    when (match List.assoc_opt "type" attrs with
        | Some t -> String.lowercase_ascii t = "hidden" | None -> false) ->
    ignore (insert_html p "input" attrs); pop p
  | Start_tag { name = "form"; attrs; _ } ->
    if p.form = None || parsing_template p then begin
      let e = insert_html p "form" attrs in
      if not (parsing_template p) then p.form <- Some e;
      pop p
    end
  | Eof -> in_body p tok
  | _ -> anything_else ()

and in_table_text p tok =
  match tok with
  | Chars s -> Buffer.add_string p.pending (without_nul s)
  | _ ->
    let s = Buffer.contents p.pending in
    Buffer.clear p.pending;
    if not (all_ws s) then begin
      p.foster <- true; body_chars p s; p.foster <- false
    end else insert_chars p s;
    p.mode <- p.original;
    process p tok

and in_caption p tok =
  let close () =
    generate_implied p; pop_until p [ "caption" ]; clear_fmt_to_marker p; p.mode <- In_table in
  match tok with
  | End_tag "caption" -> if in_scope ~kind:Table p [ "caption" ] then close ()
  | Start_tag { name = ("caption" | "col" | "colgroup" | "tbody" | "td" | "tfoot" | "th" | "thead"
                       | "tr"); _ }
  | End_tag "table" ->
    if in_scope ~kind:Table p [ "caption" ] then (close (); process p tok)
  | End_tag ("body" | "col" | "colgroup" | "html" | "tbody" | "td" | "tfoot" | "th" | "thead"
            | "tr") -> ()
  | _ -> in_body p tok

and in_column_group p tok =
  let anything_else ?(tok = tok) () =
    if current_is p "colgroup" then (pop p; p.mode <- In_table; process p tok) in
  match tok with
  | Chars s ->
    let ws, rest = split_ws s in
    insert_chars p ws;
    if rest <> "" then anything_else ~tok:(Chars rest) ()
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | Start_tag { name = "col"; attrs; _ } -> ignore (insert_html p "col" attrs); pop p
  | End_tag "colgroup" -> if current_is p "colgroup" then (pop p; p.mode <- In_table)
  | End_tag "col" -> ()
  | Start_tag { name = "template"; _ } | End_tag "template" -> in_head p tok
  | Eof -> in_body p tok
  | _ -> anything_else ()

and in_table_body p tok =
  match tok with
  | Start_tag { name = "tr"; attrs; _ } ->
    clear_to_table_body p; ignore (insert_html p "tr" attrs); p.mode <- In_row
  | Start_tag { name = ("th" | "td"); _ } ->
    clear_to_table_body p; ignore (insert_html p "tr" []); p.mode <- In_row; process p tok
  | End_tag ("tbody" | "tfoot" | "thead" as name) ->
    if in_scope ~kind:Table p [ name ] then begin
      clear_to_table_body p; pop p; p.mode <- In_table
    end
  | Start_tag { name = ("caption" | "col" | "colgroup" | "tbody" | "tfoot" | "thead"); _ }
  | End_tag "table" ->
    if in_scope ~kind:Table p [ "tbody"; "thead"; "tfoot" ] then begin
      clear_to_table_body p; pop p; p.mode <- In_table; process p tok
    end
  | End_tag ("body" | "caption" | "col" | "colgroup" | "html" | "td" | "th" | "tr") -> ()
  | _ -> in_table p tok

and in_row p tok =
  match tok with
  | Start_tag { name = ("th" | "td") as name; attrs; _ } ->
    clear_to_row p; ignore (insert_html p name attrs); p.mode <- In_cell; push_marker p
  | End_tag "tr" ->
    if in_scope ~kind:Table p [ "tr" ] then begin
      clear_to_row p; pop p; p.mode <- In_table_body
    end
  | Start_tag { name = ("caption" | "col" | "colgroup" | "tbody" | "tfoot" | "thead" | "tr"); _ }
  | End_tag "table" ->
    if in_scope ~kind:Table p [ "tr" ] then begin
      clear_to_row p; pop p; p.mode <- In_table_body; process p tok
    end
  | End_tag ("tbody" | "tfoot" | "thead" as name) ->
    if in_scope ~kind:Table p [ name ] && in_scope ~kind:Table p [ "tr" ] then begin
      clear_to_row p; pop p; p.mode <- In_table_body; process p tok
    end
  | End_tag ("body" | "caption" | "col" | "colgroup" | "html" | "td" | "th") -> ()
  | _ -> in_table p tok

and in_cell p tok =
  let close_cell () =
    generate_implied p; pop_until p [ "td"; "th" ]; clear_fmt_to_marker p; p.mode <- In_row in
  match tok with
  | End_tag ("td" | "th" as name) ->
    if in_scope ~kind:Table p [ name ] then begin
      generate_implied p; pop_until p [ name ]; clear_fmt_to_marker p; p.mode <- In_row
    end
  | Start_tag { name = ("caption" | "col" | "colgroup" | "tbody" | "td" | "tfoot" | "th" | "thead"
                       | "tr"); _ } ->
    if in_scope ~kind:Table p [ "td"; "th" ] then (close_cell (); process p tok)
  | End_tag ("body" | "caption" | "col" | "colgroup" | "html") -> ()
  | End_tag ("table" | "tbody" | "tfoot" | "thead" | "tr" as name) ->
    if in_scope ~kind:Table p [ name ] then (close_cell (); process p tok)
  | _ -> in_body p tok

and in_template p tok =
  let switch m = p.templates <- m :: (match p.templates with _ :: r -> r | [] -> []);
    p.mode <- m; process p tok in
  match tok with
  | Chars _ | Comment _ | Pi _ | Doctype _ -> in_body p tok
  | Start_tag { name = ("base" | "basefont" | "bgsound" | "link" | "meta" | "noframes" | "script"
                       | "style" | "template" | "title"); _ }
  | End_tag "template" -> in_head p tok
  | Start_tag { name = ("caption" | "colgroup" | "tbody" | "tfoot" | "thead"); _ } -> switch In_table
  | Start_tag { name = "col"; _ } -> switch In_column_group
  | Start_tag { name = "tr"; _ } -> switch In_table_body
  | Start_tag { name = ("td" | "th"); _ } -> switch In_row
  | Start_tag _ -> switch In_body
  | End_tag _ -> ()
  | Eof ->
    if not (has_template p) then p.stopped <- true
    else begin
      pop_until p [ "template" ];
      clear_fmt_to_marker p;
      p.templates <- (match p.templates with _ :: r -> r | [] -> []);
      reset_mode p;
      process p tok
    end

and after_body p tok =
  match tok with
  | Chars s when all_ws s -> in_body p tok
  | Chars s ->
    let ws, rest = split_ws s in
    if ws <> "" then in_body p (Chars ws);
    p.mode <- In_body; process p (Chars rest)
  | (Comment _ | Pi _) as t -> insert_comment ~at:(nth p 0) p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | End_tag "html" -> if p.context = None then p.mode <- After_after_body
  | Eof -> p.stopped <- true
  | _ -> p.mode <- In_body; process p tok

and frameset_ws s = String.concat "" (List.map (String.make 1)
                                        (List.filter is_ws (List.init (String.length s) (String.get s))))

and in_frameset p tok =
  match tok with
  | Chars s -> insert_chars p (frameset_ws s)
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | Start_tag { name = "frameset"; attrs; _ } -> ignore (insert_html p "frameset" attrs)
  | End_tag "frameset" ->
    if not (current_is p "html") then begin
      pop p;
      if p.context = None && not (current_is p "frameset") then p.mode <- After_frameset
    end
  | Start_tag { name = "frame"; attrs; _ } -> ignore (insert_html p "frame" attrs); pop p
  | Start_tag { name = "noframes"; _ } -> in_head p tok
  | Eof -> p.stopped <- true
  | _ -> ()

and after_frameset p tok =
  match tok with
  | Chars s -> insert_chars p (frameset_ws s)
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = "html"; _ } -> in_body p tok
  | End_tag "html" -> p.mode <- After_after_frameset
  | Start_tag { name = "noframes"; _ } -> in_head p tok
  | Eof -> p.stopped <- true
  | _ -> ()

and after_after_body p tok =
  match tok with
  | (Comment _ | Pi _) as t -> Dom.append p.doc (markup_node t)
  | Doctype _ | Start_tag { name = "html"; _ } -> in_body p tok
  | Chars s when all_ws s -> in_body p tok
  | Chars s ->
    let ws, rest = split_ws s in
    if ws <> "" then in_body p (Chars ws);
    p.mode <- In_body; process p (Chars rest)
  | Eof -> p.stopped <- true
  | _ -> p.mode <- In_body; process p tok

and after_after_frameset p tok =
  match tok with
  | (Comment _ | Pi _) as t -> Dom.append p.doc (markup_node t)
  | Doctype _ | Start_tag { name = "html"; _ } -> in_body p tok
  | Chars s -> let ws = frameset_ws s in if ws <> "" then in_body p (Chars ws)
  | Eof -> p.stopped <- true
  | Start_tag { name = "noframes"; _ } -> in_head p tok
  | _ -> ()

(* ---- foreign content ---- *)

and foreign p tok =
  let breakout () =
    let rec go () =
      if depth p > 0 then begin
        let n = current p in
        if not (is_mathml_text_ip n || is_html_ip n || Dom.ns n = Some Dom.Html) then (pop p; go ())
      end in
    go ();
    in_mode p p.mode tok in
  match tok with
  | Chars s ->
    if String.exists (fun c -> not (is_ws c) && c <> '\000') s then p.frameset_ok <- false;
    insert_chars p (String.concat replacement_utf8 (String.split_on_char '\000' s))
  | (Comment _ | Pi _) as t -> insert_comment p t
  | Doctype _ -> ()
  | Start_tag { name = ("b" | "big" | "blockquote" | "body" | "br" | "center" | "code" | "dd" | "div"
                       | "dl" | "dt" | "em" | "embed" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                       | "head" | "hr" | "i" | "img" | "li" | "listing" | "menu" | "meta" | "nobr"
                       | "ol" | "p" | "pre" | "ruby" | "s" | "small" | "span" | "strong" | "strike"
                       | "sub" | "sup" | "table" | "tt" | "u" | "ul" | "var"); _ } ->
    breakout ()
  | Start_tag { name = "font"; attrs; _ }
    when List.exists (fun (k, _) -> k = "color" || k = "face" || k = "size") attrs -> breakout ()
  | End_tag ("br" | "p") -> breakout ()
  | Start_tag { name; attrs; self_closing } ->
    let ns = match adjusted_current p with Some n -> Option.value (Dom.ns n) ~default:Dom.Html | None -> Dom.Html in
    let name = if ns = Dom.Svg then Option.value (List.assoc_opt name svg_tags) ~default:name else name in
    ignore (insert_element p ns name attrs);
    if self_closing then pop p
  | End_tag name ->
    let rec loop i =
      if i > 0 then begin
        let n = nth p i in
        if String.lowercase_ascii (Dom.name n) = name then pop_until_node p n
        else if Dom.ns (nth p (i - 1)) = Some Dom.Html then in_mode p p.mode tok
        else loop (i - 1)
      end in
    loop (depth p - 1)
  | Eof -> in_mode p p.mode tok

and replacement_utf8 = "\xEF\xBF\xBD"

(* ---- running it ---- *)

let make tok =
  { tok; doc = Dom.document (); mode = Initial; original = Initial; stack = Dynarray.create ();
    counts = Hashtbl.create 64; fmt = Dynarray.create (); templates = []; head = None; form = None;
    frameset_ok = true; foster = false; pending = Buffer.create 64; context = None;
    skip_lf = false; stopped = false }

let run p =
  let rec loop () =
    (* <![CDATA[ opens a section only in foreign content *)
    Tokenizer.set_allow_cdata p.tok
      (match adjusted_current p with Some n -> Dom.ns n <> Some Dom.Html | None -> false);
    let tok = Tokenizer.next p.tok in
    let tok =
      if p.skip_lf then begin
        p.skip_lf <- false;
        match tok with
        | Chars s when String.length s > 0 && s.[0] = '\n' -> Chars (String.sub s 1 (String.length s - 1))
        | t -> t
      end else tok in
    (match tok with Chars "" -> () | _ -> process p tok);
    if tok <> Eof && not p.stopped then loop () in
  loop ()

let parse_document text =
  let p = make (Tokenizer.create text) in
  run p;
  p.doc

(* the fragment parsing algorithm: [context] is the element whose content
   the text is (an element of its own, out of any tree) *)
let parse_fragment ~context text =
  let tok = Tokenizer.create text in
  let p = make tok in
  Dom.set_quirks p.doc Dom.No_quirks;
  p.context <- Some context;
  (match context.kind with
   | Element { ns = Html; name; _ } ->
     (match name with
      | "title" | "textarea" -> Tokenizer.set_state tok Rcdata
      | "style" | "xmp" | "iframe" | "noembed" | "noframes" -> Tokenizer.set_state tok Rawtext
      | "script" -> Tokenizer.set_state tok Script_data
      | "plaintext" -> Tokenizer.set_state tok Plaintext
      | _ -> ())
   | _ -> ());
  let root = Dom.element "html" in
  Dom.append p.doc root;
  push p root;
  if Dom.is_html context "template" then p.templates <- [ In_template ];
  reset_mode p;
  (* the form element pointer: the context's nearest form ancestor *)
  let rec form_of (n : Dom.node option) = match n with
    | Some n when Dom.is_html n "form" -> Some n
    | Some n -> form_of n.parent
    | None -> None in
  p.form <- form_of (Some context);
  run p;
  let frag = Dom.fragment () in
  List.iter (fun c -> Dom.append frag c) (Dom.children root);
  frag
