(* Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).

     ariadne [URL]                  a window (the start page without a URL)
     ariadne --dump URL             the page as text, and its links
     ariadne --layout URL [WIDTH]   the page's display list, laid out WIDTH wide
     ariadne --time URL             the time of each stage
     ariadne --check-images         imaged checked (tools/run-tests.sh)

   A page is loaded (Loader), decoded (Encoding), parsed by the HTML
   Standard's parser (Html, into Dom); its style sheets are fetched and
   parsed (Css, Selector), the cascade gives each element its style
   (Style), and layout (Layout) turns them into a display list, which the
   window paints. *)

let usage () =
  prerr_endline "usage: ariadne [URL] | ariadne --dump URL | ariadne --layout URL [WIDTH] | ariadne --time URL";
  exit 2

(* ---- pictures ---- *)

(* a picture of a page: its bytes, its own size (from imaged), and its
   pixels at the sizes it is drawn at (the last two) *)
type pic = { data : string; nw : int; nh : int; mutable scaled : ((int * int) * Gfx.image) list;
             mutable asked : (int * int) list }

(* the pictures, by URL (None: not a picture, or not fetched); one lock
   for them all, the window's thread and the workers' *)
let pics_lock = Mutex.create ()

(* ---- a page and its style sheets ---- *)

type loaded = {
  response : Loader.response;
  doc : Dom.node;
  base : string;                       (* what its links are resolved against *)
  sheets : Style.sheet list;
  title : string;
  mutable laid : (int * Layout.page) option;      (* for a width *)
  mutable styled : (int * Style.styles) option;   (* for a width *)
  pics : (string, pic option) Hashtbl.t;          (* under pics_lock *)
  started : (string, unit) Hashtbl.t;             (* fetches begun (pics_lock) *)
  hurried : (string, unit) Hashtbl.t;             (* fetches asked for first: on screen (pics_lock) *)
  mutable sized : int;                            (* pictures whose size arrived (pics_lock) *)
  mutable laid_sized : int;                       (* ... when laid out *)
  times : (string * float) list;       (* the stages' times, in ms *)
}

let now = Unix.gettimeofday

(* ARIADNE_DEBUG: what takes time (the page's stages, the pictures, slow
   frames), in the kernel log, in ms since the start *)
let debug = Sys.getenv_opt "ARIADNE_DEBUG" <> None
let t_start = now ()
let trace fmt = Printf.ksprintf (fun m ->
    if debug then Mynos.log (Printf.sprintf "ariadne %6.0f: %s\n" ((now () -. t_start) *. 1000.) m)) fmt

(* a style sheet's text, fetched *)
let fetch_css url =
  match Loader.load url with
  | r when Loader.ok r ->
    Some (snd (Encoding.to_utf8 ?transport:(Encoding.charset_of_content_type r.content_type) r.body))
  | _ -> None

(* a sheet, after the sheets it imports (three levels at most) *)
let rec with_imports ~base ~depth ?media text =
  let sh = Style.parse_sheet ~base ?media text in
  let imported =
    if depth >= 3 then []
    else List.concat_map (fun (u, mq) ->
        let url = Url.resolve base u in
        let media = match mq with [] -> media | q -> Some (Css.to_string q) in
        match fetch_css url with
        | Some t -> with_imports ~base:url ~depth:(depth + 1) ?media t
        | None -> []) sh.imports in
  imported @ [ sh ]

let load ?post url =
  let t0 = now () in
  let response = Loader.load ?post (Url.of_typed url) in
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
  trace "page %s: load %.0f, decode %.0f, parse %.0f, css %.0f ms (%d sheets)" url (ms t0 t1) (ms t1 t2) (ms t2 t3)
    (ms t3 t4) (List.length sheets);
  { response; doc; base; sheets; title; laid = None; styled = None; pics = Hashtbl.create 16;
    started = Hashtbl.create 16; hurried = Hashtbl.create 16;
    sized = 0; laid_sized = 0;
    times = [ "load", ms t0 t1; "decode", ms t1 t2; "parse", ms t2 t3; "css", ms t3 t4 ] }

(* a picture's own size, if it has arrived *)
let pic_size l src =
  let u = Url.resolve l.base src in
  Mutex.protect pics_lock (fun () -> match Hashtbl.find_opt l.pics u with
      | Some (Some p) -> Some (p.nw, p.nh) | _ -> None)

let layout_at l ~width ~height =
  match l.laid with
  | Some (w, p) when w = width -> p
  | _ ->
    let t0 = now () in
    let styles = match l.styled with
      | Some (w, s) when w = width -> s
      | _ -> let s = Style.compute ~width ~height l.sheets l.doc in l.styled <- Some (width, s); s in
    let t1 = now () in
    l.laid_sized <- Mutex.protect pics_lock (fun () -> l.sized);
    let p = Layout.layout ~image:(pic_size l) ~width ~height styles l.doc in
    trace "laid out %d wide: cascade %.0f, layout %.0f ms" width ((t1 -. t0) *. 1000.) ((now () -. t1) *. 1000.);
    l.laid <- Some (width, p);
    p

(* the pictures' work, in threads of their own: fetching a page's
   pictures and asking imaged their size, then their pixels at the sizes
   they are drawn at *)
type job = Fetch of loaded * string | Scale of pic * int * int

let jobs : job Queue.t = Queue.create ()
let urgent : job Queue.t = Queue.create ()     (* pixels for the screen: first *)
let jobs_ready = Condition.create ()
let workers = ref false

let max_pics = 300

(* pictures fetched, across pages (Back, the same icons on the next page):
   by URL, the oldest dropped past [cache_budget] bytes of their data
   (under pics_lock) *)
let cache : (string, pic) Hashtbl.t = Hashtbl.create 64
let cache_order : string Queue.t = Queue.create ()
let cache_bytes = ref 0
let cache_budget = 24 * 1024 * 1024

let cache_add url p =
  if not (Hashtbl.mem cache url) then begin
    Hashtbl.replace cache url p; Queue.push url cache_order;
    cache_bytes := !cache_bytes + String.length p.data;
    while !cache_bytes > cache_budget && not (Queue.is_empty cache_order) do
      let u = Queue.pop cache_order in
      (match Hashtbl.find_opt cache u with
       | Some q -> cache_bytes := !cache_bytes - String.length q.data; Hashtbl.remove cache u
       | None -> ())
    done
  end

(* a page's picture met (under pics_lock): from the cache, or to fetch
   (true) *)
let register l u =
  if Hashtbl.mem l.pics u then false
  else match Hashtbl.find_opt cache u with
    | Some p -> Hashtbl.replace l.pics u (Some p); Hashtbl.replace l.started u (); l.sized <- l.sized + 1; false
    | None -> Hashtbl.replace l.pics u None; true


let worker () =
  let images = lazy (try Some (Images.connect ()) with e -> trace "no imaged: %s" (Printexc.to_string e); None) in
  let rec loop () =
    let job = Mutex.protect pics_lock (fun () ->
        while Queue.is_empty jobs && Queue.is_empty urgent do Condition.wait jobs_ready pics_lock done;
        if Queue.is_empty urgent then Queue.pop jobs else Queue.pop urgent) in
    (match job, Lazy.force images with
     | Fetch (l, url), Some images
       when Mutex.protect pics_lock (fun () ->
           (* once: a picture on screen is asked for first, then met again in order *)
           if Hashtbl.mem l.started url then false else (Hashtbl.replace l.started url (); true)) ->
       let p =
         try
           trace "fetch %s" url;
           let r = Loader.load url in
           trace "fetched %s: %s, %d bytes" url r.Loader.status (String.length r.body);
           if Loader.ok r then
             let nw, nh = Images.size ~images r.body in
             trace "size %s: %d x %d" url nw nh;
             Some { data = r.body; nw; nh; scaled = []; asked = [] }
           else None
         with e -> trace "failed %s: %s" url (Printexc.to_string e); None in
       Mutex.protect pics_lock (fun () ->
           Hashtbl.replace l.pics url p;
           match p with Some p -> l.sized <- l.sized + 1; cache_add url p | None -> ())
     | Scale (p, w, h), Some images ->
       let t0 = now () in
       (match Images.decode ~images ~width:w ~height:h p.data with
        | d ->
          trace "decoded %dx%d (from %dx%d, %d bytes) in %.0f ms" w h p.nw p.nh (String.length p.data)
            ((now () -. t0) *. 1000.);
          Mutex.protect pics_lock (fun () ->
            p.scaled <- ((w, h), d.image) :: (match p.scaled with x :: _ -> [ x ] | [] -> []))
        | exception e -> trace "decode failed: %s" (Printexc.to_string e))
     | Fetch _, Some _ -> ()
     | _, None -> ());
    loop () in
  loop ()

let enqueue ?(first = false) job =
  Mutex.protect pics_lock (fun () ->
      Queue.push job (match job with Scale _ -> urgent | Fetch _ -> if first then urgent else jobs);
      Condition.signal jobs_ready);
  if not !workers then begin
    workers := true;
    trace "workers start";
    for _ = 1 to 3 do ignore (Thread.create worker ()) done
  end

(* the page's width, for the srcset candidate the layout will pick *)
let fetch_width = ref 878

(* a page's pictures, fetched: those of its img elements, in order *)
let fetch_pictures l =
  let n = ref 0 in
  Dom.walk ~leave:ignore l.doc ~enter:(fun node ->
      (if Dom.is_html node "img" && !n < max_pics then
         match Layout.img_source ~vw:!fetch_width node with
         | Some src ->
           let u = Url.resolve l.base src in
           let fresh = Mutex.protect pics_lock (fun () -> register l u) in
           if fresh then (incr n; enqueue (Fetch (l, u)))
         | _ -> ());
      true)

(* a background picture's own size, if it has arrived; met for the first
   time (on screen), fetched before the others *)
let pic_natural l src =
  let u = Url.resolve l.base src in
  let fetch = ref false in
  let r = Mutex.protect pics_lock (fun () ->
      match Hashtbl.find_opt l.pics u with
      | Some (Some p) -> Some (p.nw, p.nh)
      | Some None -> None
      | None ->
        if Hashtbl.length l.pics < max_pics && register l u then begin
          Hashtbl.replace l.hurried u (); fetch := true
        end;
        (match Hashtbl.find_opt l.pics u with Some (Some p) -> Some (p.nw, p.nh) | _ -> None)) in
  if !fetch then enqueue ~first:true (Fetch (l, u));
  r

(* a picture's pixels at w x h: drawn now if there, asked for if not *)
let pic_image l src w h =
  let u = Url.resolve l.base src in
  let ask = ref None and first = ref false in
  let r = Mutex.protect pics_lock (fun () ->
      match Hashtbl.find_opt l.pics u with
      | Some (Some p) ->
        (match List.assoc_opt (w, h) p.scaled with
         | Some _ as i -> i
         | None ->
           if not (List.mem (w, h) p.asked) then begin
             p.asked <- (w, h) :: (match p.asked with x :: _ -> [ x ] | [] -> []);
             ask := Some p
           end;
           None)
      | Some None ->
        (* on screen and not fetched yet: before the others *)
        if not (Hashtbl.mem l.started u) && not (Hashtbl.mem l.hurried u) then begin
          Hashtbl.replace l.hurried u (); first := true
        end;
        None
      | _ -> None) in
  (match !ask with Some p -> enqueue (Scale (p, w, h)) | None -> ());
  if !first then enqueue ~first:true (Fetch (l, u));
  r

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
  mutable focus : (Dom.node * int) option;           (* a text control with the keys: its caret (a byte) *)
  mutable popup : (Dom.node * int * int * int * Fonts.font) option;
                                                     (* a select's options shown: x, y, w on the page *)
}

(* Chrome's accent for chosen check boxes and radio buttons *)
let accent = 0x1A73E8
let radio_ring = lazy { Gfx.mask_width = 13; mask_height = 13; grey = Forms.circle_mask 13 ~ring:true }
let radio_dot = lazy { Gfx.mask_width = 13; mask_height = 13; grey = Forms.circle_mask 13 ~ring:false }

(* text in a font, its baseline at y *)
let draw_string g x y s color (font : Fonts.font) =
  match font.ttf with
  | Some _ ->
    List.iter (fun (dx, dy, (b : Ttf.bitmap)) ->
        Gfx.draw_mask g (x + dx) (y + dy) { Gfx.mask_width = b.width; mask_height = b.height; grey = b.grey } color)
      (Fonts.glyphs font s)
  | None -> ignore (Gfx.text g x (y - font.ascent) s color)

(* UTF-8: the start of the character before, or after, byte i *)
let prev_char s i =
  let i = ref (i - 1) in
  while !i > 0 && Char.code s.[!i] land 0xC0 = 0x80 do decr i done;
  max 0 !i

let next_char s i =
  let n = String.length s in
  let i = ref (i + 1) in
  while !i < n && Char.code s.[!i] land 0xC0 = 0x80 do incr i done;
  min n !i

(* what a control shows before byte c of its value (a password's dots) *)
let shown_prefix node c =
  let v = Forms.value node in
  let before = String.sub v 0 (min c (String.length v)) in
  match Forms.kind node with
  | Forms.Field { password = true } -> String.concat "" (List.init (Forms.utf8_length before) (fun _ -> "\xe2\x80\xa2"))
  | _ -> before

let offset = ref 0          (* how far the page is scrolled, as last drawn *)
let last_relayout = ref 0.

let window first =
  let lock = Mutex.create () in
  let arrived : (int * loaded) option ref = ref None in
  let loads = ref 0 in
  (* the page's width in the window's first size (900, as below): the
     first page is laid out once, at the width it is shown *)
  let page_width = ref (900 - 8 - 14) in
  let st = { shown = load "about:start"; address = first; loading = None; back = []; forward = [];
             want_scroll = None; hover = None; focus = None; popup = None } in
  let start ?post url =
    incr loads;
    let n = !loads in
    st.loading <- Some (url, n);
    st.address <- url;
    let width = !page_width in
    ignore (Thread.create (fun () ->
        let l = load ?post url in
        (* laid out here, for the width the window has now *)
        ignore (layout_at l ~width ~height:600);
        Mutex.protect lock (fun () -> arrived := Some (n, l))) ()) in
  let go ?post url =
    st.back <- (st.shown.response.url, !offset) :: st.back;
    st.forward <- [];
    st.want_scroll <- Some 0;
    st.focus <- None; st.popup <- None;
    start ?post url in
  (* a form sent: by a button, or by Enter in a field (with the form's
     first submit button) *)
  let submit ?submitter node =
    match Forms.form_of node with
    | Some form ->
      let submitter = match submitter with Some s -> Some s | None -> Forms.default_button form in
      (match Forms.submit ~base:st.shown.base ?submitter form with
       | Forms.Get url -> go url
       | Forms.Post (url, body) -> go ~post:body url)
    | None -> () in
  if first <> "about:start" then go first;
  Gui.run ~title:"Ariadne" ~tick:0.1 ~resizable:(400, 300) 900 640 st (fun ui st ->
      let t_frame = now () in
      let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
      (* a page arrived: shown, if it is the one asked for last *)
      (match Mutex.protect lock (fun () -> let a = !arrived in arrived := None; a) with
       | Some (n, l) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
         let asked = match st.loading with Some (u, _) -> u | None -> l.response.url in
         st.shown <- l; st.loading <- None;
         fetch_pictures l;
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
      fetch_width := !page_width;
      (* pictures whose size the layout waited for: laid out again, at
         most every second *)
      let l = st.shown in
      (match l.laid with
       | Some (_, p) when p.unsized <> [] && now () -. !last_relayout > 1.
                          && Mutex.protect pics_lock (fun () -> l.sized) <> l.laid_sized ->
         last_relayout := now (); l.laid <- None
       | _ -> ());
      let page = layout_at st.shown ~width:!page_width ~height:box_h in
      (match st.want_scroll with
       | Some s ->
         let s = match snd (Url.strip_fragment st.address) with
           | Some f when s = 0 -> (match List.assoc_opt f page.anchors with Some y -> y | None -> s)
           | _ -> s in
         Gui.scroll_to ui 2 s; st.want_scroll <- None
       | None -> ());
      (* a text control with the keys: typed into; else the keys scroll the
         page, when the address does not have them *)
      if ui.Gui.field = 1 then st.focus <- None;
      (match st.focus with
       | Some (node, caret) ->
         let v = ref (Forms.value node) in
         let c = ref (min caret (String.length !v)) in
         let insert t = v := String.sub !v 0 !c ^ t ^ String.sub !v !c (String.length !v - !c); c := !c + String.length t in
         List.iter (fun k ->
             match k with
             | "\r" | "\n" -> (match Forms.kind node with Forms.Area -> insert "\n" | _ -> submit node)
             | "\127" | "\b" -> if !c > 0 then begin
                 let p = prev_char !v !c in
                 v := String.sub !v 0 p ^ String.sub !v !c (String.length !v - !c); c := p end
             | "\027[3~" -> if !c < String.length !v then begin
                 let nx = next_char !v !c in
                 v := String.sub !v 0 !c ^ String.sub !v nx (String.length !v - nx) end
             | "\027[D" -> c := prev_char !v !c
             | "\027[C" -> c := next_char !v !c
             | "\027[H" | "\027[1~" | "\001" -> c := 0
             | "\027[F" | "\027[4~" | "\005" -> c := String.length !v
             | "\027" -> st.focus <- None
             | k when String.length k > 0 && k.[0] <> '\027' && Char.code k.[0] >= 32 -> insert k
             | _ -> ()) ui.Gui.keys;
         if !v <> Forms.value node then Forms.set_value node !v;
         (match st.focus with Some (n, _) when n == node -> st.focus <- Some (node, !c) | _ -> ())
       | None -> ());
      if ui.Gui.field <> 1 && st.focus = None then
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
      let t_paint = now () and drawn = ref 0 in
      Gui.scroll ~colour:page.background ui 2 box_x box_y box_w box_h (fun top ->
          top_ref := top;
          offset := box_y - top;
          Array.iter (fun (it : Layout.item) ->
              match it with
              | Fill { x; y; w; h; color } ->
                let yy = top + y in
                if yy + h > box_y && yy < box_y + box_h && w > 0 && h > 0 then
                  (incr drawn; Gfx.fill g (box_x + x) yy w h color)
              | Text { x; y; s; color; font } ->
                (* y is the baseline: each glyph's mask, from the fonts *)
                let yy = top + y in
                if yy + font.descent > box_y && yy - font.ascent < box_y + box_h then begin
                  incr drawn;
                  match font.ttf with
                  | Some _ ->
                    List.iter (fun (dx, dy, (b : Ttf.bitmap)) ->
                        Gfx.draw_mask g (box_x + x + dx) (yy + dy)
                          { Gfx.mask_width = b.width; mask_height = b.height; grey = b.grey } color)
                      (Fonts.glyphs font s)
                  | None -> ignore (Gfx.text g (box_x + x) (yy - font.ascent) s color)
                end
              | Image { x; y; w; h; src; clip } ->
                let yy = top + y in
                if yy + h > box_y && yy < box_y + box_h then
                  (match pic_image st.shown src w h with
                  | Some img ->
                    (match clip with
                     | Some (x0, y0, x1, y1) ->
                       Gfx.with_clip (box_x + x0) (top + y0) (x1 - x0) (y1 - y0)
                         (fun () -> Gfx.draw_image g (box_x + x) yy img)
                     | None -> Gfx.draw_image g (box_x + x) yy img)
                  | None -> ())
              | Control { x; y; w; h; node; font; color; paint } ->
                let sx = box_x + x and sy = top + y in
                if paint && sy + h > box_y && sy < box_y + box_h && w > 2 && h > 2 then begin
                  incr drawn;
                  let sh = Forms.shown node in
                  (match Forms.kind node, sh.mark with
                   | Forms.Check, `Check ->
                     Gfx.fill g sx sy w h accent;
                     for t = 0 to 1 do
                       Gfx.line g (sx + 3) (sy + 6 + t) (sx + 5) (sy + 8 + t) 0xFFFFFF;
                       Gfx.line g (sx + 5) (sy + 8 + t) (sx + 9) (sy + 3 + t) 0xFFFFFF
                     done
                   | Forms.Radio, mark ->
                     let on = mark = `Dot in
                     Gfx.draw_mask g sx sy (Lazy.force radio_ring) (if on then accent else 0x767676);
                     if on then Gfx.draw_mask g sx sy (Lazy.force radio_dot) accent
                   | Forms.Select, _ ->
                     let rx = sx + w - 13 and cy = sy + h / 2 - 2 in
                     for i = 0 to 3 do Gfx.fill g (rx + i) (cy + i) (7 - 2 * i) 1 color done
                   | _ -> ());
                  let caret = match st.focus with Some (n, c) when n == node -> Some c | _ -> None in
                  if sh.text <> "" || caret <> None then
                    Gfx.with_clip (sx + 1) (sy + 1) (w - (if Forms.kind node = Forms.Select then 16 else 2)) (h - 2) (fun () ->
                        let colour = if sh.placeholder then 0x757575 else color in
                        match Forms.kind node with
                        | Forms.Area ->
                          (* lines from the top; the caret at its line's place *)
                          let lines = String.split_on_char '\n' sh.text in
                          List.iteri (fun i l ->
                              draw_string g (sx + 4) (sy + 2 + font.ascent + i * font.line) l colour font) lines;
                          (match caret with
                           | Some c ->
                             let before = shown_prefix node c in
                             let row = List.length (String.split_on_char '\n' before) - 1 in
                             let col = match String.rindex_opt before '\n' with
                               | Some i -> String.sub before (i + 1) (String.length before - i - 1) | None -> before in
                             Gfx.fill g (sx + 4 + Fonts.width font col) (sy + 2 + row * font.line) 1
                               (font.ascent + font.descent) color
                           | None -> ())
                        | _ ->
                          let base = sy + (h + font.ascent - font.descent) / 2 in
                          let tw = Fonts.width font sh.text in
                          let caret_px = match caret with
                            | Some c when not sh.placeholder -> Fonts.width font (shown_prefix node c)
                            | _ -> 0 in
                          (* the text moved left, to keep the caret in sight *)
                          let shift = max 0 (caret_px - (w - 10)) in
                          let tx = if sh.centred then sx + (w - tw) / 2 else sx + 4 - shift in
                          draw_string g tx base sh.text colour font;
                          if caret <> None then
                            Gfx.fill g (sx + 4 - shift + caret_px) (base - font.ascent) 1
                              (font.ascent + font.descent) color)
                end
              | Bg { x; y; w; h; layer; tint; clip } ->
                let yy = top + y in
                (match layer.image with
                 | Some src when yy + h > box_y && yy < box_y + box_h && w > 0 && h > 0 ->
                   (match pic_natural st.shown src with
                    | Some natural ->
                      (* the box, within its clip *)
                      let x0, y0, x1, y1 = match clip with
                        | Some (a, b, c, d) -> (max a x, max b y, min c (x + w), min d (y + h))
                        | None -> (x, y, x + w, y + h) in
                      if x1 > x0 && y1 > y0 then
                        Gfx.with_clip (box_x + x0) (top + y0) (x1 - x0) (y1 - y0) (fun () ->
                            List.iter (fun (tx, ty, tw, th) ->
                                if top + ty + th > box_y && top + ty < box_y + box_h then
                                  match pic_image st.shown src tw th with
                                  | Some img -> Gfx.draw_image ?tint g (box_x + tx) (top + ty) img
                                  | None -> ())
                              (Layout.tiles ~x ~y ~w ~h layer ~natural))
                    | None -> ())
                 | _ -> ())) page.items;
          (* a select's options, over the page *)
          (match st.popup with
           | Some (sel, px, py, pw, font) ->
             let opts = Forms.options sel in
             let rowh = font.line + 4 in
             let ow = List.fold_left (fun m o -> max m (Fonts.width font (Forms.option_label o) + 16)) pw opts in
             let sx = box_x + px and sy = top + py in
             Gfx.fill g sx sy ow (rowh * List.length opts + 2) 0xFFFFFF;
             Gfx.rect g sx sy ow (rowh * List.length opts + 2) 0x767676;
             let chosen = Forms.selected sel in
             List.iteri (fun i o ->
                 let ry = sy + 1 + i * rowh in
                 let over = ui.Gui.mx >= sx && ui.Gui.mx < sx + ow && ui.Gui.my >= ry && ui.Gui.my < ry + rowh in
                 if over then Gfx.fill g (sx + 1) ry (ow - 2) rowh 0x1A73E8
                 else if (match chosen with Some c -> c == o | None -> false) then Gfx.fill g (sx + 1) ry (ow - 2) rowh 0xE8EEF7;
                 draw_string g (sx + 8) (ry + 2 + font.ascent) (Forms.option_label o) (if over then 0xFFFFFF else 0x202122) font)
               opts
           | None -> ());
          page.height);
      (* a link under the pointer: shown below; a click follows it *)
      let link_at mx my =
        if my < box_y || my >= box_y + box_h then None
        else
          let px = mx - box_x and py = my - !top_ref in
          Array.fold_left (fun found (l : Layout.link) ->
              if px >= l.lx && px < l.lx + l.lw && py >= l.ly && py < l.ly + l.lh then Some l.href else found)
            None page.links in
      (* the form control under the pointer: the last box there *)
      let control_at mx my =
        if my < box_y || my >= box_y + box_h then None
        else
          let px = mx - box_x and py = my - !top_ref in
          Array.fold_left (fun found (it : Layout.item) ->
              match it with
              | Control { x; y; w; h; node; font; _ } when px >= x && px < x + w && py >= y && py < y + h ->
                Some (node, x, y, w, h, font)
              | _ -> found) None page.items in
      (* the open select's option under the pointer *)
      let popup_at mx my =
        match st.popup with
        | Some (sel, px, py, pw, font) ->
          let opts = Forms.options sel in
          let rowh = font.line + 4 in
          let ow = List.fold_left (fun m o -> max m (Fonts.width font (Forms.option_label o) + 16)) pw opts in
          let sx = box_x + px and sy = !top_ref + py + 1 in
          if mx >= sx && mx < sx + ow && my >= sy && my < sy + rowh * List.length opts then
            List.nth_opt opts ((my - sy) / rowh)
          else None
        | None -> None in
      st.hover <- Option.map (Url.resolve st.shown.base) (link_at ui.Gui.mx ui.Gui.my);
      if st.hover <> None then ui.Gui.pointer <- Display.Hand;
      (match control_at ui.Gui.mx ui.Gui.my with
       | Some (node, _, _, _, _, _) when st.popup = None ->
         (match Forms.kind node with
          | Forms.Field _ | Forms.Area -> ui.Gui.pointer <- Display.Text
          | _ -> ())
       | _ -> ());
      if List.mem "\027" ui.Gui.keys then st.popup <- None;
      let control_clicked =
        ui.Gui.clicked && (st.popup <> None
                           || (let px, py = ui.Gui.press in control_at px py <> None)) in
      (if control_clicked then begin
         let px, py = ui.Gui.press in
         match st.popup with
         | Some (sel, _, _, _, _) ->
           (match popup_at px py with Some o -> Forms.select sel o | None -> ());
           st.popup <- None
         | None ->
           match control_at px py, control_at ui.Gui.mx ui.Gui.my with
           | Some (node, x, y, w, h, font), Some (n2, _, _, _, _, _) when node == n2 && not (Forms.disabled node) ->
             (match Forms.kind node with
              | Forms.Field _ | Forms.Area ->
                (* the caret at the click, along the first line *)
                let v = Forms.value node in
                let target = px - (box_x + x + 4) in
                let rec find c = if c >= String.length v then c
                  else if Fonts.width font (shown_prefix node (next_char v c)) > target then c
                  else find (next_char v c) in
                st.focus <- Some (node, if Forms.kind node = Forms.Area then String.length v else find 0);
                ui.Gui.field <- -1
              | Forms.Check | Forms.Radio -> Forms.toggle node; st.focus <- None
              | Forms.Button { submit = true; _ } -> st.focus <- None; submit ~submitter:node node
              | Forms.Select -> st.focus <- None; st.popup <- Some (node, x, y + h, w, font)
              | _ -> ())
           | _ -> ()
       end
       else if ui.Gui.clicked then st.focus <- None);
      (if ui.Gui.clicked && not control_clicked then
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
      let t_painted = now () in
      (* the status line *)
      Gfx.fill g 0 (height - 22) width 22 0xE8EDF2;
      let status = match st.loading, st.hover with
        | Some (u, _), _ -> "loading " ^ u ^ "..."
        | None, Some h -> h
        | None, None ->
          (if st.shown.title <> "" then st.shown.title ^ "  \xc2\xb7  " else "") ^ st.shown.response.status in
      ignore (Gfx.text ~max:((width - 16) / Gfx.char_w) g 8 (height - 19) status Gui.muted);
      if now () -. t_frame > 0.05 then
        trace "frame %.0f ms: before the page %.0f, the page %.0f (%d items drawn of %d)"
          ((now () -. t_frame) *. 1000.) ((t_paint -. t_frame) *. 1000.) ((t_painted -. t_paint) *. 1000.)
          !drawn (Array.length page.items);
      st)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | [ "--layout"; url ] -> layout_dump url 800
  | [ "--layout"; url; w ] -> layout_dump url (Option.value (int_of_string_opt w) ~default:800)
  | [ "--time"; url ] -> time url
  | [ "--check-images" ] -> Check_images.run ()
  | [ url ] when url <> "" && url.[0] <> '-' -> window (Url.of_typed url)
  | [] -> window "about:start"
  | _ -> usage ()
