(* Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).

     ariadne [URL]                  a window (the start page without a URL)
     ariadne --dump URL             the page as text, and its links
     ariadne --layout URL [WIDTH]   the page's display list, laid out WIDTH wide
     ariadne --time URL             the time of each stage
     ariadne --check-images         imaged checked (tools/run-tests.sh)
     ariadne --check-js             jsd checked (tools/run-tests.sh)

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

(* a page's style sheets are those its document holds now (CSSOM's
   document.styleSheets): its <style>s, each parsed once per text, and its
   <link rel=stylesheet>s, fetched once; those a script adds are fetched in a
   thread of their own and apply when they arrive (they do not hold the page
   back, as in browsers) *)
type sheet_cache = {
  sheet_base : string;
  parsed : (string, Style.sheet list) Hashtbl.t;   (* a source's sheets (with its imports), under sheets_lock *)
  fetching : (string, unit) Hashtbl.t;             (* links being fetched (sheets_lock) *)
  mutable arrived : bool;                          (* a link's sheet arrived: style again (sheets_lock) *)
}
let sheets_lock = Mutex.create ()

type loaded = {
  response : Loader.response;
  doc : Dom.node;
  base : string;                       (* what its links are resolved against *)
  mutable sheets : Style.sheet list;   (* as its document is now (css) *)
  css : sheet_cache;
  title : string;
  mutable laid : (int * Layout.page) option;      (* for a width *)
  mutable last : Layout.page option;              (* the last laid out: painted while scripts have the tree *)
  mutable styled : (int * Style.styles) option;   (* for a width *)
  pics : (string, pic option) Hashtbl.t;          (* under pics_lock *)
  started : (string, unit) Hashtbl.t;             (* fetches begun (pics_lock) *)
  hurried : (string, unit) Hashtbl.t;             (* fetches asked for first: on screen (pics_lock) *)
  mutable sized : int;                            (* pictures whose size arrived (pics_lock) *)
  mutable laid_sized : int;                       (* ... when laid out *)
  times : (string * float) list;       (* the stages' times, in ms *)
  console : string;                    (* what the page's scripts printed, their errors *)
  session : Scripts.session option;    (* its scripts, kept while it is shown *)
  frames : (int, frame) Hashtbl.t;     (* its iframes' documents, by element (the window's thread) *)
  mutable t_relayout : float;          (* when laid out again for pictures' sizes *)
  mutable t_changed : float;           (* ... for its scripts' changes *)
}

(* an iframe's browsing context: the page it holds, loaded in a thread of
   its own; navigated by its links and scripts *)
and frame = {
  mutable asked : source;              (* what its attributes say: a change loads it again *)
  mutable current : source;            (* what it shows (navigated since) *)
  fbase : string;                      (* its parent's base: a srcdoc's *)
  mutable gen : int;                   (* its loads: only the last one's page is kept *)
  mutable child : loaded option;       (* under frames_lock *)
  mutable started : bool;              (* its scripts' timers and its pictures started *)
  mutable fscroll : int;
  mutable fw : int; mutable fh : int;  (* its size, as last drawn *)
}
and source = Src of string | Srcdoc of string | Blank

let frames_lock = Mutex.create ()

let now = Unix.gettimeofday

(* ARIADNE_DEBUG: what takes time (the page's stages, the pictures, slow
   frames), in the kernel log, in ms since the start *)
let debug = Sys.getenv_opt "ARIADNE_DEBUG" <> None
let t_start = now ()
(* a message's data: URLs, as their type and size (an inline svg's are long) *)
let short_data m =
  let b = Buffer.create (String.length m) and n = String.length m in
  let rec go i =
    if i >= n then ()
    else if i + 5 <= n && String.sub m i 5 = "data:" then begin
      (* the URL runs to a space, or to ": " (the trace's own) *)
      let rec stop j = if j >= n || m.[j] = ' ' || (m.[j] = ':' && j + 1 < n && m.[j + 1] = ' ') then j else stop (j + 1) in
      let j = stop i in
      if j - i <= 80 then Buffer.add_string b (String.sub m i (j - i))
      else begin
        let mime = match String.index_from_opt m i ';', String.index_from_opt m i ',' with
          | Some k, Some c when k < c -> String.sub m i (k - i)
          | _, Some c when c < j -> String.sub m i (c - i)
          | _ -> "data:" in
        Buffer.add_string b (Printf.sprintf "%s (%d bytes)" mime (j - i))
      end;
      go j
    end else (Buffer.add_char b m.[i]; go (i + 1)) in
  go 0;
  Buffer.contents b

let trace fmt = Printf.ksprintf (fun m ->
    if debug then begin
      let m = short_data m in
      (* the kernel's log keeps lines of 190 bytes or so: longer ones in parts *)
      let t = (now () -. t_start) *. 1000. and part = 150 in
      let rec go i =
        if i < String.length m then begin
          Mynos.log (Printf.sprintf "ariadne %6.0f: %s%s\n" t (if i = 0 then "" else "... ")
                       (String.sub m i (min part (String.length m - i))));
          go (i + part)
        end in
      if m = "" then Mynos.log (Printf.sprintf "ariadne %6.0f:\n" t) else go 0
    end) fmt

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

let source_key = function
  | Style.Inline_sheet (t, m) -> "s" ^ Option.value m ~default:"" ^ "\000" ^ t
  | Style.Linked (h, m) -> "l" ^ Option.value m ~default:"" ^ "\000" ^ h

(* the sheets of [doc] as it is now; [wait]: links fetched now (the page's
   own, when it loads), else in the background *)
let current_sheets ?(wait = false) c doc =
  List.concat_map (fun src ->
      let k = source_key src in
      match Mutex.protect sheets_lock (fun () -> Hashtbl.find_opt c.parsed k) with
      | Some s -> s
      | None ->
        let store s = Mutex.protect sheets_lock (fun () -> Hashtbl.replace c.parsed k s) in
        match src with
        | Style.Inline_sheet (t, media) ->
          let s = with_imports ~base:c.sheet_base ~depth:0 ?media t in store s; s
        | Style.Linked (href, media) ->
          let u = Url.resolve c.sheet_base href in
          let get () = match fetch_css u with Some t -> with_imports ~base:u ~depth:0 ?media t | None -> [] in
          if wait then (let s = get () in store s; s)
          else begin
            let start = Mutex.protect sheets_lock (fun () ->
                if Hashtbl.mem c.fetching k then false else (Hashtbl.replace c.fetching k (); true)) in
            if start then
              ignore (Thread.create (fun () ->
                  trace "sheet %s: added by a script, fetching" u;
                  let s = get () in
                  trace "sheet %s: %d rules" u (List.fold_left (fun a (sh : Style.sheet) -> a + List.length sh.rules) 0 s);
                  Mutex.protect sheets_lock (fun () -> Hashtbl.replace c.parsed k s; c.arrived <- true)) ());
            []
          end)
    (Style.sources doc)

let load ?post ?html ?base_url ?framed url =
  let t0 = now () in
  (* [html]: a document given (an iframe's srcdoc, about:blank) *)
  let response = match html with
    | Some body -> { Loader.url; status = "200 OK"; content_type = "text/html; charset=utf-8"; body }
    | None -> Loader.load ?post (Url.of_typed url) in
  let t1 = now () in
  let text, _ = Loader.document response in
  let t2 = now () in
  let doc = Html.parse text in
  let t3 = now () in
  let doc_base = Option.value base_url ~default:response.url in
  let base = match Dom.find (fun n -> Dom.is_html n "base" && Dom.attr n "href" <> None) doc with
    | Some b -> Url.resolve doc_base (Option.get (Dom.attr b "href"))
    | None -> doc_base in
  let css = { sheet_base = base; parsed = Hashtbl.create 16; fetching = Hashtbl.create 4; arrived = false } in
  let sheets = current_sheets ~wait:true css doc in
  let t4 = now () in
  (* the page's scripts (Scripts: jsd), before the cascade *)
  let fetch_script u =
    match Loader.load u with
    | r when Loader.ok r -> Some (snd (Encoding.to_utf8 ?transport:(Encoding.charset_of_content_type r.content_type) r.body))
    | _ -> None in
  let scripts = Scripts.run ?framed ~log:(fun m -> trace "%s" m) ~url:response.url ~base ~width:878 ~height:600
      ~fetch:fetch_script ~cookies_get:Loader.script_cookies ~cookies_set:Loader.script_set_cookie
      ~sheets:(fun () -> current_sheets css doc) doc in
  let t5 = now () in
  let title = match Dom.find (fun n -> Dom.is_html n "title") doc with
    | Some t -> String.trim (Text.collapse (Dom.text_content t)) | None -> "" in
  let ms a b = (b -. a) *. 1000. in
  trace "page %s: load %.0f, decode %.0f, parse %.0f, css %.0f ms (%d sheets), scripts %.0f ms" url
    (ms t0 t1) (ms t1 t2) (ms t2 t3) (ms t3 t4) (List.length sheets) (ms t4 t5);
  { response; doc; base; sheets; css; title; laid = None; last = None; styled = None; pics = Hashtbl.create 16;
    started = Hashtbl.create 16; hurried = Hashtbl.create 16;
    sized = 0; laid_sized = 0;
    console = (match scripts with Some (r, _) -> r.Scripts.console | None -> "");
    session = Option.map snd scripts; frames = Hashtbl.create 2; t_relayout = 0.; t_changed = 0.;
    times = [ "load", ms t0 t1; "decode", ms t1 t2; "parse", ms t2 t3; "css", ms t3 t4; "scripts", ms t4 t5 ] }

(* a picture's URL: a data: URL as it is (an inline svg's), else resolved *)
let resolve_pic l src = if String.starts_with ~prefix:"data:" src then src else Url.resolve l.base src

(* a picture's own size, if it has arrived *)
let pic_size l src =
  let u = resolve_pic l src in
  Mutex.protect pics_lock (fun () -> match Hashtbl.find_opt l.pics u with
      | Some (Some p) -> Some (p.nw, p.nh) | _ -> None)

let layout_at l ~width ~height =
  match l.laid with
  | Some (w, p) when w = width -> p
  | _ ->
    let t0 = now () in
    let styles = match l.styled with
      | Some (w, s) when w = width -> s
      | _ ->
        (* the sheets as the document is now: scripts may have added some *)
        l.sheets <- current_sheets l.css l.doc;
        let s = Style.compute ~width ~height l.sheets l.doc in l.styled <- Some (width, s); s in
    let t1 = now () in
    l.laid_sized <- Mutex.protect pics_lock (fun () -> l.sized);
    let p = Layout.layout ~image:(pic_size l) ~width ~height styles l.doc in
    trace "laid out %d wide: cascade %.0f, layout %.0f ms" width ((t1 -. t0) *. 1000.) ((now () -. t1) *. 1000.);
    l.laid <- Some (width, p);
    l.last <- Some p;
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
           let u = resolve_pic l src in
           let fresh = Mutex.protect pics_lock (fun () -> register l u) in
           if fresh then (incr n; enqueue (Fetch (l, u)))
         | _ -> ());
      true)

(* a background picture's own size, if it has arrived; met for the first
   time (on screen), fetched before the others *)
let pic_natural l src =
  let u = resolve_pic l src in
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
  let u = resolve_pic l src in
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
      | None ->
        (* not met before (an inline svg's): fetched first *)
        if Hashtbl.length l.pics < max_pics && register l u then begin
          Hashtbl.replace l.hurried u (); first := true
        end;
        None) in
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

(* ---- iframes ---- *)

(* a page gone: its scripts closed, and its frames' (their loads under way
   dropped) *)
let rec close_page l =
  Option.iter Scripts.close l.session;
  let kids = Mutex.protect frames_lock (fun () ->
      Hashtbl.fold (fun _ f acc -> f.gen <- f.gen + 1; let c = f.child in f.child <- None; c :: acc) l.frames []) in
  List.iter (Option.iter close_page) kids

(* what an iframe's attributes ask for: srcdoc first, then src *)
let frame_source l (node : Dom.node) =
  match Dom.attr node "srcdoc" with
  | Some h -> Srcdoc h
  | None ->
    match Dom.attr node "src" with
    | Some s when String.trim s <> "" && String.trim s <> "about:blank" -> Src (Url.resolve l.base (String.trim s))
    | _ -> Blank

(* the frame's current source loaded, in a thread of its own; the page it
   showed closed *)
let start_frame f =
  let old = Mutex.protect frames_lock (fun () ->
      f.gen <- f.gen + 1; let c = f.child in f.child <- None; c) in
  Option.iter close_page old;
  f.started <- false; f.fscroll <- 0;
  let gen = f.gen and src = f.current in
  ignore (Thread.create (fun () ->
      let c = match src with
        | Src u -> load ~framed:true u
        | Srcdoc h -> load ~framed:true ~html:h ~base_url:f.fbase "about:srcdoc"
        | Blank -> load ~framed:true ~html:"" ~base_url:f.fbase "about:blank" in
      let keep = Mutex.protect frames_lock (fun () ->
          if f.gen = gen then (f.child <- Some c; true) else false) in
      if not keep then close_page c) ())

(* a page's origin, serialized: its URL's ("https://host[:port]") for
   http(s); a srcdoc's or about:blank's, its parent's (its base); else
   opaque, "null" (the HTML Standard's) *)
let origin_of l =
  let u = if l.response.url = "about:srcdoc" || l.response.url = "about:blank" then l.base else l.response.url in
  match Url.scheme_of u with
  | Some ("http" | "https") -> fst (Url.split u)
  | _ -> "null"

(* messages between a page and a frame of it (each a context of its own):
   the page's to the frame, the frame's to the page ("parent") or to the
   top; each delivered only where its target origin allows *)
let route_messages ~top l (node : Dom.node) c =
  let allowed target_origin receiver =
    target_origin = "*" || target_origin = "/" || fst (Url.split target_origin) = origin_of receiver in
  match l.session, c.session with
  | Some ps, Some cs ->
    let h = Dom_api.handle ps.Scripts.dom node in
    let down, rest = List.partition (fun (t, _, _) -> t = "frame:" ^ h) ps.dom.outbox in
    ps.dom.outbox <- rest;
    List.iter (fun (_, data, o) ->
        if allowed o c then begin
          trace "message to the frame %s: %s" c.response.url data;
          Scripts.message cs ~data ~origin:(origin_of l) ~source:"parent"
        end) (List.rev down);
    let up, rest = List.partition (fun (t, _, _) -> t = "parent" || t = "top") cs.dom.outbox in
    cs.dom.outbox <- rest;
    List.iter (fun (t, data, o) ->
        let receiver = if t = "top" then top else l in
        let source = if receiver == l then "frame:" ^ h else "none" in
        match receiver.session with
        | Some rs when allowed o receiver ->
          trace "message from the frame %s: %s" c.response.url data;
          Scripts.message rs ~data ~origin:(origin_of c) ~source
        | _ -> ()) (List.rev up)
  | _ -> ()

(* an iframe's frame (the tree held): made, and loaded, when first met;
   loaded again when its attributes ask for something else *)
let frame_of l (node : Dom.node) =
  let asked = frame_source l node in
  match Hashtbl.find_opt l.frames node.Dom.id with
  | Some f ->
    if f.asked <> asked then (f.asked <- asked; f.current <- asked; start_frame f);
    f
  | None ->
    let f = { asked; current = asked; fbase = l.base; gen = 0; child = None; started = false;
              fscroll = 0; fw = 300; fh = 150 } in
    Hashtbl.replace l.frames node.Dom.id f;
    start_frame f;
    f

(* a page shown (the window's, or a frame's): its scripts' layout is the
   window's, at the size it is shown; their timers; its pictures *)
let attach l ~width ~height =
  (match l.session with
   | Some s ->
     let seen = ref s.Scripts.dom.version in
     s.layout <- (fun () ->
         if s.dom.version <> !seen then (seen := s.dom.version; l.laid <- None; l.styled <- None);
         let page = layout_at l ~width:(width ()) ~height:(height ()) in
         (page, match l.styled with
           | Some (_, st) -> st
           | None -> Style.compute ~width:(width ()) ~height:(height ()) l.sheets l.doc));
     Scripts.start s
   | None -> ());
  fetch_pictures l

(* a shown page, each frame: laid out again when pictures' sizes it waited
   for arrived (at most every second), when a sheet a script asked for
   arrived, when its scripts changed it (at most every second: scripts
   that keep changing it, ads...) *)
let refresh l ~locked =
  (match l.laid with
   | Some (_, p) when p.unsized <> [] && now () -. l.t_relayout > 1.
                      && Mutex.protect pics_lock (fun () -> l.sized) <> l.laid_sized ->
     l.t_relayout <- now (); l.laid <- None
   | _ -> ());
  if locked && Mutex.protect sheets_lock (fun () -> let a = l.css.arrived in l.css.arrived <- false; a)
  then (l.laid <- None; l.styled <- None);
  match l.session with
  | Some s when locked && s.Scripts.dom.changed && now () -. l.t_changed >= 1. ->
    ignore (Scripts.changed s);
    l.t_changed <- now ();
    l.laid <- None; l.styled <- None
  | _ -> ()

let offset = ref 0          (* how far the page is scrolled, as last drawn *)

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
  (* an event for the page's scripts: whether its default action stays *)
  let event node typ =
    match st.shown.session with Some s -> Scripts.event s node typ | None -> true in
  let submit ?submitter node =
    match Forms.form_of node with
    | Some form when event form "submit" ->
      let submitter = match submitter with Some s -> Some s | None -> Forms.default_button form in
      (match Forms.submit ~base:st.shown.base ?submitter form with
       | Forms.Get url -> go url
       | Forms.Post (url, body) -> go ~post:body url)
    | _ -> () in
  let view_h = ref 600 in
  (* the frames drawn: their visible box, and their page's origin on the
     screen (the innermost first) *)
  let frames_drawn : (int * int * int * int * frame * loaded * Layout.page * int * int) list ref = ref [] in
  if first <> "about:start" then go first;
  Gui.run ~title:"Ariadne" ~tick:0.1 ~resizable:(400, 300) 900 640 st (fun ui st ->
      (* the page's tree, unless its scripts have it now: then the page as
         last laid out, and nothing done to the tree this frame *)
      let locked = Mutex.try_lock Scripts.dom_lock in
      Fun.protect ~finally:(fun () -> if locked then Mutex.unlock Scripts.dom_lock) (fun () ->
      let t_frame = now () in
      let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
      (* a page arrived: shown, if it is the one asked for last *)
      (match Mutex.protect lock (fun () -> !arrived) with
       | Some (n, l) when not (match st.loading with Some (_, m) -> m = n | None -> false) ->
         close_page l
       | _ -> ());
      (match (if locked then Mutex.protect lock (fun () -> let a = !arrived in arrived := None; a) else None) with
       | Some (n, l) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
         let asked = match st.loading with Some (u, _) -> u | None -> l.response.url in
         close_page st.shown;
         st.shown <- l; st.loading <- None;
         attach l ~width:(fun () -> !page_width) ~height:(fun () -> !view_h);
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
      refresh st.shown ~locked;
      view_h := box_h;
      let page =
        if locked then layout_at st.shown ~width:!page_width ~height:box_h
        else match st.shown.last with
          | Some p -> p
          | None -> Layout.layout ~width:!page_width ~height:box_h (Style.compute ~width:1 ~height:1 [] (Dom.document ()))
                      (Dom.document ()) in
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
      (* typing changes the tree: only while the frame holds it *)
      (match (if locked then st.focus else None) with
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
         if !v <> Forms.value node then (Forms.set_value node !v; ignore (event node "input"));
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
      (* the frames drawn last frame: the one under the pointer (the
         innermost); the link there in its page *)
      let frame_at mx my =
        List.find_opt (fun (x0, y0, x1, y1, _, _, _, _, _) -> mx >= x0 && mx < x1 && my >= y0 && my < y1) !frames_drawn in
      let link_in (cp : Layout.page) x y =
        Array.fold_left (fun found (k : Layout.link) ->
            if x >= k.lx && x < k.lx + k.lw && y >= k.ly && y < k.ly + k.lh then Some k else found) None cp.links in
      (* the wheel over a frame whose page is taller: that page scrolls *)
      (if ui.Gui.wheel <> 0 then
         match frame_at ui.Gui.mx ui.Gui.my with
         | Some (_, _, _, _, f, _, cp, _, _) when cp.height > f.fh ->
           f.fscroll <- max 0 (min (cp.height - f.fh) (f.fscroll + ui.Gui.wheel * 48));
           ui.Gui.wheel <- 0
         | _ -> ());
      let top_ref = ref box_y in
      let t_paint = now () and drawn = ref 0 in
      (* a page's items, its origin on the screen at (ox, oy), drawn where
         they are within the band vy0..vy1; an iframe's document drawn in
         its box (a page of its own: paint_frame) *)
      let rec paint_items l (page : Layout.page) ~ox ~oy ~vy0 ~vy1 ~depth =
      Array.iter (fun (it : Layout.item) ->
          match it with
          | Frame { x; y; w; h; node; clip } ->
            let clip = Option.map (fun (a, b, c, d) -> (ox + a, oy + b, ox + c, oy + d)) clip in
            paint_frame l node ~sx:(ox + x) ~sy:(oy + y) ~w ~h ~clip ~vy0 ~vy1 ~depth
          | Fill { x; y; w; h; color } ->
            let yy = oy + y in
            if yy + h > vy0 && yy < vy1 && w > 0 && h > 0 then
              (incr drawn; Gfx.fill g (ox + x) yy w h color)
          | Text { x; y; s; color; font } ->
            (* y is the baseline: each glyph's mask, from the fonts *)
            let yy = oy + y in
            if yy + font.descent > vy0 && yy - font.ascent < vy1 then begin
              incr drawn;
              match font.ttf with
              | Some _ ->
                List.iter (fun (dx, dy, (b : Ttf.bitmap)) ->
                    Gfx.draw_mask g (ox + x + dx) (yy + dy)
                      { Gfx.mask_width = b.width; mask_height = b.height; grey = b.grey } color)
                  (Fonts.glyphs font s)
              | None -> ignore (Gfx.text g (ox + x) (yy - font.ascent) s color)
            end
          | Image { x; y; w; h; src; clip } ->
            let yy = oy + y in
            if yy + h > vy0 && yy < vy1 then
              (match pic_image l src w h with
              | Some img ->
                (match clip with
                 | Some (x0, y0, x1, y1) ->
                   Gfx.with_clip (ox + x0) (oy + y0) (x1 - x0) (y1 - y0)
                     (fun () -> Gfx.draw_image g (ox + x) yy img)
                 | None -> Gfx.draw_image g (ox + x) yy img)
              | None -> ())
          | Control { x; y; w; h; node; font; color; paint } ->
            let sx = ox + x and sy = oy + y in
            if paint && sy + h > vy0 && sy < vy1 && w > 2 && h > 2 then begin
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
          | Gradient { x; y; w; h; g = gr; clip } ->
            let yy = oy + y in
            if yy + h > vy0 && yy < vy1 && w > 0 && h > 0 then begin
              incr drawn;
              let cx0, cy0, cx1, cy1 = Option.value clip ~default:(min_int, min_int, max_int, max_int) in
              List.iter (fun (bx, by, bw, bh, c) ->
                  let x0 = max bx cx0 and y0 = max by cy0 in
                  let x1 = min (bx + bw) cx1 and y1 = min (by + bh) cy1 in
                  if x1 > x0 && y1 > y0 && c lsr 24 <> 0 then
                    Gfx.fill g (ox + x0) (oy + y0) (x1 - x0) (y1 - y0) (c land 0xFFFFFF))
                (Layout.bands ~x ~y ~w ~h gr)
            end
          | Bg { x; y; w; h; layer; tint; clip } ->
            let yy = oy + y in
            (match layer.image with
             | Some src when yy + h > vy0 && yy < vy1 && w > 0 && h > 0 ->
               (match pic_natural l src with
                | Some natural ->
                  (* the box, within its clip *)
                  let x0, y0, x1, y1 = match clip with
                    | Some (a, b, c, d) -> (max a x, max b y, min c (x + w), min d (y + h))
                    | None -> (x, y, x + w, y + h) in
                  if x1 > x0 && y1 > y0 then
                    Gfx.with_clip (ox + x0) (oy + y0) (x1 - x0) (y1 - y0) (fun () ->
                        List.iter (fun (tx, ty, tw, th) ->
                            if oy + ty + th > vy0 && oy + ty < vy1 then
                              match pic_image l src tw th with
                              | Some img -> Gfx.draw_image ?tint g (ox + tx) (oy + ty) img
                              | None -> ())
                          (Layout.tiles ~x ~y ~w ~h layer ~natural))
                | None -> ())
             | _ -> ())) page.items
      and paint_frame l node ~sx ~sy ~w ~h ~clip ~vy0 ~vy1 ~depth =
        let x0, y0, x1, y1 = match clip with
          | Some (a, b, c, d) -> (max sx a, max sy b, min (sx + w) c, min (sy + h) d)
          | None -> (sx, sy, sx + w, sy + h) in
        let y0 = max y0 vy0 and y1 = min y1 vy1 in
        (* made, or loaded again, only with the tree held *)
        let f = if locked then Some (frame_of l node) else Hashtbl.find_opt l.frames node.Dom.id in
        match f with
        | Some f when depth < 4 ->
          f.fw <- w; f.fh <- h;
          (match Mutex.protect frames_lock (fun () -> f.child) with
           | Some c ->
             if locked && not f.started then begin
               f.started <- true;
               attach c ~width:(fun () -> f.fw) ~height:(fun () -> f.fh);
               (* its document loaded: the iframe's load event, in its page *)
               Option.iter (fun ps -> ignore (Scripts.event ps node "load")) l.session
             end;
             refresh c ~locked;
             if locked then route_messages ~top:st.shown l node c;
             (match c.session with
              | Some s when locked && s.Scripts.dom.navigation <> None ->
                (* its scripts navigated: the frame goes there *)
                let u, _ = Option.get s.dom.navigation in
                s.dom.navigation <- None;
                f.current <- Src u; start_frame f
              | _ ->
                let cp = if locked then Some (layout_at c ~width:w ~height:h) else c.last in
                match cp with
                | Some cp when x1 > x0 && y1 > y0 ->
                  f.fscroll <- max 0 (min f.fscroll (cp.height - h));
                  (match c.session with
                   | Some s when locked -> s.Scripts.view <- (w, h); Scripts.scrolled_to s (0, f.fscroll)
                   | _ -> ());
                  let cox = sx and coy = sy - f.fscroll in
                  frames_drawn := (x0, y0, x1, y1, f, c, cp, cox, coy) :: !frames_drawn;
                  Gfx.with_clip x0 y0 (x1 - x0) (y1 - y0) (fun () ->
                      Option.iter (Gfx.fill g x0 y0 (x1 - x0) (y1 - y0)) cp.canvas;
                      paint_items c cp ~ox:cox ~oy:coy ~vy0:y0 ~vy1:y1 ~depth:(depth + 1))
                | _ -> ())
           | None -> ())
        | _ -> () in
      Gui.scroll ~colour:page.background ui 2 box_x box_y box_w box_h (fun top ->
          top_ref := top;
          offset := box_y - top;
          frames_drawn := [];
          paint_items st.shown page ~ox:box_x ~oy:top ~vy0:box_y ~vy1:(box_y + box_h) ~depth:0;
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
      (match frame_at ui.Gui.mx ui.Gui.my with
       | Some (_, _, _, _, _, c, cp, cox, coy) ->
         st.hover <- Option.map (fun (k : Layout.link) -> Url.resolve c.base k.href)
             (link_in cp (ui.Gui.mx - cox) (ui.Gui.my - coy))
       | None -> ());
      if st.hover <> None then ui.Gui.pointer <- Display.Hand;
      (match control_at ui.Gui.mx ui.Gui.my with
       | Some (node, _, _, _, _, _) when st.popup = None ->
         (match Forms.kind node with
          | Forms.Field _ | Forms.Area -> ui.Gui.pointer <- Display.Text
          | _ -> ())
       | _ -> ());
      if List.mem "\027" ui.Gui.keys then st.popup <- None;
      (* a click: an event for the scripts at what is under it (the
         innermost element with a box there: Layout.element_at); its
         default action unless they prevent it *)
      (* a click in a frame: its scripts' event, its link (the frame goes
         there; the window, for _top, _parent, _blank) *)
      let frame_clicked =
        ui.Gui.clicked && st.popup = None && (let px, py = ui.Gui.press in frame_at px py <> None) in
      (if frame_clicked && locked then
         let px, py = ui.Gui.press in
         match frame_at px py with
         | Some (_, _, _, _, f, c, cp, cox, coy) ->
           st.focus <- None;
           let x = px - cox and y = py - coy in
           let allowed = match c.session with
             | Some s -> (match Layout.element_at () cp ~x ~y with Some n -> Scripts.event s n "click" | None -> true)
             | None -> true in
           (match link_in cp x y, link_in cp (ui.Gui.mx - cox) (ui.Gui.my - coy) with
            | Some k, Some k2 when allowed && k.href = k2.href ->
              let url = Url.resolve c.base k.href in
              let target = match Dom.attr k.anode "target" with
                | Some t -> String.lowercase_ascii (String.trim t) | None -> "" in
              (match Url.scheme_of url with
               | Some ("mailto" | "javascript" | "tel") -> ()
               | _ ->
                 if List.mem target [ "_top"; "_parent"; "_blank" ] then go url
                 else (f.current <- Src url; start_frame f))
            | _ -> ())
         | None -> ());
      let page_clicked = ui.Gui.clicked && not frame_clicked in
      let click_target mx my =
        if my < box_y || my >= box_y + box_h then None
        else Layout.element_at () page ~x:(mx - box_x) ~y:(my - !top_ref) in
      let allowed =
        if page_clicked && locked && st.popup = None && st.shown.session <> None then
          let px, py = ui.Gui.press in
          match click_target px py with Some n -> event n "click" | None -> true
        else true in
      let control_clicked =
        page_clicked && locked && (st.popup <> None
                           || (let px, py = ui.Gui.press in control_at px py <> None)) in
      (if control_clicked && allowed then begin
         let px, py = ui.Gui.press in
         match st.popup with
         | Some (sel, _, _, _, _) ->
           (match popup_at px py with Some o -> Forms.select sel o; ignore (event sel "change") | None -> ());
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
              | Forms.Check | Forms.Radio -> Forms.toggle node; ignore (event node "change"); st.focus <- None
              | Forms.Button { submit = true; _ } -> st.focus <- None; submit ~submitter:node node
              | Forms.Select -> st.focus <- None; st.popup <- Some (node, x, y + h, w, font)
              | _ -> ())
           | _ -> ()
       end
       else if page_clicked then st.focus <- None);
      (if page_clicked && not control_clicked && allowed then
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
      (* the scripts: the viewport as it is now (their observers, scroll
         events), and a scroll they asked for *)
      (* a script asked to go elsewhere (location.href = ..., assign,
         replace, reload): once its run is over, as browsers do *)
      (match st.shown.session with
       | Some s when locked && s.Scripts.dom.navigation <> None ->
         let url, replace = Option.get s.dom.navigation in
         s.dom.navigation <- None;
         if replace then (st.want_scroll <- Some 0; st.focus <- None; st.popup <- None; start url)
         else go url
       | _ -> ());
      (match st.shown.session with
       | Some s when locked ->
         s.Scripts.view <- (!page_width, box_h);
         Scripts.scrolled_to s (0, !offset);
         (match s.want_scroll with
          | Some (_, y) -> s.want_scroll <- None; Gui.scroll_to ui 2 (min y (max 0 (page.height - box_h)))
          | None -> ())
       | _ -> ());
      (* the status line *)
      Gfx.fill g 0 (height - 22) width 22 0xE8EDF2;
      let status = match st.loading, st.hover with
        | Some (u, _), _ -> "loading " ^ u ^ "..."
        | None, Some h -> h
        | None, None ->
          (if st.shown.title <> "" then st.shown.title ^ "  \xc2\xb7  " else "") ^ st.shown.response.status
          ^ (if not locked then "  \xc2\xb7  scripts running..." else "") in
      ignore (Gfx.text ~max:((width - 16) / Gfx.char_w) g 8 (height - 19) status Gui.muted);
      if now () -. t_frame > 0.05 then
        trace "frame %.0f ms: before the page %.0f, the page %.0f (%d items drawn of %d)"
          ((now () -. t_frame) *. 1000.) ((t_paint -. t_frame) *. 1000.) ((t_painted -. t_paint) *. 1000.)
          !drawn (Array.length page.items);
      st))

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | [ "--layout"; url ] -> layout_dump url 800
  | [ "--layout"; url; w ] -> layout_dump url (Option.value (int_of_string_opt w) ~default:800)
  | [ "--time"; url ] -> time url
  | [ "--check-images" ] -> Check_images.run ()
  | [ "--check-js" ] -> Check_js.run ()
  | [ url ] when url <> "" && url.[0] <> '-' -> window (Url.of_typed url)
  | [] -> window "about:start"
  | _ -> usage ()
