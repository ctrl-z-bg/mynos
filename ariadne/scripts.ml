(* A page's scripts (M6): run in jsd, the DOM reached through Ariadne's
   own service, dom/1, which answers jsd's __dom calls with Dom_api's
   operations on the page's tree. Scripts run once the page is parsed and
   its style sheets fetched, before the cascade: in document order, the
   inline ones and those fetched (src); then DOMContentLoaded, load, and
   the timers due within the first second. Nothing else touches the tree
   meanwhile (the page is not shown yet), so no lock is needed on it.
   ARIADNE_NOJS (set to anything) turns scripts off. *)

type _ request = Call : string * string list -> string list request

let call_args = Wire.(pair (field "op" string) (field "args" (list string)))

module Protocol = struct
  let id = "dom/1"
  let summary = "A page's DOM for its scripts (Ariadne's, for jsd's __dom): an operation and its arguments."
  let requests = Ipc.[
      request 0 "call" "A DOM operation (Dom_api: document, query, getAttr, insert...) and its arguments: \
                        its answer (nodes as handle, type, name triples)."
        call_args Wire.(list string) ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with Call (op, args) -> Wire.write w Wire.int 0; Wire.write w call_args (op, args)
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let op, args = Wire.read r call_args in Request (Call (op, args))
    | n -> raise (Wire.Error (Printf.sprintf "dom: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function Call _ -> Wire.(list string)
end

module S = Ipc.Make (Protocol)

let enabled = Sys.getenv_opt "ARIADNE_NOJS" = None

(* the pages with scripts, by session (a page loading and the one shown
   both have one: the first argument of every call says whose); the
   service, started once *)
let sessions : (int, Dom_api.t) Hashtbl.t = Hashtbl.create 8
let lock = Mutex.create ()
let next_sid = ref 0
let service = lazy (
  let name = Printf.sprintf "ariadne-dom.%d" (Mynos.getpid ()) in
  let handler = { S.handle = fun (type a) _caller (r : a request) : a ->
      match r with
      | Call (op, sid :: args) ->
        (match Mutex.protect lock (fun () -> Hashtbl.find_opt sessions (int_of_string sid)) with
         | Some t -> Dom_api.call t op args
         | None -> failwith "no such page"
         | exception Failure _ -> failwith "no such page")
      | Call (_, []) -> failwith "no page" } in
  ignore (Thread.create (fun () -> S.serve name handler) ());
  (* registered by the thread: a moment to be there *)
  Thread.delay 0.05;
  name)

(* ---- a script's requests (fetch, XMLHttpRequest) ---- *)

(* scheme, host and port: an origin ("null" for those without) *)
let origin u =
  match Url.scheme_of u with
  | Some ("http" | "https") ->
    (match Http.parse_url u with
     | tls, host, port, _ ->
       (if tls then "https" else "http") ^ "://" ^ String.lowercase_ascii host
       ^ (if (tls && port = 443) || ((not tls) && port = 80) then "" else ":" ^ string_of_int port)
     | exception Http.Error _ -> "null")
  | Some s -> s ^ ":"
  | None -> "null"

(* a page's request, as __dom("fetch", method, url, headers, has body,
   body): [status; reason; url; body; name; value...]. Another origin's:
   no cookies, its answer readable if it allows it (Access-Control-Allow-
   Origin), and only GET, HEAD, POST (there is no preflight) *)
let fetch_for ~page ~log = function
  | [ meth; url; headers; has_body; body; mode ] ->
    let meth = String.uppercase_ascii meth in
    let url = Url.resolve page url in
    let headers = List.filter_map (fun l ->
        match String.index_opt l ':' with
        | Some i -> Some (String.trim (String.sub l 0 i), String.trim (String.sub l (i + 1) (String.length l - i - 1)))
        | None -> None) (String.split_on_char '\n' headers) in
    let mine = origin page and theirs = origin url in
    (* a data: URL is anyone's (without cookies) *)
    let data = Url.scheme_of url = Some "data" in
    (* a script's src: any origin's (classic scripts are not CORS's), with cookies *)
    let same = mine = theirs || data || mode = "script" in
    if not same && not (List.mem meth [ "GET"; "HEAD"; "POST" ]) then
      failwith ("NetworkError: " ^ meth ^ " to another origin (" ^ theirs ^ ") is not allowed here");
    let headers = if same then headers else ("Origin", mine) :: headers in
    let a = Loader.fetch ~credentials:same ~meth ~headers ?body:(if has_body = "1" then Some body else None) url in
    log (Printf.sprintf "request %s %s: %d %s, %d bytes" meth url a.Loader.a_status a.a_reason (String.length a.a_body));
    if a.Loader.a_status = 0 then failwith ("NetworkError: " ^ a.a_reason);
    if not same then begin
      match List.assoc_opt "access-control-allow-origin" a.a_headers with
      | Some o when String.trim o = "*" || String.trim o = mine -> ()
      | _ -> failwith ("NetworkError: " ^ theirs ^ " does not let " ^ mine ^ " read its answer (CORS)")
    end;
    let ct = Option.value (List.assoc_opt "content-type" a.a_headers) ~default:"" in
    let text = snd (Encoding.to_utf8 ?transport:(Encoding.charset_of_content_type ct) a.a_body) in
    [ string_of_int a.a_status; a.a_reason; a.a_url; text ] @ List.concat_map (fun (k, v) -> [ k; v ]) a.a_headers
  | _ -> failwith "fetch: its arguments"

(* JavaScript's types for <script> (and none: JavaScript) *)
let is_js s =
  match String.lowercase_ascii (String.trim (Option.value (Dom.attr s "type") ~default:"")) with
  | "" | "text/javascript" | "application/javascript" | "application/ecmascript" | "text/ecmascript"
  | "application/x-javascript" | "text/jscript" -> true
  | _ -> false

type report = { ran : int; failed : int; console : string; ms : float; changed : bool }

(* a page's scripts, kept while it is shown: their context, its tree *)
type session = {
  cx : Js.context;
  dom : Dom_api.t;
  sid : int;
  mutable pending : int;                   (* timers waiting *)
  log : string -> unit;
  out : Buffer.t;                          (* console, errors *)
  mutable layout : unit -> Layout.page * Style.styles;   (* a layout of the page as it is now *)
  mutable laid : (int * Layout.page * Layout.index * Style.styles) option;   (* the last, and its version *)
  mutable scroll : int * int;              (* the window's: x, y *)
  mutable view : int * int;                (* the viewport's width, height *)
  mutable want_scroll : (int * int) option;   (* asked by a script (scrollTo) *)
  mutable shown : bool;                    (* the window has told its scroll once (that is not a scroll) *)
  mutable closed : bool;
}

(* the shown page's tree: its scripts' timers (a thread of their own) and
   the window (a frame: layout, events, painting from the tree) take turns
   with it; a page loading has a tree no one else sees *)
let dom_lock = Mutex.create ()

(* ---- what scripts learn of the layout ---- *)

let laid_out s =
  match s.laid with
  | Some (v, page, idx, styles) when v = s.dom.version -> (page, idx, styles)
  | _ ->
    let page, styles = s.layout () in
    let idx = Layout.index page in
    s.laid <- Some (s.dom.version, page, idx, styles);
    (page, idx, styles)

let css_color c =
  if c lsr 24 = 255 then
    Printf.sprintf "rgb(%d, %d, %d)" ((c lsr 16) land 255) ((c lsr 8) land 255) (c land 255)
  else Printf.sprintf "rgba(%d, %d, %d, %g)" ((c lsr 16) land 255) ((c lsr 8) land 255) (c land 255)
      (float (c lsr 24) /. 255.)

let display_name = function
  | Style.None_ -> "none" | Contents -> "contents" | Block -> "block" | Inline -> "inline"
  | Inline_block -> "inline-block" | List_item -> "list-item" | Table -> "table" | Table_row -> "table-row"
  | Table_cell -> "table-cell" | Table_group -> "table-row-group" | Table_caption -> "table-caption"
  | Table_column -> "table-column" | Flex -> "flex" | Inline_flex -> "inline-flex" | Grid -> "grid"
  | Inline_grid -> "inline-grid"

let position_name = function
  | Style.Static -> "static" | Relative -> "relative" | Absolute -> "absolute" | Fixed -> "fixed" | Sticky -> "sticky"

let geometry_of s : Dom_api.geometry =
  let px f = Printf.sprintf "%gpx" f in
  let len (l : Style.length) ~of_ = match l with
    | Style.Len (p, q) -> px (p +. q *. float of_ /. 100.) | Auto -> "auto" in
  let box n =
    let _, idx, styles = laid_out s in
    match Layout.element_box idx n with
    | Some r ->
      let b = match Style.get styles n with
        | Some st -> Array.map int_of_float st.border_width |> fun a ->
          Array.mapi (fun i w -> if st.border_style.(i) then w else 0) a
        | None -> [| 0; 0; 0; 0 |] in
      Some (r.rx, r.ry, r.rw, r.rh, b)
    | None -> None in
  let viewport () =
    let page, _, _ = laid_out s in
    let sx, sy = s.scroll and w, h = s.view in
    (sx, sy, w, h, page.height) in
  let offset_parent (n : Dom.node) =
    let _, _, styles = laid_out s in
    match Style.get styles n with
    | Some st when st.position = Fixed -> None
    | None -> None
    | Some _ ->
      let rec up (x : Dom.node) =
        match x.parent with
        | None -> None
        | Some p when Dom.is_html p "body" -> Some p
        | Some p ->
          (match Style.get styles p with
           | Some ps when ps.position <> Static -> Some p
           | Some _ when Dom.is_html p "td" || Dom.is_html p "th" || Dom.is_html p "table" -> Some p
           | _ -> up p) in
      up n in
  let computed n prop =
    let _, idx, styles = laid_out s in
    match Style.get styles n with
    | None -> ""
    | Some st ->
      let w = match Layout.element_box idx n with Some r -> r.rw | None -> 0 in
      let side i = [| "top"; "right"; "bottom"; "left" |].(i) in
      let find a name = let rec go i = if i = 4 then None else if name = side i then Some a.(i) else go (i + 1) in go 0 in
      match prop with
      | "display" -> display_name st.display
      | "position" -> position_name st.position
      | "visibility" -> if st.visible then "visible" else "hidden"
      | "opacity" -> if st.transparent then "0" else "1"
      | "color" -> css_color (0xFF000000 lor st.color)
      | "background-color" -> css_color st.background
      | "font-size" -> px st.font_size
      | "font-weight" -> string_of_int st.font_weight
      | "font-style" -> if st.italic then "italic" else "normal"
      | "font-family" -> st.font_family
      | "float" -> st.float_
      | "clear" -> st.clear
      | "overflow" -> if st.overflow_clip then "hidden" else "visible"
      | "box-sizing" -> if st.border_box then "border-box" else "content-box"
      | "width" | "height" ->
        (match Layout.element_box idx n with
         | Some r -> px (float (if prop = "width" then r.rw else r.rh))
         | None -> "auto")
      | p when String.length p > 7 && String.sub p 0 7 = "margin-" ->
        (match find st.margin (String.sub p 7 (String.length p - 7)) with Some l -> len l ~of_:w | None -> "")
      | p when String.length p > 8 && String.sub p 0 8 = "padding-" ->
        (match find st.padding (String.sub p 8 (String.length p - 8)) with Some l -> len l ~of_:w | None -> "")
      | p when String.length p > 7 && String.sub p 0 7 = "border-" && String.ends_with ~suffix:"-width" p ->
        (match find st.border_width (String.sub p 7 (String.length p - 13)) with Some f -> px f | None -> "")
      | "z-index" -> "auto"
      | _ -> "" in
  let scroll_to x y = s.want_scroll <- Some (max 0 x, max 0 y) in
  { box; viewport; offset_parent; computed; scroll_to }

let eval s ~name code =
  match Js.eval ~name s.cx code with
  | r ->
    Buffer.add_string s.out r.Js.console;
    (* what the scripts printed, in the trace too (ARIADNE_DEBUG) *)
    List.iteri (fun i l ->
        if i < 20 && l <> "" then
          s.log (Printf.sprintf "console (%s): %s" name (if String.length l > 160 then String.sub l 0 160 else l)))
      (String.split_on_char '\n' r.Js.console);
    if not r.ok then begin
      Buffer.add_string s.out ("error: " ^ r.value ^ "\n");
      s.log (Printf.sprintf "script %s: %s" name (List.hd (String.split_on_char '\n' r.value)))
    end;
    Some r
  | exception e -> s.log ("script " ^ name ^ ": " ^ Printexc.to_string e); None

let refresh_pending s =
  match eval s ~name:"timers" "__pendingTimers()" with
  | Some r when r.ok -> s.pending <- Option.value (int_of_string_opt r.value) ~default:0
  | _ -> ()

(* the window scrolled: the scripts' observers and scroll events *)
let scrolled_to s (x, y) =
  if not s.shown then (s.shown <- true; s.scroll <- (x, y))
  else if s.scroll <> (x, y) then begin
    s.scroll <- (x, y);
    s.log (Printf.sprintf "scroll to %d" y);
    ignore (eval s ~name:"scroll" "__scrolled()");
    refresh_pending s
  end

(* an event at a node (click, input, submit, change): whether its default
   action is still to happen (no preventDefault) *)
let event s (n : Dom.node) typ =
  let h = Dom_api.handle s.dom n in
  let allowed =
    match eval s ~name:typ (Printf.sprintf "__event(%S, %d, %S, %S)" h (Dom_api.node_type n) (Dom_api.node_name n) typ) with
    | Some r when r.ok -> r.value <> "false"
    | _ -> true in
  (* a handler may have set a timer *)
  refresh_pending s;
  allowed

(* the timers due within [ms] *)
let tick s ms =
  (* a run's worth at a time (jsd limits each run), while some are due *)
  let rec go i first =
    match eval s ~name:"timers" (Printf.sprintf "__runTimers(%d)" (if first then ms else 0)) with
    | Some r when r.ok ->
      (match List.map int_of_string_opt (String.split_on_char ' ' r.value) with
       | [ Some due; Some waiting ] ->
         s.pending <- waiting;
         if due > 0 && i < 100 then go (i + 1) false
       | _ -> refresh_pending s)
    | _ -> refresh_pending s in
  go 0 true

(* the page's timers, in a thread of their own while it is shown: every
   100 ms, those due, the tree held (Scripts.dom_lock) *)
let start s =
  ignore (Thread.create (fun () ->
      let last = ref (Unix.gettimeofday ()) in
      while not s.closed do
        Thread.delay 0.1;
        if s.pending > 0 then begin
          Mutex.lock dom_lock;
          Fun.protect ~finally:(fun () -> Mutex.unlock dom_lock) (fun () ->
              if not s.closed then begin
                let now = Unix.gettimeofday () in
                tick s (int_of_float ((now -. !last) *. 1000.));
                last := now
              end)
        end else last := Unix.gettimeofday ()
      done) ())

(* the scripts changed the tree since asked last *)
let changed s = let c = s.dom.changed in s.dom.changed <- false; c

let close s =
  s.closed <- true;
  Js.destroy s.cx;
  Mutex.protect lock (fun () -> Hashtbl.remove sessions s.sid)

(* the page's scripts run; [fetch] gives a script's text by its URL *)
let run ~(log : string -> unit) ~url ~base ~width ~height ~(fetch : string -> string option)
    ?(cookies_get = fun _ -> "") ?(cookies_set = fun _ _ -> ()) ~(sheets : Style.sheet list) (doc : Dom.node) =
  let trace fmt = Printf.ksprintf log fmt in
  let t0 = Unix.gettimeofday () in
  let scripts = ref [] in
  Dom.iter (fun n -> if Dom.is_html n "script" && is_js n then scripts := n :: !scripts) doc;
  let scripts = List.rev !scripts in
  if not enabled || scripts = [] then None
  else
    match Js.connect () with
    | exception _ -> trace "scripts: no jsd"; None
    | js ->
      let name = Lazy.force service in
      let t = Dom_api.create ~cookies:((fun () -> cookies_get url), cookies_set url) ~fetch:(fetch_for ~page:url ~log) doc in
      let sid = Mutex.protect lock (fun () -> incr next_sid; Hashtbl.replace sessions !next_sid t; !next_sid) in
      let cx = Js.create ~js ~dom:name () in
      (* while loading: a layout of its own (no picture sizes yet); the
         window gives it its own when the page is shown *)
      let layout () =
        let styles = Style.compute ~width ~height sheets doc in
        (Layout.layout ~width ~height styles doc, styles) in
      let s = { cx; dom = t; sid; pending = 0; log; out = Buffer.create 256; layout; laid = None;
                scroll = (0, 0); view = (width, height); want_scroll = None; shown = false; closed = false } in
      t.geometry <- geometry_of s;
      let ran = ref 0 and failed = ref 0 in
      let run_one ~name code =
        match eval s ~name code with Some r when not r.ok -> incr failed | _ -> () in
      run_one ~name:"url.js" Js_prelude.url_polyfill;
      run_one ~name:"prelude.js" Js_prelude.source;
      let quote x = "\"" ^ String.concat "\\\"" (String.split_on_char '"' x) ^ "\"" in
      run_one ~name:"init" (Printf.sprintf "__init(%s, %d, %d, %d)" (quote url) width height sid);
      (* a developer's probe (ARIADNE_DEBUG): /disk/ariadne-probe.js, run
         before the page's scripts (it may wrap the APIs they use) *)
      (if Sys.getenv_opt "ARIADNE_DEBUG" <> None then
         match In_channel.with_open_bin "/disk/ariadne-probe.js" In_channel.input_all with
         | probe -> log "probe: /disk/ariadne-probe.js"; run_one ~name:"probe" probe
         | exception Sys_error _ -> ());
      List.iteri (fun i sc ->
          let code, name = match Dom.attr sc "src" with
            | Some src when String.trim src <> "" ->
              let u = Url.resolve base (String.trim src) in
              (fetch u, u)
            | _ -> (Some (Dom.text_content sc), Printf.sprintf "%s#script%d" url (i + 1)) in
          match code with
          | Some code -> incr ran; run_one ~name code
          | None -> trace "script %s: not fetched" name) scripts;
      run_one ~name:"after" "__afterScripts()";
      (* the timers (and the scripts scripts added): the window's, once the
         page is shown, as browsers do: not before showing it *)
      (match eval s ~name:"timers" "__pendingTimers()" with
       | Some r when r.ok -> s.pending <- Option.value (int_of_string_opt r.value) ~default:0
       | _ -> ());
      (* with scripts on, noscript's content is not shown *)
      let noscripts = ref [] in
      Dom.iter (fun n -> if Dom.is_html n "noscript" then noscripts := n :: !noscripts) doc;
      List.iter Dom.remove !noscripts;
      let ms = (Unix.gettimeofday () -. t0) *. 1000. in
      trace "scripts: %d run, %d failed, %.0f ms%s" !ran !failed ms (if t.changed then ", the page changed" else "");
      let report = { ran = !ran; failed = !failed; console = Buffer.contents s.out; ms; changed = t.changed } in
      t.changed <- false;
      Some (report, s)
