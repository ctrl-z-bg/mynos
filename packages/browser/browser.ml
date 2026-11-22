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
its text and links. No JavaScript, no style sheets, no pictures yet: the
pages that do not need them read well. Type an address above (Enter
goes), or follow a link.</p>
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

let fetch url : doc =
  let page u tokens status = { url = u; tokens; status } in
  let of_body u ct body status =
    let body = if Html.charset ~content_type:ct body = `Latin1 then Html.latin1_to_utf8 body else body in
    if is_html u ct then page u (Html.tokens body) status
    else if Html.contains (String.lowercase_ascii ct) "text" || ct = "" then
      page u (Html.tokens (html_of_text body)) status
    else page u (Html.tokens (message_page "Not a page"
                                (Printf.sprintf "This is %s, %d bytes: the browser shows only text for now."
                                   ct (String.length body)))) status in
  let rec go u n =
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
      (match Http.get ~timeout:20000 ~headers:[ ("User-Agent", user_agent);
                                                ("Accept", "text/html,text/plain;q=0.9,*/*;q=0.5") ] u with
       | r when r.Http.status >= 300 && r.status < 400 && n < 8 ->
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
    | None -> go (of_typed u) n in
  go url 0

(* ---- --dump: the page as text ---- *)

let dump url =
  let d = fetch (of_typed url) in
  let p = Layout.layout ~width:78 d.tokens in
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
}

let lock = Mutex.create ()
let fetched : (int * doc) option ref = ref None
let fetches = ref 0

let line_h = 18

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | args ->
    let first = match args with u :: _ -> of_typed u | [] -> "about:start" in
    let st = { doc = fetch "about:start"; laid = None; address = first; back = []; forward = [];
               loading = None; want_scroll = None; offset = 0; hover = None } in
    let start_fetch url =
      incr fetches;
      let n = !fetches in
      st.loading <- Some (url, n);
      st.address <- url;
      ignore (Thread.create (fun () ->
          let d = fetch url in
          Mutex.protect lock (fun () -> fetched := Some (n, d))) ()) in
    let go url =
      st.back <- (st.doc.url, st.offset) :: st.back;
      st.forward <- [];
      start_fetch url in
    if first <> "about:start" then go first;
    Gui.run ~title:"Browser" ~tick:0.1 ~resizable:(480, 320) 900 640 st (fun ui st ->
        let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
        (* a page fetched: shown, at its fragment if it has one *)
        (match Mutex.protect lock (fun () -> let f = !fetched in fetched := None; f) with
         | Some (n, d) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
           let asked = match st.loading with Some (u, _) -> u | None -> d.url in
           st.doc <- d; st.laid <- None; st.loading <- None;
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
        let page = match st.laid with
          | Some (w, p) when w = cols -> p
          | _ -> let p = Layout.layout ~width:cols st.doc.tokens in st.laid <- Some (cols, p); p in
        (match st.want_scroll with
         | Some s ->
           (* a fragment: its anchor's line *)
           let _, frag = strip_fragment st.address in
           let s = match frag with
             | Some f -> (match List.assoc_opt f page.anchors with Some l -> l * line_h | None -> s)
             | None -> s in
           Gui.scroll_to ui 2 s; st.want_scroll <- None
         | None -> ());
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
        let links = ref [] in
        Gui.scroll ~colour:0xFFFFFF ui 2 4 box_y (width - 8) box_h (fun top ->
            st.offset <- box_y + 1 - top;
            Array.iteri (fun i (l : Layout.line) ->
                let y = top + 6 + i * line_h in
                if y > box_y - line_h && y < box_y + box_h then begin
                  for k = 0 to l.bar - 1 do
                    Gfx.fill g (12 + k * 16) y 2 line_h 0xC0C8D0
                  done;
                  if l.rule then Gfx.fill g 12 (y + 8) (width - 48) 1 0xC0C8D0;
                  List.iter (fun (s : Layout.span) ->
                      let x = 16 + s.col * Gfx.char_w in
                      let n = Layout.cells s.text in
                      ignore (Gui.text ~bold:s.style.bold ui x y s.text s.style.colour);
                      if s.style.underline then Gfx.fill g x (y + 15) (n * Gfx.char_w) 1 s.style.colour;
                      if s.style.strike then Gfx.fill g x (y + 8) (n * Gfx.char_w) 1 s.style.colour;
                      match s.style.link with
                      | Some h -> links := (x, y, n * Gfx.char_w, h) :: !links
                      | None -> ()) l.spans
                end) page.lines;
            12 + Array.length page.lines * line_h);
        (* a link under the pointer: shown below; a click follows it *)
        let inside (x, y, w, _) px py = px >= x && px < x + w && py >= y && py < y + line_h
                                        && py >= box_y && py < box_y + box_h in
        st.hover <- None;
        List.iter (fun (x, y, w, h) ->
            if inside (x, y, w, h) ui.Gui.mx ui.Gui.my then st.hover <- Some (resolve st.doc.url h))
          !links;
        (if ui.Gui.clicked then
           let px, py = ui.Gui.press in
           match List.find_opt (fun (x, y, w, h) ->
               inside (x, y, w, h) px py && inside (x, y, w, h) ui.Gui.mx ui.Gui.my) !links with
           | Some (_, _, _, h) ->
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
