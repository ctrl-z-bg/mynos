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
<p>MyNOS's new browser, in OCaml (doc/decisions/browser.md). This is
milestone M0, the skeleton: it shows a page's text. Type an address above
and press Enter.</p>
<h2>Try</h2>
<ul>
<li><a href="about:tests">about:tests</a>: the test pages, built into Ariadne</li>
<li><a href="file:/disk/">file:/disk/</a>: the disk</li>
<li><a href="https://en.m.wikipedia.org/wiki/Ariadne">https://en.m.wikipedia.org/wiki/Ariadne</a></li>
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

let load url =
  let rec go url redirects =
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
      (match Http.get ~timeout:20000 ~headers:[ "User-Agent", user_agent;
                                                "Accept", "text/html,text/plain;q=0.9,*/*;q=0.5" ] url with
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
    | None -> go (Url.of_typed url) redirects in
  go url 0

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
