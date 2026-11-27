(* A page as text: see text.mli. *)

type kind = Heading of int | Paragraph | Item of int | Pre | Rule

type block = { kind : kind; text : string }

type page = { title : string; blocks : block list; links : string list }

(* not shown: what is not content, or not text *)
let skipped = [ "head"; "title"; "script"; "style"; "template"; "svg"; "math"; "select"; "datalist" ]

let blocks_of = [ "address"; "article"; "aside"; "blockquote"; "body"; "caption"; "center";
                  "dd"; "details"; "dialog"; "div"; "dl"; "dt"; "fieldset"; "figcaption";
                  "figure"; "footer"; "form"; "header"; "html"; "legend"; "main"; "menu";
                  "nav"; "ol"; "p"; "section"; "summary"; "table"; "tbody"; "tfoot";
                  "thead"; "tr"; "ul"; "noscript" ]

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012'

let collapse s =
  let b = Buffer.create (String.length s) in
  let space = ref false in
  String.iter (fun c ->
      if is_space c then space := true
      else begin
        if !space && Buffer.length b > 0 then Buffer.add_char b ' ';
        space := false; Buffer.add_char b c
      end) s;
  Buffer.contents b

let of_dom doc =
  let title = match Dom.find (fun n -> Dom.name n = "title") doc with
    | Some t -> collapse (Dom.text_content t) | None -> "" in
  let blocks = ref [] and links = ref [] in
  let buf = Buffer.create 256 in
  let space = ref false in           (* a space is due before the next word *)
  let pre = ref 0 in                 (* inside how many <pre> *)
  let depth = ref 0 in               (* inside how many lists *)
  let kinds = ref [ Paragraph ] in   (* the blocks' kinds, the innermost first *)
  let flush () =
    let t = Buffer.contents buf in
    (* no empty lines at either end *)
    let t = if !pre > 0 then t else String.trim t in
    let rec strip_nl t =
      let n = String.length t in
      if n > 0 && t.[n - 1] = '\n' then strip_nl (String.sub t 0 (n - 1)) else t in
    let t = strip_nl t in
    let t = if String.length t > 0 && t.[0] = '\n' then String.sub t 1 (String.length t - 1) else t in
    if String.trim t <> "" then blocks := { kind = List.hd !kinds; text = t } :: !blocks;
    Buffer.clear buf; space := false in
  let add_text s =
    if !pre > 0 then Buffer.add_string buf s
    else String.iter (fun c ->
        if is_space c then
          space := Buffer.length buf > 0 && Buffer.nth buf (Buffer.length buf - 1) <> '\n'
        else begin
          if !space then Buffer.add_char buf ' ';
          space := false; Buffer.add_char buf c
        end) s in
  let kind_of name = match name with
    | "h1" -> Some (Heading 1) | "h2" -> Some (Heading 2) | "h3" -> Some (Heading 3)
    | "h4" -> Some (Heading 4) | "h5" -> Some (Heading 5) | "h6" -> Some (Heading 6)
    | "li" -> Some (Item (max 1 !depth))
    | "pre" | "listing" | "plaintext" -> Some Pre
    | n when List.mem n blocks_of -> Some (match !kinds with k :: _ -> (match k with Item _ -> Paragraph | k -> k) | [] -> Paragraph)
    | _ -> None in
  let enter (n : Dom.node) =
    match n.kind with
    | Text t -> add_text t.data; false
    | Element _ when Dom.attr n "hidden" <> None -> false
    | Element _ ->
      let name = Dom.name n in
      if List.mem name skipped then false
      else begin
        (match name with
         | "br" -> Buffer.add_char buf '\n'; space := false
         | "hr" -> flush (); blocks := { kind = Rule; text = "" } :: !blocks
         | "img" ->
           (match Dom.attr n "alt" with
            | Some a when String.trim a <> "" -> add_text (" [" ^ String.trim a ^ "] ")
            | _ -> ())
         | "td" | "th" ->
           (* a cell after another: a bar between them *)
           let rec prev_cell (p : Dom.node option) = match p with
             | Some ({ kind = Element _; _ } as e) -> List.mem (Dom.name e) [ "td"; "th" ] || prev_cell e.prev
             | Some e -> prev_cell e.prev
             | None -> false in
           if prev_cell n.prev then add_text " | "
         | "a" ->
           (match Dom.attr n "href" with
            | Some h when not (List.mem h !links) -> links := h :: !links
            | _ -> ())
         | _ -> ());
        (match kind_of name with
         | Some k ->
           flush ();
           if name = "ul" || name = "ol" || name = "menu" then incr depth;
           if k = Pre then incr pre;
           kinds := k :: !kinds
         | None -> ());
        true
      end
    | _ -> true in
  let leave (n : Dom.node) =
    match n.kind with
    | Element _ ->
      let name = Dom.name n in
      (match kind_of name with
       | Some _ when not (List.mem name skipped) && Dom.attr n "hidden" = None ->
         flush ();
         if name = "ul" || name = "ol" || name = "menu" then decr depth;
         (match !kinds with Pre :: _ -> decr pre | _ -> ());
         kinds := (match !kinds with _ :: (_ :: _ as rest) -> rest | k -> k)
       | _ -> ())
    | _ -> () in
  Dom.walk ~enter ~leave doc;
  flush ();
  { title; blocks = List.rev !blocks; links = List.rev !links }

let to_text p =
  let b = Buffer.create 4096 in
  if p.title <> "" then Printf.bprintf b "title: %s\n" p.title;
  List.iter (fun blk ->
      match blk.kind with
      | Heading n -> Printf.bprintf b "%s %s\n" (String.make n '#') blk.text
      | Paragraph -> Printf.bprintf b "%s\n" blk.text
      | Item d -> Printf.bprintf b "%s- %s\n" (String.make (2 * (d - 1)) ' ') blk.text
      | Pre -> List.iter (fun l -> Printf.bprintf b "    %s\n" l) (String.split_on_char '\n' blk.text)
      | Rule -> Buffer.add_string b "----\n") p.blocks;
  Buffer.contents b
