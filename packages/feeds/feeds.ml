(* feeds: a reader of news feeds, RSS and Atom, in a window (or in the
   terminal).

     feeds              a window: the feeds of /disk/feeds.txt, their items
     feeds URL          a feed's items, in the terminal

   /disk/feeds.txt has a feed's address a line (# starts a comment); the
   window adds and removes them. *)

let file = "/disk/feeds.txt"
let defaults = [
  "https://github.com/ctrl-z-bg/mynos/commits/main.atom";
  "https://discuss.ocaml.org/latest.rss";
  "https://news.ycombinator.com/rss";
]

type item = { title : string; link : string; date : string; summary : string }
type feed = { name : string; items : item list }

(* HTML (a feed's descriptions) to text: tags out, paragraphs kept *)
let text_of_html s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if s.[!i] = '<' then begin
      let j = match String.index_from_opt s !i '>' with Some j -> j | None -> n - 1 in
      let t = String.lowercase_ascii (String.sub s (!i + 1) (max 0 (j - !i - 1))) in
      if List.exists (fun p -> String.starts_with ~prefix:p t) [ "p"; "/p"; "br"; "li"; "div"; "/div"; "h" ]
      then Buffer.add_char b '\n';
      i := j + 1
    end else (Buffer.add_char b s.[!i]; incr i)
  done;
  let t = Xml.decode (Buffer.contents b) in
  (* blank lines, one at most *)
  String.split_on_char '\n' t |> List.map String.trim
  |> List.fold_left (fun acc l -> match acc with "" :: _ when l = "" -> acc | _ -> l :: acc) []
  |> List.rev |> String.concat "\n" |> String.trim

let rec download ?(redirects = 5) url =
  match Http.get ~headers:[ "user-agent", "MyNOS-feeds/1.0" ] ~timeout:30000 url with
  | { Http.status = 200; body; _ } -> body
  | { Http.status = (301 | 302 | 303 | 307 | 308); _ } as r when redirects > 0 ->
    (match Http.header "location" r with
     | Some l ->
       let l = if String.starts_with ~prefix:"/" l then
           (let (tls, host, port, _) = Http.parse_url url in
            Printf.sprintf "%s://%s%s%s" (if tls then "https" else "http") host
              (if (tls && port = 443) || (not tls && port = 80) then "" else ":" ^ string_of_int port) l)
         else l in
       download ~redirects:(redirects - 1) l
     | None -> failwith "a redirect without a place")
  | r -> failwith (Printf.sprintf "%d %s" r.Http.status r.Http.reason)
  | exception Http.Error m -> failwith m

let parse url body =
  let x = try Xml.parse body with Failure m -> failwith ("not XML: " ^ m) in
  let t e name = match Xml.child name e with Some c -> String.trim (Xml.text c) | None -> "" in
  match Xml.tag x with
  | "rss" | "RDF" ->
    let channel = match Xml.child "channel" x with Some c -> c | None -> x in
    let items = Xml.children "item" channel @ Xml.children "item" x in
    { name = (let n = t channel "title" in if n = "" then url else n);
      items = List.map (fun i ->
          { title = text_of_html (t i "title"); link = t i "link";
            date = (let d = t i "pubDate" in if d = "" then t i "date" else d);
            summary = text_of_html (let d = t i "description" in if d = "" then t i "encoded" else d) })
          items }
  | "feed" ->
    { name = (let n = text_of_html (t x "title") in if n = "" then url else n);
      items = List.map (fun e ->
          let link = match List.find_opt (fun l ->
              Xml.attr "rel" l = None || Xml.attr "rel" l = Some "alternate") (Xml.children "link" e) with
            | Some l -> Option.value (Xml.attr "href" l) ~default:""
            | None -> "" in
          { title = text_of_html (t e "title"); link;
            date = (let d = t e "updated" in if d = "" then t e "published" else d);
            summary = text_of_html (let c = t e "content" in if c = "" then t e "summary" else c) })
          (Xml.children "entry" x) }
  | other -> failwith ("not a feed: <" ^ other ^ ">")

let fetch url = parse url (download url)

let read_list () =
  match In_channel.with_open_bin file In_channel.input_all with
  | s -> String.split_on_char '\n' s |> List.map String.trim
         |> List.filter (fun l -> l <> "" && l.[0] <> '#')
  | exception Sys_error _ -> defaults

let write_list l =
  try Out_channel.with_open_bin file (fun oc ->
      output_string oc "# feeds: an address a line\n";
      List.iter (fun u -> output_string oc (u ^ "\n")) l)
  with Sys_error _ -> ()

(* {1 In the terminal} *)

let terminal url =
  match fetch url with
  | f ->
    print_endline f.name;
    List.iter (fun i ->
        Printf.printf "\n%s\n" i.title;
        if i.date <> "" then Printf.printf "  %s\n" i.date;
        if i.link <> "" then Printf.printf "  %s\n" i.link) f.items
  | exception Failure m -> prerr_endline ("feeds: " ^ url ^ ": " ^ m); exit 1

(* {1 In a window} *)

let width = 900 and height = 600
let left = 260

type state = {
  mutable urls : string list;
  mutable sel_feed : int;
  mutable feeds : (string * (feed, string) result) list;   (* fetched, by address *)
  mutable sel_item : int;
  mutable adding : string;
  mutable busy : string list;
  result : (string * (feed, string) result) list Atomic.t;
  mutable item_page : int;
}

let start_fetch st url =
  if not (List.mem url st.busy) then begin
    st.busy <- url :: st.busy;
    ignore (Thread.create (fun () ->
        let r = match fetch url with f -> Ok f | exception Failure m -> Error m
                                     | exception e -> Error (Printexc.to_string e) in
        let rec put () =
          let old = Atomic.get st.result in
          if not (Atomic.compare_and_set st.result old ((url, r) :: old)) then put () in
        put ()) ())
  end

let wrap width text =
  let per = max 10 (width / Gfx.char_w) in
  List.concat_map (fun para ->
      if para = "" then [ "" ]
      else
        let words = String.split_on_char ' ' para in
        List.rev (List.fold_left (fun acc w ->
            match acc with
            | l :: rest when Gfx.cells l + 1 + Gfx.cells w <= per -> (l ^ " " ^ w) :: rest
            | acc -> w :: acc) [] words)) (String.split_on_char '\n' text)

let window () =
  let st = { urls = read_list (); sel_feed = 0; feeds = []; sel_item = -1; adding = "";
             busy = []; result = Atomic.make []; item_page = 0 } in
  if not (Sys.file_exists file) then write_list st.urls;
  List.iter (start_fetch st) st.urls;
  Gui.run ~title:"Feeds" ~tick:0.3 ~resizable:(600, 360) width height st (fun ui st ->
      (* resizable: the size as it is now *)
      let width = Gui.width ui and height = Gui.height ui in
      let g = ui.Gui.g in
      List.iter (fun (url, r) ->
          st.busy <- List.filter (( <> ) url) st.busy;
          st.feeds <- (url, r) :: List.remove_assoc url st.feeds)
        (Atomic.exchange st.result []);
      (* the feeds, on the left *)
      Gfx.fill g 0 0 left height 0xE6EBF0;
      Gui.label ~bold:true ui 12 10 "Feeds";
      List.iteri (fun i url ->
          let name = match List.assoc_opt url st.feeds with
            | Some (Ok f) -> f.name
            | Some (Error _) -> "(!) " ^ url
            | None -> url in
          if Gui.list_item ui 6 (34 + i * 24) (left - 12) ~selected:(i = st.sel_feed) name then begin
            st.sel_feed <- i; st.sel_item <- -1; st.item_page <- st.item_page + 1 end)
        st.urls;
      let y = height - 98 in
      st.adding <- Gui.text_field ui 1 8 y (left - 16) st.adding;
      if Gui.button ui 8 (y + 28) 78 "Add" && String.trim st.adding <> "" then begin
        let u = String.trim st.adding in
        st.urls <- st.urls @ [ u ]; st.adding <- ""; write_list st.urls; start_fetch st u;
        st.sel_feed <- List.length st.urls - 1
      end;
      if Gui.button ui 92 (y + 28) 78 "Remove" && st.urls <> [] then begin
        st.urls <- List.filteri (fun i _ -> i <> st.sel_feed) st.urls;
        write_list st.urls; st.sel_feed <- 0; st.sel_item <- -1
      end;
      if Gui.button ui 176 (y + 28) 76 "Reload" then List.iter (start_fetch st) st.urls;
      ignore (Gfx.text g 8 (y + 62) (if st.busy = [] then "" else
                                         Printf.sprintf "reading %d..." (List.length st.busy)) Gui.muted);
      (* the items, and the one chosen *)
      let x = left + 10 in
      let w = width - x - 10 in
      (match List.nth_opt st.urls st.sel_feed with
       | None -> ignore (Gui.paragraph ~colour:Gui.muted ui x 12 w "No feed: add one's address.")
       | Some url ->
         match List.assoc_opt url st.feeds with
         | None -> Gui.label ~colour:Gui.muted ui x 12 ("Reading " ^ url ^ "...")
         | Some (Error m) -> ignore (Gui.paragraph ~colour:0xC62828 ui x 12 w (url ^ ": " ^ m))
         | Some (Ok f) ->
           Gui.label ~bold:true ui x 10 f.name;
           let list_h = if st.sel_item >= 0 then 230 else height - 44 in
           Gui.scroll ui (100 + st.item_page) x 34 w list_h (fun y0 ->
               List.iteri (fun i it ->
                   if Gui.list_item ui (x + 2) (y0 + i * 24) (w - 22) ~selected:(i = st.sel_item) it.title
                   then st.sel_item <- i) f.items;
               24 * List.length f.items);
           match (if st.sel_item < 0 then None else List.nth_opt f.items st.sel_item) with
           | None -> ()
           | Some it ->
             let ty = 34 + list_h + 10 in
             Gfx.fill g x ty w (height - ty - 8) 0xFFFFFF;
             Gfx.rect g x ty w (height - ty - 8) 0xD5DBE1;
             let lines = wrap (w - 24) it.summary in
             Gui.scroll ~colour:0xFFFFFF ui (5000 + st.sel_item + 1000 * st.item_page) (x + 1) (ty + 1) (w - 2) (height - ty - 10)
               (fun y0 ->
                  let tl = wrap (w - 24) it.title in
                  List.iteri (fun i l -> ignore (Gfx.text ~bold:true g (x + 10) (y0 + 8 + i * 18) l Gui.foreground)) tl;
                  let y1 = y0 + 8 + 18 * List.length tl in
                  ignore (Gfx.text g (x + 10) y1 it.date Gui.muted);
                  ignore (Gfx.text ~max:((w - 24) / Gfx.char_w) g (x + 10) (y1 + 18) it.link 0x1F4F7A);
                  List.iteri (fun i l -> ignore (Gfx.text g (x + 10) (y1 + 46 + i * 18) l Gui.foreground)) lines;
                  8 + 18 * List.length tl + 46 + 18 * List.length lines + 8)
      );
      st)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [] -> window ()
  | url :: _ -> terminal url
