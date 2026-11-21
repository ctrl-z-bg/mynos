(* wiki: Wikipedia, read in a window (or in the terminal), through its
   API: JSON over HTTPS.

     wiki                  a window: search, read, follow the links
     wiki [-l LANG] TERM   the article's first paragraphs, in the terminal
     wiki -f [-l LANG] TERM   the whole article

   The language is English unless -l names another (it, de, fr...); the
   window has a field for it. *)

let agent = "MyNOS-wiki/1.0 (https://github.com/ctrl-z-bg/mynos)"

let encode s =
  let b = Buffer.create (String.length s * 3) in
  String.iter (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' -> Buffer.add_char b c
      | ' ' -> Buffer.add_string b "%20"
      | c -> Printf.bprintf b "%%%02X" (Char.code c)) s;
  Buffer.contents b

let api lang params =
  let url = Printf.sprintf "https://%s.wikipedia.org/w/api.php?format=json&formatversion=2&%s"
      lang (String.concat "&" (List.map (fun (k, v) -> k ^ "=" ^ encode v) params)) in
  match Http.get ~headers:[ "user-agent", agent ] ~timeout:30000 url with
  | { Http.status = 200; body; _ } -> Json.of_string body
  | r -> failwith (Printf.sprintf "Wikipedia answered %d %s" r.Http.status r.Http.reason)
  | exception Http.Error m -> failwith m
  | exception Json.Error m -> failwith ("not JSON: " ^ m)

(* the search's snippets have HTML: its tags out, its entities in *)
let strip_html s =
  let b = Buffer.create (String.length s) in
  let inside = ref false in
  String.iter (fun c ->
      if c = '<' then inside := true
      else if c = '>' then inside := false
      else if not !inside then Buffer.add_char b c) s;
  List.fold_left (fun s (e, r) -> Str.global_replace (Str.regexp_string e) r s)
    (Buffer.contents b) [ "&quot;", "\""; "&#039;", "'"; "&amp;", "&"; "&lt;", "<"; "&gt;", ">" ]

let search lang q =
  let j = api lang [ "action", "query"; "list", "search"; "srsearch", q; "srlimit", "30" ] in
  Json.(member "query" j |> member "search" |> to_list)
  |> List.map (fun r -> Json.(member "title" r |> to_string_value,
                              strip_html (member "snippet" r |> to_string_value)))

type article = { title : string; text : string; links : string list }

let article lang title =
  let j = api lang [ "action", "query"; "prop", "extracts|links"; "explaintext", "1";
                     "titles", title; "redirects", "1"; "pllimit", "max"; "plnamespace", "0" ] in
  match Json.(member "query" j |> member "pages" |> to_list) with
  | p :: _ when Json.member "missing" p = Json.Null ->
    { title = Json.(member "title" p |> to_string_value);
      text = (match Json.member "extract" p with Json.Null -> "" | e -> Json.to_string_value e);
      links = (match Json.member "links" p with
          | Json.Null -> []
          | l -> List.map (fun x -> Json.(member "title" x |> to_string_value)) (Json.to_list l)) }
  | _ -> failwith (title ^ ": no such article")

let random_title lang =
  let j = api lang [ "action", "query"; "list", "random"; "rnnamespace", "0"; "rnlimit", "1" ] in
  match Json.(member "query" j |> member "random" |> to_list) with
  | r :: _ -> Json.(member "title" r |> to_string_value)
  | [] -> failwith "no random article"

(* {1 In the terminal} *)

let terminal lang full term =
  match article lang term with
  | a ->
    print_endline a.title;
    print_endline (String.make (String.length a.title) '=');
    let paras = String.split_on_char '\n' a.text |> List.filter (( <> ) "") in
    let paras = if full then paras else
        (* up to the first section *)
        let rec upto = function
          | p :: _ when String.starts_with ~prefix:"==" p -> []
          | p :: rest -> p :: upto rest
          | [] -> [] in
        upto paras in
    List.iter (fun p -> print_endline p; print_newline ()) paras;
    Printf.printf "https://%s.wikipedia.org/wiki/%s\n" lang
      (encode (String.map (fun c -> if c = ' ' then '_' else c) a.title))
  | exception Failure m ->
    (* not an article's title: what a search finds *)
    match search lang term with
    | [] -> prerr_endline ("wiki: " ^ m); exit 1
    | rs ->
      Printf.printf "No article %s. Articles about it:\n" term;
      List.iter (fun (t, _) -> print_endline ("  " ^ t)) (List.filteri (fun i _ -> i < 10) rs)
    | exception Failure m -> prerr_endline ("wiki: " ^ m); exit 1

(* {1 In a window} *)

let width = 860 and height = 600

type view = Results of (string * string) list | Article of article | Nothing

type state = {
  mutable lang : string;
  mutable query : string;
  mutable view : view;
  mutable back : view list;
  mutable busy : string;                       (* what is being fetched *)
  mutable error : string;
  mutable show_links : bool;
  result : (unit -> view) option Atomic.t;     (* a fetch's answer, from its thread *)
  mutable lines : (string * bool) list;        (* the article, wrapped: text, a heading *)
  mutable wrapped_for : string;
  mutable page : int;                          (* each page its own scroll box *)
}

(* a fetch, in a thread: the window keeps drawing *)
let fetch st what f =
  if st.busy = "" then begin
    st.busy <- what; st.error <- "";
    ignore (Thread.create (fun () ->
        let r = match f () with
          | v -> (fun () -> v)
          | exception Failure m -> (fun () -> failwith m)
          | exception e -> let m = Printexc.to_string e in (fun () -> failwith m) in
        Atomic.set st.result (Some r)) ())
  end

let wrap width text =
  let per = max 10 (width / Gfx.char_w) in
  List.concat_map (fun para ->
      if String.starts_with ~prefix:"==" para then
        [ "", false; String.trim (String.map (fun c -> if c = '=' then ' ' else c) para), true ]
      else
        let words = String.split_on_char ' ' para in
        let lines = List.fold_left (fun acc w ->
            match acc with
            | l :: rest when Gfx.cells l + 1 + Gfx.cells w <= per -> (l ^ " " ^ w) :: rest
            | acc -> w :: acc) [] words in
        List.rev_map (fun l -> (l, false)) lines @ [ "", false ])
    (String.split_on_char '\n' text |> List.filter (( <> ) ""))

let window () =
  let st = { lang = "en"; query = ""; view = Nothing; back = []; busy = ""; error = "";
             show_links = false; result = Atomic.make None; lines = []; wrapped_for = ""; page = 0 } in
  let goto st v =
    (match st.view with Nothing -> () | old -> st.back <- old :: st.back);
    st.view <- v; st.page <- st.page + 1 in
  let open_article st title =
    fetch st ("Reading " ^ title) (fun () -> Article (article st.lang title)) in
  Gui.run ~title:"Wikipedia" ~tick:0.2 width height st (fun ui st ->
      let g = ui.Gui.g in
      (match Atomic.exchange st.result None with
       | Some r ->
         st.busy <- "";
         (match r () with
          | v -> goto st v; st.show_links <- false
          | exception Failure m -> st.error <- m)
       | None -> ());
      (* the bar *)
      Gfx.fill g 0 0 width 40 Gui.panel_colour;
      if Gui.button ui 8 8 40 "<" then
        (match st.back with
         | v :: rest -> st.view <- v; st.back <- rest; st.page <- st.page + 1
         | [] -> ());
      st.lang <- Gui.text_field ui 1 56 10 36 st.lang;
      st.query <- Gui.text_field ui 2 100 10 380 st.query;
      let enter = ui.Gui.field = 2 && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      if (Gui.button ui 488 8 80 "Search" || enter) && String.trim st.query <> "" then begin
        let q = String.trim st.query and lang = String.trim st.lang in
        fetch st ("Searching " ^ q) (fun () -> Results (search lang q))
      end;
      if Gui.button ui 576 8 80 "Random" then begin
        let lang = String.trim st.lang in
        fetch st "A random article" (fun () -> Article (article lang (random_title lang)))
      end;
      (match st.view with
       | Article _ ->
         if Gui.button ui 664 8 80 (if st.show_links then "Text" else "Links") then
           st.show_links <- not st.show_links
       | _ -> ());
      let status = if st.busy <> "" then st.busy ^ "..." else st.error in
      ignore (Gfx.text ~max:((width - 760) / Gfx.char_w) g 756 12 status
                (if st.error <> "" && st.busy = "" then 0xC62828 else Gui.muted));
      (* the page *)
      let top = 48 in
      (match st.view with
       | Nothing ->
         ignore (Gui.paragraph ~colour:Gui.muted ui 16 (top + 8) (width - 32)
                   "Type a subject and press Enter. The field on the left is the \
                    language of Wikipedia: en, it, de, fr... Random opens any article.")
       | Results rs ->
         Gui.scroll ui (10 + 3 * st.page) 8 top (width - 16) (height - top - 8) (fun y0 ->
             let y = ref y0 in
             List.iter (fun (t, snippet) ->
                 if Gui.list_item ui 4 !y (width - 40) ~selected:false t then open_article st t;
                 let lines = wrap (width - 60) snippet in
                 List.iteri (fun i (l, _) ->
                     if i < 2 then ignore (Gfx.text g 24 (!y + 24 + i * 18) l Gui.muted))
                   (List.filter (fun (l, _) -> l <> "") lines);
                 y := !y + 66) rs;
             !y - y0)
       | Article a when st.show_links ->
         Gui.label ~bold:true ui 16 top (a.title ^ ": its links");
         Gui.scroll ui (11 + 3 * st.page) 8 (top + 24) (width - 16) (height - top - 32) (fun y0 ->
             List.iteri (fun i t ->
                 let col = i mod 3 and row = i / 3 in
                 if Gui.list_item ui (4 + col * ((width - 40) / 3)) (y0 + row * 24)
                     ((width - 40) / 3 - 6) ~selected:false t then open_article st t) a.links;
             24 * ((List.length a.links + 2) / 3))
       | Article a ->
         if st.wrapped_for != a.text then begin
           st.lines <- wrap (width - 56) a.text; st.wrapped_for <- a.text
         end;
         Gui.label ~bold:true ui 16 top a.title;
         Gui.scroll ~colour:0xFFFFFF ui (12 + 3 * st.page) 8 (top + 24) (width - 16) (height - top - 32) (fun y0 ->
             List.iteri (fun i (l, heading) ->
                 let y = y0 + 6 + i * 18 in
                 if y > -20 && y < height then
                   ignore (Gfx.text ~bold:heading g 16 y l (if heading then 0x1F4F7A else Gui.foreground)))
               st.lines;
             12 + 18 * List.length st.lines));
      st)

let () =
  let rec opts lang full = function
    | "-l" :: l :: rest -> opts l full rest
    | "-f" :: rest -> opts lang true rest
    | rest -> lang, full, rest in
  match opts "en" false (List.tl (Array.to_list Sys.argv)) with
  | _, _, [] -> window ()
  | lang, full, words -> terminal lang full (String.concat " " words)
