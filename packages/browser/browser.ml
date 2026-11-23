(* browser: a simple web browser for MyNOS (phase 1: text and links).

     browser [URL]          a window (the start page without a URL)
     browser --dump URL     the page as text, on the standard output

   HTML is read tolerantly (module Html) and laid out as lines of text
   (module Layout): headings, paragraphs, lists, quotes, tables as rows,
   preformatted text, links. No JavaScript and no CSS: pages that do not
   need them (Wikipedia, Hacker News, the text editions of news sites,
   documentation, blogs, MyNOS's own httpd) read well; the others show
   what their HTML holds. Images show as their [alt] text.

   http, https (MyNOS's TLS), file (a file or a directory of the disk),
   about:start. Redirections are followed (8 at most). A page is fetched
   by a thread, so that the window keeps answering; Stop forgets it. *)

(* ---- URLs ---- *)

let scheme_of u =
  match String.index_opt u ':' with
  | Some i when i > 0 && String.for_all (fun c ->
      match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '+' | '-' | '.' -> true | _ -> false)
      (String.sub u 0 i) -> Some (String.lowercase_ascii (String.sub u 0 i))
  | _ -> None

let strip_fragment u =
  match String.index_opt u '#' with
  | Some i -> (String.sub u 0 i, Some (String.sub u (i + 1) (String.length u - i - 1)))
  | None -> (u, None)

(* "a/b/../c/./d" -> "a/c/d" *)
let remove_dots path =
  let parts = String.split_on_char '/' path in
  let out = List.fold_left (fun acc p ->
      match p with
      | "." -> acc
      | ".." -> (match acc with _ :: rest when rest <> [] -> rest | l -> l)
      | p -> p :: acc) [] parts in
  let r = String.concat "/" (List.rev out) in
  if String.length path > 0 && path.[String.length path - 1] = '/' && r <> ""
     && r.[String.length r - 1] <> '/' then r ^ "/" else r

(* the origin ("https://host:port") and the path of an absolute URL *)
let split_url u =
  match String.index_opt u ':' with
  | None -> (u, "/")
  | Some i ->
    let rest = String.sub u (i + 1) (String.length u - i - 1) in
    if String.length rest >= 2 && String.sub rest 0 2 = "//" then
      match String.index_from_opt rest 2 '/' with
      | Some j -> (String.sub u 0 (i + 1 + j), String.sub rest j (String.length rest - j))
      | None -> (u, "/")
    else (String.sub u 0 (i + 1), rest)

let resolve base href =
  let href = String.trim href in
  if href = "" then base
  else match scheme_of href with
    | Some _ -> href
    | None ->
      let origin, path = split_url (fst (strip_fragment base)) in
      if String.length href >= 2 && String.sub href 0 2 = "//" then
        (match scheme_of base with Some s -> s ^ ":" ^ href | None -> "http:" ^ href)
      else if href.[0] = '/' then origin ^ remove_dots href
      else if href.[0] = '#' then fst (strip_fragment base) ^ href
      else if href.[0] = '?' then
        origin ^ (match String.index_opt path '?' with Some i -> String.sub path 0 i | None -> path) ^ href
      else begin
        let path = match String.index_opt path '?' with Some i -> String.sub path 0 i | None -> path in
        let dir = match String.rindex_opt path '/' with
          | Some i -> String.sub path 0 (i + 1) | None -> "/" in
        origin ^ remove_dots (dir ^ href)
      end

(* what the user typed: a URL, or a host ("example.com"), or a path *)
let known = [ "http"; "https"; "file"; "about"; "mailto"; "javascript"; "tel"; "data"; "ftp" ]

let of_typed s =
  let s = String.trim s in
  if s = "" then "about:start"
  else if (match scheme_of s with Some k -> List.mem k known | None -> false) then s
  else if s.[0] = '/' then "file:" ^ s
  else if s.[0] >= '0' && s.[0] <= '9' || String.starts_with ~prefix:"localhost" s then "http://" ^ s
  else "https://" ^ s

(* ---- fetching ---- *)

type doc = {
  url : string;                     (* after redirections *)
  tokens : Html.token list;
  status : string;                  (* "200 OK", or what happened *)
  mutable styled : (int * Html.token list) option;   (* its CSS applied, for a width *)
}

let user_agent = "MyNOS-browser/1.0 (text; no JavaScript)"

let html_of_text t =
  "<pre>" ^ String.concat "&amp;" (String.split_on_char '&'
     (String.concat "&lt;" (String.split_on_char '<' t))) ^ "</pre>"

let message_page title body =
  Printf.sprintf "<title>%s</title><h1>%s</h1><p>%s</p>" title title body

let start_page = {|<title>MyNOS browser</title>
<h1>The MyNOS browser</h1>
<p>A simple browser, written in OCaml for MyNOS: it reads HTML and shows
its text, links, pictures and forms. No JavaScript, little CSS: the
pages that do not need them read well. Type an address above (Enter
goes), or follow a link.</p>
<h2>Searching</h2>
<ul>
<li><a href="https://lite.duckduckgo.com/lite/">DuckDuckGo lite</a>: a search without JavaScript (Google's needs it)</li>
</ul>
<h2>Pages that read well</h2>
<ul>
<li><a href="https://en.m.wikipedia.org/wiki/OCaml">OCaml, on Wikipedia</a> (the mobile edition)</li>
<li><a href="https://en.m.wikipedia.org/wiki/Microkernel">Microkernel, on Wikipedia</a></li>
<li><a href="https://news.ycombinator.com/">Hacker News</a></li>
<li><a href="https://text.npr.org/">NPR, text only</a></li>
<li><a href="https://lite.cnn.com/">CNN lite</a></li>
<li><a href="https://ocaml.org/">ocaml.org</a></li>
<li><a href="file:/disk/">The disk</a> (files and folders)</li>
</ul>
<h2>Keys</h2>
<p>Page Up, Page Down, the arrows, Home and End scroll the page (when the
address field does not have the keys: click the page). Back and Forward
go through the pages seen; Reload fetches again.</p>|}

let listing dir =
  let es = Gui.entries dir in
  "<title>" ^ dir ^ "</title><h1>" ^ dir ^ "</h1><ul>"
  ^ (if dir <> "/" then "<li><a href=\"../\">..</a></li>" else "")
  ^ String.concat "" (List.map (fun (e : Gui.entry) ->
      Printf.sprintf "<li><a href=\"%s%s\">%s%s</a> %s</li>" e.name (if e.is_dir then "/" else "")
        e.name (if e.is_dir then "/" else "") (if e.is_dir then "" else Gui.size_text e.size)) es)
  ^ "</ul>"

let is_html name ct =
  let ct = String.lowercase_ascii ct in
  Html.contains ct "html" || (ct = "" && (Filename.check_suffix name ".html" || Filename.check_suffix name ".htm"))

(* ---- cookies: in memory, by domain, for this window's life ---- *)

let cookies : (string * string * string) list ref = ref []     (* domain, name, value *)
let cookie_lock = Mutex.create ()

let host_of url =
  match Http.parse_url url with
  | _, host, _, _ -> String.lowercase_ascii host
  | exception _ -> ""

let domain_matches host d = host = d || String.ends_with ~suffix:("." ^ d) host

let take_cookies url (r : Http.response) =
  let host = host_of url in
  List.iter (fun (k, v) ->
      if k = "set-cookie" then
        match List.map String.trim (String.split_on_char ';' v) with
        | nv :: attrs ->
          (match String.index_opt nv '=' with
           | Some i ->
             let name = String.trim (String.sub nv 0 i)
             and value = String.trim (String.sub nv (i + 1) (String.length nv - i - 1)) in
             let attr a = List.find_map (fun x ->
                 let lx = String.lowercase_ascii x in
                 if String.starts_with ~prefix:(a ^ "=") lx then
                   Some (String.sub x (String.length a + 1) (String.length x - String.length a - 1))
                 else None) attrs in
             let domain = match attr "domain" with
               | Some d ->
                 let d = String.lowercase_ascii d in
                 let d = if String.length d > 0 && d.[0] = '.' then String.sub d 1 (String.length d - 1) else d in
                 if domain_matches host d then d else host      (* not another site's *)
               | None -> host in
             let gone = (match attr "max-age" with
                 | Some a -> (match int_of_string_opt a with Some n -> n <= 0 | None -> false)
                 | None -> false) in
             Mutex.protect cookie_lock (fun () ->
                 cookies := List.filter (fun (d, n, _) -> not (d = domain && n = name)) !cookies;
                 if not gone then cookies := (domain, name, value) :: !cookies)
           | None -> ())
        | [] -> ()) r.headers

let cookie_headers url =
  let host = host_of url in
  match Mutex.protect cookie_lock (fun () ->
      List.filter (fun (d, _, _) -> domain_matches host d) !cookies) with
  | [] -> []
  | cs -> [ ("Cookie", String.concat "; " (List.rev_map (fun (_, n, v) -> n ^ "=" ^ v) cs)) ]

(* the style sheets fetched (<link rel=stylesheet>), by URL, for the
   session: a page's are fetched with it, by its thread *)
let sheets : (string, string) Hashtbl.t = Hashtbl.create 16
let sheets_lock = Mutex.create ()

let sheet_of base href =
  Mutex.protect sheets_lock (fun () -> Hashtbl.find_opt sheets (resolve base href))

(* a page's style sheets not fetched yet, each by a thread of its own:
   true if some came *)
let fetch_sheets (d : doc) =
  let todo = List.sort_uniq compare (List.filter_map (fun href ->
      let u = fst (strip_fragment (resolve d.url href)) in
      if Mutex.protect sheets_lock (fun () -> Hashtbl.mem sheets u) then None else Some u)
      (Css.links ~px:1024 d.tokens)) in
  let one u = begin
        let css = match scheme_of u with
          | Some ("http" | "https") ->
            (match Http.get ~timeout:15000
                     ~headers:(("User-Agent", user_agent) :: ("Accept", "text/css,*/*;q=0.1")
                               :: cookie_headers u) u with
             | r when r.Http.status = 200 && String.length r.body <= 2_000_000 -> r.body
             | _ -> ""
             | exception _ -> "")
          | Some "file" ->
            (try In_channel.with_open_bin (String.sub u 5 (String.length u - 5)) In_channel.input_all
             with _ -> "")
          | _ -> "" in
        Mutex.protect sheets_lock (fun () -> Hashtbl.replace sheets u css)
      end in
  List.iter Thread.join (List.map (fun u -> Thread.create one u) todo);
  todo <> []

(* the page's tokens with its CSS applied, for a window [px] wide *)
let styled (d : doc) px =
  match d.styled with
  | Some (w, t) when w = px -> t
  | _ ->
    let t = Css.apply ~px ~sheet:(sheet_of d.url) d.tokens in
    d.styled <- Some (px, t);
    t

let fetch ?body ?(px = 880) url : doc =
  let page u tokens status = { url = u; tokens; status; styled = None } in
  let of_body u ct body status =
    let body = if Html.charset ~content_type:ct body = `Latin1 then Html.latin1_to_utf8 body else body in
    if is_html u ct then page u (Html.tokens body) status
    else if Html.contains (String.lowercase_ascii ct) "text" || ct = "" then
      page u (Html.tokens (html_of_text body)) status
    else page u (Html.tokens (message_page "Not a page"
                                (Printf.sprintf "This is %s, %d bytes: the browser shows only text for now."
                                   ct (String.length body)))) status in
  let rec go ?body u n =
    let u, _ = strip_fragment u in
    match scheme_of u with
    | Some "about" -> page u (Html.tokens start_page) "about"
    | Some "file" ->
      let path = String.sub u 5 (String.length u - 5) in
      let path = if String.length path > 2 && String.sub path 0 2 = "//" then String.sub path 2 (String.length path - 2) else path in
      let path = if path = "" then "/" else path in
      if Sys.file_exists path && Sys.is_directory path then
        page u (Html.tokens (listing path)) "a folder"
      else (match In_channel.with_open_bin path In_channel.input_all with
          | body -> of_body u "" body "a file"
          | exception Sys_error m -> page u (Html.tokens (message_page "Cannot open" m)) m)
    | Some ("http" | "https") ->
      let headers = ("User-Agent", user_agent)
                    :: ("Accept", "text/html,text/plain;q=0.9,*/*;q=0.5") :: cookie_headers u in
      let answer = match body with
        | Some b -> Http.post ~timeout:20000
                      ~headers:(("Content-Type", "application/x-www-form-urlencoded") :: headers) ~body:b u
        | None -> Http.get ~timeout:20000 ~headers u in
      (match answer with
       | r when (take_cookies u r; r.Http.status >= 300 && r.status < 400 && n < 8) ->
         (* a redirection: a GET, the form's data not sent again *)
         (match Http.header "location" r with
          | Some l -> go (resolve u l) (n + 1)
          | None -> of_body u (Option.value (Http.header "content-type" r) ~default:"") r.body
                      (Printf.sprintf "%d %s" r.status r.reason))
       | r -> of_body u (Option.value (Http.header "content-type" r) ~default:"") r.body
                (Printf.sprintf "%d %s" r.status r.reason)
       | exception Http.Error m -> page u (Html.tokens (message_page "Not reached" (u ^ ": " ^ m))) m
       | exception e -> page u (Html.tokens (message_page "Not reached" (Printexc.to_string e))) "error")
    | Some s -> page u (Html.tokens (message_page "Not a web address"
                                       ("The browser does not open " ^ s ^ ": addresses."))) s
    | None -> go ?body (of_typed u) n in
  let d = go ?body url 0 in
  (* its CSS, with the sheets known so far, here in the fetching thread *)
  ignore (styled d px);
  d

(* ---- --dump: the page as text ---- *)

let dump url =
  let t0 = Unix.gettimeofday () in
  let d = fetch ~px:(78 * 8) (of_typed url) in
  let t1 = Unix.gettimeofday () in
  if fetch_sheets d then d.styled <- None;
  let t2 = Unix.gettimeofday () in
  ignore (styled d (78 * 8));
  let t = Unix.gettimeofday () in
  (* BROWSER_TIMES=1: where the time went, on the error output *)
  if Sys.getenv_opt "BROWSER_TIMES" <> None then
    Printf.eprintf "browser: page %.0f ms, %d style sheets %.0f ms, CSS %.0f ms (%d tokens)\n%!"
      ((t1 -. t0) *. 1000.) (List.length (Css.links ~px:1024 d.tokens)) ((t2 -. t1) *. 1000.)
      ((t -. t2) *. 1000.) (List.length d.tokens);
  let p = Layout.layout ~width:78 (styled d (78 * 8)) in
  if Sys.getenv_opt "BROWSER_TIMES" <> None then
    Printf.eprintf "browser: layout %.0f ms\n%!" ((Unix.gettimeofday () -. t) *. 1000.);
  if p.Layout.title <> "" then Printf.printf "%s\n\n" p.title;
  print_string (Layout.to_text p);
  (* its links, numbered as lynx does *)
  let links = ref [] in
  Array.iter (fun (l : Layout.line) ->
      List.iter (fun (s : Layout.span) -> match s.style.link with
          | Some h when not (List.mem h !links) -> links := h :: !links
          | _ -> ()) l.spans) p.lines;
  if !links <> [] then begin
    print_string "\nLinks:\n";
    List.iteri (fun i h -> Printf.printf "%3d. %s\n" (i + 1) (resolve d.url h)) (List.rev !links)
  end

(* ---- the window ---- *)

type st = {
  mutable doc : doc;
  mutable laid : (int * Layout.page) option;   (* the width it was laid out for *)
  mutable address : string;
  mutable back : (string * int) list;           (* url, scroll *)
  mutable forward : (string * int) list;
  mutable loading : (string * int) option;      (* a fetch running: its number *)
  mutable want_scroll : int option;
  mutable offset : int;                         (* the page's scroll, as drawn *)
  mutable hover : string option;
  values : (int * int, string * bool) Hashtbl.t;   (* the forms' fields, as changed *)
  mutable focus : (int * int) option;             (* the field that has the keys *)
  mutable cursor : int;                           (* in it: the characters before *)
  mutable first : int;                            (* the first character shown *)
}

(* application/x-www-form-urlencoded *)
let urlencode s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
      | 'A'..'Z' | 'a'..'z' | '0'..'9' | '-' | '_' | '.' | '~' -> Buffer.add_char b c
      | ' ' -> Buffer.add_char b '+'
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c))) s;
  Buffer.contents b

let value_of st (f : Layout.field) w =
  match Hashtbl.find_opt st.values w with Some v -> v | None -> (f.value, f.checked)

(* a form's data: its fields' names and values, the button pressed's *)
let form_data st (page : Layout.page) fi submitter =
  let f = page.forms.(fi) in
  let pairs = List.concat (List.mapi (fun k (fl : Layout.field) ->
      let v, c = value_of st fl (fi, k) in
      if fl.fname = "" then []
      else match fl.kind with
        | Hidden | Text | Password | Textarea | Select -> [ (fl.fname, v) ]
        | Checkbox | Radio -> if c then [ (fl.fname, v) ] else []
        | Submit -> if submitter = Some k then [ (fl.fname, fl.value) ] else [])
      (Array.to_list f.fields)) in
  String.concat "&" (List.map (fun (k, v) -> urlencode k ^ "=" ^ urlencode v) pairs)

let lock = Mutex.create ()
let fetched : (int * doc) option ref = ref None
let fetches = ref 0

(* ---- pictures: fetched by a thread, after the page; PNG and JPEG ---- *)

type picture = Loading | Ready of Image.t | Failed

let pictures : (string, picture) Hashtbl.t = Hashtbl.create 32
let pictures_done = Atomic.make 0              (* a picture came: lay out again *)
let sheets_done = Atomic.make 0                (* a page's style sheets came: style it again *)
let scaled : (string * int * int, Gfx.t) Hashtbl.t = Hashtbl.create 32

(* the bytes of a URL: file:, http:, https: (redirections followed) *)
let rec bytes_of ?(n = 0) url =
  match scheme_of url with
  | Some "file" ->
    let path = String.sub url 5 (String.length url - 5) in
    (try Ok (In_channel.with_open_bin path In_channel.input_all) with Sys_error m -> Error m)
  | Some ("http" | "https") ->
    (match Http.get ~timeout:20000 ~headers:(("User-Agent", user_agent) :: cookie_headers url) url with
     | r when (take_cookies url r; r.Http.status >= 300 && r.status < 400 && n < 5) ->
       (match Http.header "location" r with
        | Some l -> bytes_of ~n:(n + 1) (resolve url l)
        | None -> Error "a redirection without its place")
     | r when r.status = 200 -> Ok r.body
     | r -> Error (string_of_int r.status)
     | exception Http.Error m -> Error m
     | exception e -> Error (Printexc.to_string e))
  | _ -> Error "not fetched"

let decode_picture body =
  match (if Png.is_png body then Some (Png.read body)
         else if Jpeg.is_jpeg body then Some (Jpeg.read body) else None) with
  | Some img when img.Image.width <= 4096 && img.height <= 4096
                  && img.width * img.height <= 4_000_000 -> Ready img
  | _ | exception _ -> Failed

(* the pictures of a page, one after the other (40 at most) *)
let fetch_pictures urls =
  let todo = Mutex.protect lock (fun () ->
      List.filter (fun u ->
          if Hashtbl.mem pictures u then false
          else (Hashtbl.replace pictures u Loading; true)) urls) in
  if todo <> [] then
    ignore (Thread.create (fun () ->
        List.iteri (fun i u ->
            let p = if i >= 40 then Failed else
                match bytes_of u with
                | Ok body when String.length body <= 4_000_000 -> decode_picture body
                | _ -> Failed in
            Mutex.protect lock (fun () -> Hashtbl.replace pictures u p);
            Atomic.incr pictures_done) todo) ())

let picture_of url = Mutex.protect lock (fun () -> Hashtbl.find_opt pictures url)

(* a picture at its size on the page, made once (nearest pixel) *)
let picture_at url (img : Image.t) w h =
  match Hashtbl.find_opt scaled (url, w, h) with
  | Some g -> g
  | None ->
    let g = Gfx.create w h in
    for y = 0 to h - 1 do
      let sy = y * img.height / h in
      for x = 0 to w - 1 do
        let sx = x * img.width / w in
        Bigarray.Array1.unsafe_set g.Gfx.pixels (y * w + x)
          (Int32.of_int img.pixels.(sy * img.width + sx))
      done
    done;
    Hashtbl.replace scaled (url, w, h) g; g

let line_h = 18

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | args ->
    let first = match args with u :: _ -> of_typed u | [] -> "about:start" in
    let last_cols = ref 110 in             (* the page's width when last laid out *)
    let st = { doc = fetch "about:start"; laid = None; address = first; back = []; forward = [];
               loading = None; want_scroll = None; offset = 0; hover = None;
               values = Hashtbl.create 8; focus = None;
               cursor = 0; first = 0 } in
    let start_fetch ?body url =
      incr fetches;
      let n = !fetches in
      st.loading <- Some (url, n);
      st.address <- url;
      ignore (Thread.create (fun () ->
          let d = fetch ?body ~px:(!last_cols * 8) url in
          Mutex.protect lock (fun () -> fetched := Some (n, d));
          (* shown already; styled again when its sheets come *)
          if fetch_sheets d then begin d.styled <- None; Atomic.incr sheets_done end) ()) in
    let go ?body url =
      st.back <- (st.doc.url, st.offset) :: st.back;
      st.forward <- [];
      start_fetch ?body url in
    let submit (page : Layout.page) fi submitter =
      let f = page.forms.(fi) in
      let data = form_data st page fi submitter in
      let base = fst (strip_fragment st.doc.url) in
      let action = if f.action = "" then base else resolve base f.action in
      st.focus <- None;
      if f.meth = "post" then go ~body:data action
      else
        let no_query = match String.index_opt action '?' with
          | Some i -> String.sub action 0 i | None -> action in
        go (no_query ^ "?" ^ data) in
    if first <> "about:start" then go first;
    let pictures_seen = ref 0 and sheets_seen = ref 0 in
    Gui.run ~title:"Browser" ~tick:0.1 ~resizable:(480, 320) 900 640 st (fun ui st ->
        let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
        (* a page fetched: shown, at its fragment if it has one *)
        (match Mutex.protect lock (fun () -> let f = !fetched in fetched := None; f) with
         | Some (n, d) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
           let asked = match st.loading with Some (u, _) -> u | None -> d.url in
           st.doc <- d; st.laid <- None; st.loading <- None;
           Hashtbl.reset st.values; st.focus <- None;
           (* the address after redirections, with the fragment asked for *)
           st.address <- d.url ^ (match snd (strip_fragment asked) with
               | Some f -> "#" ^ f | None -> "");
           st.want_scroll <- Some (match st.want_scroll with Some s -> s | None -> 0)
         | _ -> ());
        (* the bar *)
        Gfx.fill g 0 0 width 40 0x1B3A57;
        let back = Gui.button ui 6 7 34 "<" and fwd = Gui.button ui 44 7 34 ">" in
        let reload = Gui.button ui 82 7 70 (if st.loading <> None then "Stop" else "Reload") in
        let field_w = width - 160 - 60 in
        let typed = Gui.text_field ui 1 158 9 field_w st.address in
        let enter = ui.Gui.field = 1 && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
        st.address <- typed;
        let gob = Gui.button ui (width - 56) 7 50 "Go" in
        if (enter || gob) && String.trim st.address <> "" then begin
          ui.Gui.field <- 0; go (of_typed st.address)
        end;
        if back then (match st.back with
            | (u, off) :: rest ->
              st.forward <- (st.doc.url, st.offset) :: st.forward; st.back <- rest;
              st.want_scroll <- Some off; start_fetch u
            | [] -> ());
        if fwd then (match st.forward with
            | (u, off) :: rest ->
              st.back <- (st.doc.url, st.offset) :: st.back; st.forward <- rest;
              st.want_scroll <- Some off; start_fetch u
            | [] -> ());
        if reload then begin
          if st.loading <> None then begin st.loading <- None; st.address <- st.doc.url end
          else begin st.want_scroll <- Some st.offset; start_fetch st.doc.url end
        end;
        (* the page, laid out for the width it has *)
        let box_y = 44 and box_h = height - 44 - 24 in
        let cols = (width - 40) / Gfx.char_w in
        (* a picture came: the page laid out again, with its size *)
        let done_now = Atomic.get pictures_done in
        if done_now <> !pictures_seen then begin pictures_seen := done_now; st.laid <- None end;
        let sheets_now = Atomic.get sheets_done in
        if sheets_now <> !sheets_seen then begin sheets_seen := sheets_now; st.laid <- None end;
        let size src attr =
          match picture_of (resolve st.doc.url src) with
          | Some (Ready img) -> Some (img.Image.width, img.height)
          | Some Failed -> (match attr with Some _ -> attr | None -> Some (0, 0))
          | _ -> attr in
        let page = match st.laid with
          | Some (w, p) when w = cols -> p
          | _ ->
            last_cols := cols;
            let p = Layout.layout ~size ~width:cols (styled st.doc (cols * 8)) in
            st.laid <- Some (cols, p);
            (* its pictures, to fetch *)
            fetch_pictures (Array.to_list p.lines |> List.filter_map (fun (l : Layout.line) ->
                Option.map (fun (pic : Layout.picture) -> resolve st.doc.url pic.src) l.picture));
            p in
        (match st.want_scroll with
         | Some s ->
           (* a fragment: its anchor's line *)
           let _, frag = strip_fragment st.address in
           let s = match frag with
             | Some f -> (match List.assoc_opt f page.anchors with Some l -> l * line_h | None -> s)
             | None -> s in
           Gui.scroll_to ui 2 s; st.want_scroll <- None
         | None -> ());
        (* a field of the page has the keys: they edit it *)
        if ui.Gui.field = 1 then st.focus <- None;
        (match st.focus with
         | Some ((fi, k) as w) when fi < Array.length page.forms && k < Array.length page.forms.(fi).fields ->
           let f = page.forms.(fi).fields.(k) in
           (* edited at the cursor (st.cursor characters before it) *)
           List.iter (fun key ->
               let v, c = value_of st f w in
               let n = Layout.cells v in
               st.cursor <- max 0 (min st.cursor n);
               let before, after = Layout.split_cells v st.cursor in
               let set s cur = Hashtbl.replace st.values w (s, c); st.cursor <- cur in
               match key with
               | "\r" | "\n" -> submit page fi None
               | "\027" -> st.focus <- None
               | "\127" | "\b" ->
                 if st.cursor > 0 then
                   set (fst (Layout.split_cells before (st.cursor - 1)) ^ after) (st.cursor - 1)
               | "\027[3~" ->
                 if st.cursor < n then set (before ^ snd (Layout.split_cells after 1)) st.cursor
               | "\027[D" -> st.cursor <- max 0 (st.cursor - 1)
               | "\027[C" -> st.cursor <- min n (st.cursor + 1)
               | "\027[H" | "\027[1~" | "\001" -> st.cursor <- 0
               | "\027[F" | "\027[4~" | "\005" -> st.cursor <- n
               | "\021" -> set "" 0
               | "\022" ->
                 let clip = match String.split_on_char '\n' (Clipboard.get ()) with l :: _ -> l | [] -> "" in
                 set (before ^ clip ^ after) (st.cursor + Layout.cells clip)
               | key when String.length key > 0 && key.[0] >= ' ' && key.[0] <> '\127' ->
                 set (before ^ key ^ after) (st.cursor + Layout.cells key)
               | _ -> ()) ui.Gui.keys;
           ui.Gui.keys <- []
         | _ -> st.focus <- None);
        (* keys: the page's, when the address does not have them *)
        if ui.Gui.field <> 1 then begin
          let page_step = box_h - 2 * line_h in
          List.iter (fun k ->
              let by d = Gui.scroll_to ui 2 (max 0 (st.offset + d)) in
              match k with
              | "\027[6~" | " " -> by page_step
              | "\027[5~" -> by (- page_step)
              | "\027[B" -> by (3 * line_h)
              | "\027[A" -> by (-3 * line_h)
              | "\027[H" | "\027[1~" -> Gui.scroll_to ui 2 0
              | "\027[F" | "\027[4~" -> Gui.scroll_to_end ui 2
              | "\b" | "\127" -> ()
              | _ -> ()) ui.Gui.keys
        end;
        let links = ref [] and widgets = ref [] in
        (* a form's field, drawn as what it is *)
        let draw_widget x y cells ((fi, k) as w) =
          let f = page.forms.(fi).fields.(k) in
          let v, c = value_of st f w in
          let pw = cells * Gfx.char_w in
          let focused = st.focus = Some w in
          (match f.kind with
           | Text | Password | Textarea ->
             Gfx.fill g x y (pw - 2) (line_h - 2) 0xFFFFFF;
             Gfx.rect g x y (pw - 2) (line_h - 2) (if focused then Gui.accent else 0x8A96A3);
             let shown = if f.kind = Password then String.make (Layout.cells v) '*' else v in
             let room = max 1 (cells - 2) and total = Layout.cells shown in
             (* the part in view: the cursor in it, when focused; else the end *)
             let first =
               if not focused then max 0 (total - room)
               else begin
                 let cur = min st.cursor total in
                 if cur < st.first then st.first <- cur;
                 if cur > st.first + room - 1 then st.first <- cur - room + 1;
                 if total - st.first < room - 1 then st.first <- max 0 (total - room + 1);
                 st.first <- max 0 st.first;
                 st.first
               end in
             let part = fst (Layout.split_cells (snd (Layout.split_cells shown first)) room) in
             ignore (Gfx.text g (x + 6) (y + 1) part Gui.foreground);
             if focused then
               Gfx.fill g (x + 6 + (min st.cursor total - first) * Gfx.char_w) (y + 2) 2 13 Gui.accent
           | Submit ->
             Gfx.fill g x y (pw - 4) (line_h - 2) Gui.accent;
             let lw = Layout.cells f.label * Gfx.char_w in
             ignore (Gfx.text ~bold:true g (x + (pw - 4 - lw) / 2) (y + 1) f.label 0xFFFFFF)
           | Checkbox | Radio ->
             Gfx.rect g (x + 4) (y + 2) 13 13 0x5F6B76;
             if c then Gfx.fill g (x + 7) (y + 5) 7 7 (if f.kind = Radio then Gui.accent else 0x1A2228)
           | Select ->
             Gfx.fill g x y (pw - 2) (line_h - 2) 0xF0F3F6;
             Gfx.rect g x y (pw - 2) (line_h - 2) 0x8A96A3;
             let words = match List.assoc_opt v f.options with Some w -> w | None -> v in
             ignore (Gfx.text ~max:(cells - 3) g (x + 6) (y + 1) words Gui.foreground);
             ignore (Gfx.text g (x + pw - 16) (y + 1) "v" Gui.muted)
           | Hidden -> ());
          widgets := (x, y, pw, line_h, w) :: !widgets in
        Gui.scroll ~colour:0xFFFFFF ui 2 4 box_y (width - 8) box_h (fun top ->
            st.offset <- box_y + 1 - top;
            Array.iteri (fun i (l : Layout.line) ->
                let y = top + 6 + i * line_h in
                if y > box_y - line_h && y < box_y + box_h then begin
                  for k = 0 to l.bar - 1 do
                    Gfx.fill g (12 + k * 16) y 2 line_h 0xC0C8D0
                  done;
                  if l.rule then Gfx.fill g 12 (y + 8) (width - 48) 1 0xC0C8D0;
                  (match l.picture with
                   | Some pic ->
                     let url = resolve st.doc.url pic.src in
                     let x = 16 + 8 * l.bar * 2 in
                     (match picture_of url with
                      | Some (Ready img) when pic.pw > 0 ->
                        Gfx.blit (picture_at url img pic.pw pic.ph) 0 0 g x y pic.pw pic.ph
                      | state ->
                        (* not here (yet): a frame and its words *)
                        let label = (if pic.alt <> "" then pic.alt else Filename.basename pic.src)
                                    ^ (match state with Some Loading | None -> " (loading)" | _ -> "") in
                        let w = max 60 (if pic.pw > 0 then pic.pw else 8 * Layout.cells label + 16) in
                        let h = max (line_h - 2) pic.ph in
                        Gfx.rect g x y (min w (width - 40)) h 0xC0C8D0;
                        ignore (Gui.text ~max:((min w (width - 40) - 8) / 8) ui (x + 4) (y + 1) label Gui.muted));
                     (match pic.plink with
                      | Some h -> links := (x, y, max pic.pw 60, max line_h pic.ph, h) :: !links
                      | None -> ())
                   | None -> ());
                  List.iter (fun (s : Layout.span) ->
                      let x = 16 + s.col * Gfx.char_w in
                      let n = Layout.cells s.text in
                      match s.widget with
                      | Some w -> draw_widget x y n w
                      | None ->
                      ignore (Gui.text ~bold:s.style.bold ui x y s.text s.style.colour);
                      if s.style.underline then Gfx.fill g x (y + 15) (n * Gfx.char_w) 1 s.style.colour;
                      if s.style.strike then Gfx.fill g x (y + 8) (n * Gfx.char_w) 1 s.style.colour;
                      match s.style.link with
                      | Some h -> links := (x, y, n * Gfx.char_w, line_h, h) :: !links
                      | None -> ()) l.spans
                end) page.lines;
            12 + Array.length page.lines * line_h);
        (* a link under the pointer: shown below; a click follows it *)
        let inside (x, y, w, lh, _) px py = px >= x && px < x + w && py >= y && py < y + lh
                                            && py >= box_y && py < box_y + box_h in
        st.hover <- None;
        List.iter (fun ((_, _, _, _, h) as l) ->
            if inside l ui.Gui.mx ui.Gui.my then st.hover <- Some (resolve st.doc.url h))
          !links;
        (* a click on a field: the keys to it, or its value changed, or the
           form sent *)
        let on_widget = ref false in
        (if ui.Gui.clicked then
           let px, py = ui.Gui.press in
           let hit (x, y, w, h, _) = px >= x && px < x + w && py >= y && py < y + h
                                     && py >= box_y && py < box_y + box_h in
           match List.find_opt hit !widgets with
           | Some (_, _, _, _, ((fi, k) as w)) ->
             on_widget := true;
             let form = page.forms.(fi) in
             let f = form.fields.(k) in
             let v, c = value_of st f w in
             (match f.kind with
              | Text | Password | Textarea ->
                (* the cursor where the click was, in the part shown (a
                   field without the keys shows its end) *)
                let wx, ww = match List.find_opt hit !widgets with
                  | Some (x, _, w, _, _) -> (x, w) | None -> (px, 0) in
                let n = Layout.cells v in
                let room = max 1 (ww / Gfx.char_w - 2) in
                let first = if st.focus = Some w then st.first else max 0 (n - room) in
                st.first <- first;
                st.focus <- Some w; ui.Gui.field <- 0;
                st.cursor <- min n (first + max 0 ((px - wx - 6 + Gfx.char_w / 2) / Gfx.char_w))
              | Checkbox -> Hashtbl.replace st.values w (v, not c)
              | Radio ->
                Array.iteri (fun j (o : Layout.field) ->
                    if o.kind = Radio && o.fname = f.fname then
                      Hashtbl.replace st.values (fi, j) (fst (value_of st o (fi, j)), j = k)) form.fields
              | Select ->
                let rec next = function
                  | (a, _) :: (b, _) :: _ when a = v -> b
                  | _ :: rest -> next rest
                  | [] -> (match f.options with (a, _) :: _ -> a | [] -> v) in
                Hashtbl.replace st.values w (next f.options, c)
              | Submit -> submit page fi (Some k)
              | Hidden -> ())
           | None -> if py >= box_y then st.focus <- None);
        (if ui.Gui.clicked && not !on_widget then
           let px, py = ui.Gui.press in
           match List.find_opt (fun l -> inside l px py && inside l ui.Gui.mx ui.Gui.my) !links with
           | Some (_, _, _, _, h) ->
             let target = resolve st.doc.url h in
             if String.length h > 0 && h.[0] = '#' then begin
               st.address <- target; st.want_scroll <- Some st.offset
             end else (match scheme_of target with
                 | Some ("mailto" | "javascript" | "tel") -> ()
                 | _ -> go target)
           | None -> ());
        (* the status line *)
        Gfx.fill g 0 (height - 22) width 22 0xE8EDF2;
        let status = match st.loading, st.hover with
          | Some (u, _), _ -> "loading " ^ u ^ "..."
          | None, Some h -> h
          | None, None ->
            (if page.title <> "" then page.title ^ "  \xc2\xb7  " else "") ^ st.doc.status in
        ignore (Gfx.text ~max:((width - 16) / Gfx.char_w) g 8 (height - 19) status Gui.muted);
        st)
