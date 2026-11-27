(* Loading a page: about:, file:, http: and https: (through Http, TLS in
   netd). The one module of the engine that does input and output, with
   the window (doc/decisions/browser.md, rule 5). *)

type response = {
  url : string;            (* after redirections, without the fragment *)
  status : string;         (* "200 OK", "a file", or what went wrong *)
  content_type : string;
  body : string;
}

let user_agent = "Ariadne/0.1 (MyNOS)"

let escape s =
  let b = Buffer.create (String.length s) in
  String.iter (function
      | '<' -> Buffer.add_string b "&lt;" | '>' -> Buffer.add_string b "&gt;"
      | '&' -> Buffer.add_string b "&amp;" | '"' -> Buffer.add_string b "&quot;"
      | c -> Buffer.add_char b c) s;
  Buffer.contents b

let message title text =
  Printf.sprintf "<title>%s</title><h1>%s</h1><p>%s</p>" (escape title) (escape title) (escape text)

let start_page = {|<title>Ariadne</title>
<h1>Ariadne</h1>
<p>MyNOS's new browser, in OCaml (doc/decisions/browser.md,
BROWSER-TODO.md). It parses pages with the HTML Standard's parser, applies
their CSS and lays them out: blocks and lines, floats, positioning,
flexbox, grid and tables. Pictures, real fonts and JavaScript are still to
come. Type an address above and press Enter.</p>
<h2>Try</h2>
<ul>
<li><a href="about:tests">about:tests</a>: the test pages, built into Ariadne</li>
<li><a href="file:/disk/">file:/disk/</a>: the disk</li>
<li><a href="https://en.wikipedia.org/wiki/Ariadne">https://en.wikipedia.org/wiki/Ariadne</a></li>
<li><a href="https://news.ycombinator.com/">https://news.ycombinator.com/</a></li>
</ul>|}

let tests_page () =
  "<title>Test pages</title><h1>Test pages</h1><ul>"
  ^ String.concat "" (List.map (fun (name, _) ->
      Printf.sprintf "<li><a href=\"about:test/%s\">about:test/%s</a></li>" name name) Pages.pages)
  ^ "</ul>"

let listing dir =
  let names = try Array.to_list (Sys.readdir dir) with Sys_error _ -> [] in
  let names = List.sort compare names in
  let slash = if String.ends_with ~suffix:"/" dir then "" else "/" in
  "<title>" ^ escape dir ^ "</title><h1>" ^ escape dir ^ "</h1><ul>"
  ^ String.concat "" (List.map (fun n ->
      let d = try Sys.is_directory (dir ^ slash ^ n) with Sys_error _ -> false in
      let n = escape n ^ if d then "/" else "" in
      Printf.sprintf "<li><a href=\"%s\">%s</a></li>" n n) names)
  ^ "</ul>"

let html ?(status = "") url body = { url; status; content_type = "text/html"; body }

(* an answer with content: HTTP's 2xx, a file, a data: URL *)
let ok r = String.length r.status > 0 && (r.status.[0] = '2' || r.status = "a file" || r.status = "a data URL")

(* data:[type][;base64],data (RFC 2397) *)
let base64 s =
  let v c = match c with
    | 'A' .. 'Z' -> Char.code c - 65 | 'a' .. 'z' -> Char.code c - 71 | '0' .. '9' -> Char.code c + 4
    | '+' | '-' -> 62 | '/' | '_' -> 63 | _ -> -1 in
  let b = Buffer.create (String.length s * 3 / 4) in
  let acc = ref 0 and bits = ref 0 in
  String.iter (fun c ->
      let d = v c in
      if d >= 0 then begin
        acc := (!acc lsl 6) lor d; bits := !bits + 6;
        if !bits >= 8 then begin
          bits := !bits - 8;
          Buffer.add_char b (Char.chr ((!acc lsr !bits) land 255))
        end
      end) s;
  Buffer.contents b

let percent_decode s =
  let b = Buffer.create (String.length s) and n = String.length s in
  let hex c = match c with
    | '0' .. '9' -> Char.code c - 48 | 'a' .. 'f' -> Char.code c - 87 | 'A' .. 'F' -> Char.code c - 55 | _ -> -1 in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '%' && !i + 2 < n && hex s.[!i + 1] >= 0 && hex s.[!i + 2] >= 0 then begin
      Buffer.add_char b (Char.chr (hex s.[!i + 1] * 16 + hex s.[!i + 2])); i := !i + 3
    end else (Buffer.add_char b s.[!i]; incr i)
  done;
  Buffer.contents b

let data_url url =
  let rest = String.sub url 5 (String.length url - 5) in
  match String.index_opt rest ',' with
  | None -> html ~status:"a bad data URL" url (message "Not shown" "A data: URL without a comma.")
  | Some i ->
    let meta = String.lowercase_ascii (String.sub rest 0 i) and data = String.sub rest (i + 1) (String.length rest - i - 1) in
    let is_b64 = String.ends_with ~suffix:";base64" meta in
    let ct = match String.index_opt meta ';' with Some j -> String.sub meta 0 j | None -> meta in
    let body = if is_b64 then base64 (percent_decode data) else percent_decode data in
    { url; status = "a data URL"; content_type = (if ct = "" then "text/plain" else ct); body }

(* [post]: a form's body (application/x-www-form-urlencoded), sent with
   POST; a redirect after it is followed with GET *)
let load ?post url =
  let rec go ?post url redirects =
    if Url.scheme_of url = Some "data" then data_url url else
    let url, _ = Url.strip_fragment url in
    match Url.scheme_of url with
    | Some "about" ->
      let what = String.sub url 6 (String.length url - 6) in
      (match what with
       | "start" -> html url start_page
       | "blank" -> html url ""
       | "tests" -> html url (tests_page ())
       | w when String.starts_with ~prefix:"test/" w ->
         let name = String.sub w 5 (String.length w - 5) in
         (* a query (a form sent to a test page) does not name another page *)
         let name = match String.index_opt name '?' with Some i -> String.sub name 0 i | None -> name in
         (match List.assoc_opt name Pages.pages with
          | Some p -> html ~status:"a test page" url p
          | None -> html ~status:"not found" url (message "Not found" ("There is no test page " ^ name ^ ".")))
       | _ -> html ~status:"not found" url (message "Not found" ("Ariadne has no page " ^ url ^ ".")))
    | Some "file" ->
      let path = String.sub url 5 (String.length url - 5) in
      let path = if String.starts_with ~prefix:"//" path then String.sub path 2 (String.length path - 2) else path in
      let path = if path = "" then "/" else path in
      if (try Sys.is_directory path with Sys_error _ -> false) then html ~status:"a folder" url (listing path)
      else (match In_channel.with_open_bin path In_channel.input_all with
          | body ->
            let ct = if Filename.check_suffix path ".html" || Filename.check_suffix path ".htm"
              then "text/html" else "text/plain" in
            { url; status = "a file"; content_type = ct; body }
          | exception Sys_error m -> html ~status:m url (message "Cannot open" m))
    | Some ("http" | "https") ->
      let headers = [ "User-Agent", user_agent; "Accept", "text/html,text/plain;q=0.9,*/*;q=0.5" ] in
      (match (match post with
           | Some body ->
             Http.post ~timeout:20000 ~headers:(("Content-Type", "application/x-www-form-urlencoded") :: headers)
               ~body url
           | None -> Http.get ~timeout:20000 ~headers url) with
       | r when r.Http.status >= 300 && r.status < 400 && redirects < 8
                && Http.header "location" r <> None ->
         go (Url.resolve url (Option.get (Http.header "location" r))) (redirects + 1)
       | r ->
         { url; status = Printf.sprintf "%d %s" r.status r.reason;
           content_type = Option.value (Http.header "content-type" r) ~default:"";
           body = r.body }
       | exception Http.Error m -> html ~status:m url (message "Not reached" (url ^ ": " ^ m))
       | exception e -> html ~status:"error" url (message "Not reached" (Printexc.to_string e)))
    | Some s -> html ~status:"not shown" url (message "Not shown" ("Ariadne does not open " ^ s ^ ": addresses."))
    | None -> go ?post (Url.of_typed url) redirects in
  go ?post url 0

(* the response as HTML in UTF-8, and the encoding its bytes were in:
   HTML decoded by its byte order mark, the HTTP header's charset, a <meta>
   or a guess (Encoding); text the same way, as preformatted text; anything
   else said in words *)
let document r =
  let ct = String.lowercase_ascii r.content_type in
  let charset = Encoding.charset_of_content_type r.content_type in
  if ct = "" || String.starts_with ~prefix:"text/html" ct || String.starts_with ~prefix:"application/xhtml" ct
  then let e, text = Encoding.to_utf8 ?transport:charset r.body in (text, Encoding.name e)
  else if String.starts_with ~prefix:"text/" ct then
    let e, text = Encoding.to_utf8 ?transport:charset r.body in
    ("<pre>" ^ escape text ^ "</pre>", Encoding.name e)
  else (message "Not a page"
          (Printf.sprintf "This is %s, %d bytes: Ariadne shows only pages for now." r.content_type
             (String.length r.body)), "UTF-8")
