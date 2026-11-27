(* Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).

     ariadne [URL]                  a window (the start page without a URL)
     ariadne --dump URL             the page as text, and its links
     ariadne --layout URL [WIDTH]   the page's display list, laid out WIDTH wide
     ariadne --time URL             the time of each stage

   A page is loaded (Loader), decoded (Encoding), parsed by the HTML
   Standard's parser (Html, into Dom); its style sheets are fetched and
   parsed (Css, Selector), the cascade gives each element its style
   (Style), and layout (Layout) turns them into a display list, which the
   window paints. *)

let usage () =
  prerr_endline "usage: ariadne [URL] | ariadne --dump URL | ariadne --layout URL [WIDTH] | ariadne --time URL";
  exit 2

(* ---- a page and its style sheets ---- *)

type loaded = {
  response : Loader.response;
  doc : Dom.node;
  base : string;                       (* what its links are resolved against *)
  sheets : Style.sheet list;
  title : string;
  mutable laid : (int * Layout.page) option;      (* for a width *)
  times : (string * float) list;       (* the stages' times, in ms *)
}

let now = Unix.gettimeofday

(* a style sheet's text, fetched *)
let fetch_css url =
  match Loader.load url with
  | r when String.length r.Loader.status > 0 && (r.status.[0] = '2' || r.status = "a file") ->
    Some (snd (Encoding.to_utf8 ?transport:(Encoding.charset_of_content_type r.content_type) r.body))
  | _ -> None

(* a sheet, after the sheets it imports (three levels at most) *)
let rec with_imports ~base ~depth ?media text =
  let sh = Style.parse_sheet ?media text in
  let imported =
    if depth >= 3 then []
    else List.concat_map (fun (u, mq) ->
        let url = Url.resolve base u in
        let media = match mq with [] -> media | q -> Some (Css.to_string q) in
        match fetch_css url with
        | Some t -> with_imports ~base:url ~depth:(depth + 1) ?media t
        | None -> []) sh.imports in
  imported @ [ sh ]

let load url =
  let t0 = now () in
  let response = Loader.load (Url.of_typed url) in
  let t1 = now () in
  let text, _ = Loader.document response in
  let t2 = now () in
  let doc = Html.parse text in
  let t3 = now () in
  let base = match Dom.find (fun n -> Dom.is_html n "base" && Dom.attr n "href" <> None) doc with
    | Some b -> Url.resolve response.url (Option.get (Dom.attr b "href"))
    | None -> response.url in
  let sheets = List.concat_map (function
      | Style.Inline_sheet (t, media) -> with_imports ~base ~depth:0 ?media t
      | Style.Linked (href, media) ->
        let u = Url.resolve base href in
        (match fetch_css u with Some t -> with_imports ~base:u ~depth:0 ?media t | None -> []))
      (Style.sources doc) in
  let t4 = now () in
  let title = match Dom.find (fun n -> Dom.is_html n "title") doc with
    | Some t -> String.trim (Text.collapse (Dom.text_content t)) | None -> "" in
  let ms a b = (b -. a) *. 1000. in
  { response; doc; base; sheets; title; laid = None;
    times = [ "load", ms t0 t1; "decode", ms t1 t2; "parse", ms t2 t3; "css", ms t3 t4 ] }

let layout_at l ~width ~height =
  match l.laid with
  | Some (w, p) when w = width -> p
  | _ ->
    let styles = Style.compute ~width ~height l.sheets l.doc in
    let p = Layout.layout ~width ~height styles l.doc in
    l.laid <- Some (width, p);
    p

(* ---- --dump, --layout, --time ---- *)

let dump url =
  let response = Loader.load (Url.of_typed url) in
  let page = Text.of_dom (Html.parse (fst (Loader.document response))) in
  print_string (Text.to_text page);
  if page.links <> [] then begin
    print_string "links:\n";
    List.iteri (fun i h -> Printf.printf "%d. %s\n" (i + 1) (Url.resolve response.url h)) page.links
  end

let layout_dump url width =
  let l = load url in
  print_string (Layout.dump (layout_at l ~width ~height:600))

let time url =
  let l = load url in
  let t0 = now () in
  let styles = Style.compute ~width:880 ~height:600 l.sheets l.doc in
  let t1 = now () in
  let p = Layout.layout ~width:880 ~height:600 styles l.doc in
  let t2 = now () in
  Printf.printf "ariadne: %s (%s)\n" l.response.url l.response.status;
  let rules = List.fold_left (fun a (s : Style.sheet) -> a + List.length s.rules) 0 l.sheets in
  List.iter (fun (stage, ms) ->
      let detail = match stage with
        | "load" -> Printf.sprintf "%d bytes" (String.length l.response.body)
        | "parse" -> Printf.sprintf "%d nodes" (Dom.count l.doc)
        | "css" -> Printf.sprintf "%d sheets, %d rules (fetched and parsed)" (List.length l.sheets) rules
        | _ -> "" in
      Printf.printf "  %-8s %6.0f ms  %s\n" stage ms detail) l.times;
  Printf.printf "  %-8s %6.0f ms\n" "cascade" ((t1 -. t0) *. 1000.);
  Printf.printf "  %-8s %6.0f ms  %d items, %d links, %d px high\n" "layout" ((t2 -. t1) *. 1000.)
    (Array.length p.items) (Array.length p.links) p.height;
  let total = List.fold_left (fun a (_, ms) -> a +. ms) 0. l.times +. (t2 -. t0) *. 1000. in
  Printf.printf "  %-8s %6.0f ms\n" "total" total

(* ---- the window ---- *)

type st = {
  mutable shown : loaded;
  mutable address : string;
  mutable loading : (string * int) option;          (* a load running: its number *)
  mutable back : (string * int) list;                (* url, scroll *)
  mutable forward : (string * int) list;
  mutable want_scroll : int option;
  mutable hover : string option;
}

let offset = ref 0          (* how far the page is scrolled, as last drawn *)

let window first =
  let lock = Mutex.create () in
  let arrived : (int * loaded) option ref = ref None in
  let loads = ref 0 in
  let page_width = ref 880 in
  let st = { shown = load "about:start"; address = first; loading = None; back = []; forward = [];
             want_scroll = None; hover = None } in
  let start url =
    incr loads;
    let n = !loads in
    st.loading <- Some (url, n);
    st.address <- url;
    let width = !page_width in
    ignore (Thread.create (fun () ->
        let l = load url in
        (* laid out here, for the width the window has now *)
        ignore (layout_at l ~width ~height:600);
        Mutex.protect lock (fun () -> arrived := Some (n, l))) ()) in
  let go url =
    st.back <- (st.shown.response.url, !offset) :: st.back;
    st.forward <- [];
    st.want_scroll <- Some 0;
    start url in
  if first <> "about:start" then go first;
  Gui.run ~title:"Ariadne" ~tick:0.1 ~resizable:(400, 300) 900 640 st (fun ui st ->
      let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
      (* a page arrived: shown, if it is the one asked for last *)
      (match Mutex.protect lock (fun () -> let a = !arrived in arrived := None; a) with
       | Some (n, l) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
         let asked = match st.loading with Some (u, _) -> u | None -> l.response.url in
         st.shown <- l; st.loading <- None;
         st.address <- l.response.url ^ (match snd (Url.strip_fragment asked) with
             | Some f -> "#" ^ f | None -> "");
         if st.want_scroll = None then st.want_scroll <- Some 0
       | _ -> ());
      (* the bar: Back, Forward, Reload or Stop, the address, Go *)
      Gfx.fill g 0 0 width 40 0x1B3A57;
      let back = Gui.button ui 6 7 34 "<" and fwd = Gui.button ui 44 7 34 ">" in
      let reload = Gui.button ui 82 7 70 (if st.loading <> None then "Stop" else "Reload") in
      let field_w = width - 158 - 64 in
      st.address <- Gui.text_field ui 1 158 9 field_w st.address;
      let enter = ui.Gui.field = 1 && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      let gob = Gui.button ui (width - 58) 7 52 "Go" in
      if (enter || gob) && String.trim st.address <> "" then begin
        ui.Gui.field <- 0; go (Url.of_typed st.address)
      end;
      if back then (match st.back with
          | (u, off) :: rest ->
            st.forward <- (st.shown.response.url, !offset) :: st.forward; st.back <- rest;
            st.want_scroll <- Some off; start u
          | [] -> ());
      if fwd then (match st.forward with
          | (u, off) :: rest ->
            st.back <- (st.shown.response.url, !offset) :: st.back; st.forward <- rest;
            st.want_scroll <- Some off; start u
          | [] -> ());
      if reload then begin
        if st.loading <> None then (st.loading <- None; st.address <- st.shown.response.url)
        else (st.want_scroll <- Some !offset; start st.shown.response.url)
      end;
      (* the page, laid out for the width it has *)
      let box_x = 4 and box_y = 44 and box_h = height - 44 - 24 in
      let box_w = width - 8 in
      page_width := box_w - 14;
      let page = layout_at st.shown ~width:!page_width ~height:box_h in
      (match st.want_scroll with
       | Some s ->
         let s = match snd (Url.strip_fragment st.address) with
           | Some f when s = 0 -> (match List.assoc_opt f page.anchors with Some y -> y | None -> s)
           | _ -> s in
         Gui.scroll_to ui 2 s; st.want_scroll <- None
       | None -> ());
      (* the keys scroll the page, when the address does not have them *)
      if ui.Gui.field <> 1 then
        List.iter (fun k ->
            let by d = Gui.scroll_to ui 2 (max 0 (min (page.height - box_h) (!offset + d))) in
            match k with
            | "\027[6~" | " " -> by (box_h - 40)
            | "\027[5~" -> by (-(box_h - 40))
            | "\027[B" -> by 48
            | "\027[A" -> by (-48)
            | "\027[H" | "\027[1~" -> Gui.scroll_to ui 2 0
            | "\027[F" | "\027[4~" -> Gui.scroll_to_end ui 2
            | _ -> ()) ui.Gui.keys;
      let top_ref = ref box_y in
      Gui.scroll ~colour:page.background ui 2 box_x box_y box_w box_h (fun top ->
          top_ref := top;
          offset := box_y - top;
          Array.iter (fun (it : Layout.item) ->
              match it with
              | Fill { x; y; w; h; color } ->
                let yy = top + y in
                if yy + h > box_y && yy < box_y + box_h && w > 0 && h > 0 then
                  Gfx.fill g (box_x + x) yy w h color
              | Text { x; y; s; color; font } ->
                (* y is the baseline: each glyph's mask, from the fonts *)
                let yy = top + y in
                if yy + font.descent > box_y && yy - font.ascent < box_y + box_h then begin
                  match font.ttf with
                  | Some _ ->
                    List.iter (fun (dx, dy, (b : Ttf.bitmap)) ->
                        Gfx.draw_mask g (box_x + x + dx) (yy + dy)
                          { Gfx.mask_width = b.width; mask_height = b.height; grey = b.grey } color)
                      (Fonts.glyphs font s)
                  | None -> ignore (Gfx.text g (box_x + x) (yy - font.ascent) s color)
                end) page.items;
          page.height);
      (* a link under the pointer: shown below; a click follows it *)
      let link_at mx my =
        if my < box_y || my >= box_y + box_h then None
        else
          let px = mx - box_x and py = my - !top_ref in
          Array.fold_left (fun found (l : Layout.link) ->
              if px >= l.lx && px < l.lx + l.lw && py >= l.ly && py < l.ly + l.lh then Some l.href else found)
            None page.links in
      st.hover <- Option.map (Url.resolve st.shown.base) (link_at ui.Gui.mx ui.Gui.my);
      (if ui.Gui.clicked then
         let px, py = ui.Gui.press in
         match link_at px py, link_at ui.Gui.mx ui.Gui.my with
         | Some h, Some h2 when h = h2 ->
           let target = Url.resolve st.shown.base h in
           let here, _ = Url.strip_fragment st.shown.response.url in
           (match Url.strip_fragment target with
            | t, Some f when t = here ->
              st.address <- target;
              (match List.assoc_opt f page.anchors with
               | Some y -> Gui.scroll_to ui 2 y | None -> ())
            | _ ->
              match Url.scheme_of target with
              | Some ("mailto" | "javascript" | "tel") -> ()
              | _ -> go target)
         | _ -> ());
      (* the status line *)
      Gfx.fill g 0 (height - 22) width 22 0xE8EDF2;
      let status = match st.loading, st.hover with
        | Some (u, _), _ -> "loading " ^ u ^ "..."
        | None, Some h -> h
        | None, None ->
          (if st.shown.title <> "" then st.shown.title ^ "  \xc2\xb7  " else "") ^ st.shown.response.status in
      ignore (Gfx.text ~max:((width - 16) / Gfx.char_w) g 8 (height - 19) status Gui.muted);
      st)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | [ "--layout"; url ] -> layout_dump url 800
  | [ "--layout"; url; w ] -> layout_dump url (Option.value (int_of_string_opt w) ~default:800)
  | [ "--time"; url ] -> time url
  | [ url ] when url <> "" && url.[0] <> '-' -> window (Url.of_typed url)
  | [] -> window "about:start"
  | _ -> usage ()
