(* Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).

     ariadne [URL]           a window (the start page without a URL)
     ariadne --dump URL      the page as text, and its links
     ariadne --time URL      the time of each stage

   M0, the skeleton: a page is loaded (Loader), parsed (Html, into Dom)
   and read as text (Text); the window shows that text. *)

let usage () =
  prerr_endline "usage: ariadne [URL] | ariadne --dump URL | ariadne --time URL";
  exit 2

type loaded = {
  response : Loader.response;
  doc : Dom.node;
  page : Text.page;
}

let load url =
  let response = Loader.load (Url.of_typed url) in
  let doc = Html.parse (Loader.to_html response) in
  { response; doc; page = Text.of_dom doc }

(* ---- --dump and --time ---- *)

let dump url =
  let l = load url in
  print_string (Text.to_text l.page);
  if l.page.links <> [] then begin
    print_string "links:\n";
    List.iteri (fun i h -> Printf.printf "%d. %s\n" (i + 1) (Url.resolve l.response.url h)) l.page.links
  end

let time url =
  let now = Unix.gettimeofday in
  let ms a b = (b -. a) *. 1000. in
  let t0 = now () in
  let r = Loader.load (Url.of_typed url) in
  let t1 = now () in
  let doc = Html.parse (Loader.to_html r) in
  let t2 = now () in
  let page = Text.of_dom doc in
  let t3 = now () in
  Printf.printf "ariadne: %s (%s)\n" r.url r.status;
  Printf.printf "  load  %6.0f ms  %d bytes\n" (ms t0 t1) (String.length r.body);
  Printf.printf "  parse %6.0f ms  %d nodes\n" (ms t1 t2) (Dom.count doc);
  Printf.printf "  text  %6.0f ms  %d blocks\n" (ms t2 t3) (List.length page.blocks);
  Printf.printf "  total %6.0f ms\n" (ms t0 t3)

(* ---- the window ---- *)

(* the page's text as lines of the window's monospaced font, for a width *)
type line = { x : int; y : int; s : string; colour : int }

let line_h = 18

(* characters, not bytes: UTF-8's continuation bytes do not count *)
let cells s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* [s] cut into lines of at most [cols] characters, at spaces; a word
   longer than a line is cut *)
let wrap cols s =
  let cols = max 8 cols in
  List.concat_map (fun para ->
      let words = List.filter (fun w -> w <> "") (String.split_on_char ' ' para) in
      let lines = ref [] and cur = Buffer.create 80 and len = ref 0 in
      let push () = lines := Buffer.contents cur :: !lines; Buffer.clear cur; len := 0 in
      List.iter (fun w ->
          let wl = cells w in
          if !len > 0 && !len + 1 + wl > cols then push ();
          if !len > 0 then (Buffer.add_char cur ' '; incr len);
          Buffer.add_string cur w; len := !len + wl;
          if !len > cols then push ()) words;
      if !len > 0 || !lines = [] then push ();
      List.rev !lines) (String.split_on_char '\n' s)

let lay_out width (page : Text.page) =
  let out = ref [] and y = ref 8 in
  let cols x = (width - x - 16) / Gfx.char_w in
  let add x colour s = out := { x; y = !y; s; colour } :: !out; y := !y + line_h in
  List.iter (fun (b : Text.block) ->
      (match b.kind with
       | Heading n ->
         y := !y + (if n <= 2 then 10 else 4);
         List.iter (add 12 Gui.accent) (wrap (cols 12) b.text)
       | Paragraph -> List.iter (add 12 Gui.foreground) (wrap (cols 12) b.text)
       | Item d ->
         let x = 12 + 16 * d in
         (match wrap (cols x) b.text with
          | first :: rest ->
            out := { x = x - 12; y = !y; s = "-"; colour = Gui.muted } :: !out;
            add x Gui.foreground first; List.iter (add x Gui.foreground) rest
          | [] -> ())
       | Pre -> List.iter (add 20 0x3A4A5A) (String.split_on_char '\n' b.text)
       | Rule -> out := { x = 12; y = !y + line_h / 2; s = ""; colour = 0xC0C8D0 } :: !out; y := !y + line_h);
      y := !y + 6) page.blocks;
  (Array.of_list (List.rev !out), !y + 8)

type st = {
  mutable shown : loaded;
  mutable laid : (int * (line array * int)) option;    (* for a width *)
  mutable address : string;
  mutable loading : (string * int) option;             (* a load running: its number *)
}

(* how far the page is scrolled, as last drawn *)
let offset = ref 0

let window first =
  let lock = Mutex.create () in
  let arrived : (int * loaded) option ref = ref None in
  let loads = ref 0 in
  let st = { shown = load "about:start"; laid = None; address = first; loading = None } in
  let start url =
    incr loads;
    let n = !loads in
    st.loading <- Some (url, n);
    st.address <- url;
    ignore (Thread.create (fun () ->
        let l = load url in
        Mutex.protect lock (fun () -> arrived := Some (n, l))) ()) in
  if first <> "about:start" then start first;
  Gui.run ~title:"Ariadne" ~tick:0.1 ~resizable:(400, 300) 900 640 st (fun ui st ->
      let g = ui.Gui.g and width = Gui.width ui and height = Gui.height ui in
      (* a page arrived: shown, if it is the one asked for last *)
      (match Mutex.protect lock (fun () -> let a = !arrived in arrived := None; a) with
       | Some (n, l) when (match st.loading with Some (_, m) -> m = n | None -> false) ->
         st.shown <- l; st.laid <- None; st.loading <- None;
         st.address <- l.response.url;
         Gui.scroll_to ui 2 0
       | _ -> ());
      (* the bar: Reload or Stop, the address, Go *)
      Gfx.fill g 0 0 width 40 0x1B3A57;
      let reload = Gui.button ui 6 7 70 (if st.loading <> None then "Stop" else "Reload") in
      let field_w = width - 82 - 64 in
      st.address <- Gui.text_field ui 1 82 9 field_w st.address;
      let enter = ui.Gui.field = 1 && List.exists (fun k -> k = "\r" || k = "\n") ui.Gui.keys in
      let go = Gui.button ui (width - 58) 7 52 "Go" in
      if (enter || go) && String.trim st.address <> "" then begin
        ui.Gui.field <- 0; start (Url.of_typed st.address)
      end;
      if reload then begin
        if st.loading <> None then (st.loading <- None; st.address <- st.shown.response.url)
        else start st.shown.response.url
      end;
      (* the page: laid out once per width, only the lines in view drawn *)
      let box_y = 44 and box_h = height - 44 - 24 in
      let page_w = width - 8 in
      let lines, total = match st.laid with
        | Some (w, l) when w = page_w -> l
        | _ -> let l = lay_out page_w st.shown.page in st.laid <- Some (page_w, l); l in
      (* the keys scroll the page, when the address does not have them *)
      if ui.Gui.field <> 1 then
        List.iter (fun k ->
            match k with
            | "\027[6~" | " " -> Gui.scroll_to ui 2 (max 0 (min (total - box_h) (!offset + box_h - 2 * line_h)))
            | "\027[5~" -> Gui.scroll_to ui 2 (max 0 (!offset - box_h + 2 * line_h))
            | "\027[H" | "\027[1~" -> Gui.scroll_to ui 2 0
            | "\027[F" | "\027[4~" -> Gui.scroll_to_end ui 2
            | _ -> ()) ui.Gui.keys;
      Gui.scroll ~colour:0xFFFFFF ui 2 4 box_y page_w box_h (fun top ->
          offset := box_y - top;
          Array.iter (fun l ->
              let y = top + l.y in
              if y > box_y - line_h && y < box_y + box_h then
                if l.s = "" then Gfx.fill g l.x y (page_w - 2 * l.x) 1 l.colour
                else ignore (Gui.text ui l.x y l.s l.colour)) lines;
          total);
      (* the status line *)
      Gfx.fill g 0 (height - 22) width 22 0xE8EDF2;
      let status = match st.loading with
        | Some (u, _) -> "loading " ^ u ^ "..."
        | None ->
          let p = st.shown.page in
          (if p.title <> "" then p.title ^ "  \xc2\xb7  " else "") ^ st.shown.response.status in
      ignore (Gfx.text ~max:((width - 16) / Gfx.char_w) g 8 (height - 19) status Gui.muted);
      st)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--dump"; url ] -> dump url
  | [ "--time"; url ] -> time url
  | [ url ] when url <> "" && url.[0] <> '-' -> window (Url.of_typed url)
  | [] -> window "about:start"
  | _ -> usage ()
