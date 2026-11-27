(* Ariadne's core, checked: the test pages' text against the expected
   dumps, URLs, a deep tree. The same program runs on the host (make -C
   ariadne test) and in MyNOS, as init.byte of its own RAM disk
   (tests/ariadne, a boot of tools/run-tests.sh).

     run_tests              every check
     run_tests --print NAME the dump of the test page NAME (to write its
                            expected text: tests/expected/NAME.txt) *)

let dump_of html = Text.to_text (Text.of_dom (Html.parse html))

(* a page laid out 800 pixels wide, with its <style> sheets (no network) *)
let layout_of html =
  let doc = Html.parse html in
  let sheets = List.concat_map (function
      | Style.Inline_sheet (t, media) -> [ Style.parse_sheet ?media t ]
      | Style.Linked _ -> []) (Style.sources doc) in
  Layout.dump (Layout.layout ~width:800 ~height:600 (Style.compute ~width:800 ~height:600 sheets doc) doc)

let failures = ref 0

let check what ok =
  Printf.printf "ariadne: %-52s %s\n%!" what (if ok then "ok" else "FAIL");
  if not ok then incr failures

(* the first line that differs, to say what went wrong *)
let first_difference a b =
  let la = String.split_on_char '\n' a and lb = String.split_on_char '\n' b in
  let rec go i la lb = match la, lb with
    | x :: ra, y :: rb -> if x = y then go (i + 1) ra rb else Some (i, x, y)
    | x :: _, [] -> Some (i, x, "(nothing)")
    | [], y :: _ -> Some (i, "(nothing)", y)
    | [], [] -> None in
  go 1 la lb

let pages () =
  List.iter (fun (name, html) ->
      match List.assoc_opt name Expected.expected with
      | None -> check ("page " ^ name ^ ": has an expected text") false
      | Some want ->
        let got = dump_of html in
        check ("page " ^ name) (got = want);
        match first_difference got want with
        | Some (i, g, w) when got <> want ->
          Printf.printf "ariadne:   line %d: got      %S\nariadne:   line %d: expected %S\n" i g i w
        | _ -> ()) Pages.pages

let layouts () =
  List.iter (fun (name, html) ->
      match List.assoc_opt name Expected_layout.expected_layout with
      | None -> check ("layout " ^ name ^ ": has an expected display list") false
      | Some want ->
        let got = layout_of html in
        check ("layout " ^ name) (got = want);
        match first_difference got want with
        | Some (i, g, w) when got <> want ->
          Printf.printf "ariadne:   line %d: got      %S\nariadne:   line %d: expected %S\n" i g i w
        | _ -> ()) Pages.pages

let urls () =
  let r = Url.resolve in
  check "url: a relative link" (r "https://a.org/x/y.html" "z.html" = "https://a.org/x/z.html");
  check "url: dots" (r "https://a.org/x/y/" "../z" = "https://a.org/x/z");
  check "url: an absolute path" (r "https://a.org/x/y" "/z?q=1" = "https://a.org/z?q=1");
  check "url: a fragment" (r "https://a.org/x#old" "#new" = "https://a.org/x#new");
  check "url: no scheme" (r "https://a.org/x" "//b.org/y" = "https://b.org/y");
  check "url: a test page's link" (r "about:test/basic" "lists.html" = "about:test/lists.html");
  check "url: what was typed" (Url.of_typed "example.com" = "https://example.com"
                               && Url.of_typed "/disk/a.html" = "file:/disk/a.html")

(* the bytes' encoding, found and decoded *)
let encodings () =
  let enc ?transport s = fst (Encoding.sniff ?transport s) in
  check "encoding: a byte order mark" (enc "\xEF\xBB\xBFx" = Encoding.Utf8 && enc "\xFF\xFEx\000" = Encoding.Utf16le);
  check "encoding: the HTTP header's charset" (enc ~transport:"ISO-8859-1" "caf\xC3\xA9" = Encoding.Windows_1252);
  check "encoding: <meta charset>" (enc "<html><meta charset=\"latin1\">caf\xC3\xA9" = Encoding.Windows_1252);
  check "encoding: <meta http-equiv>"
    (enc "<meta http-equiv=Content-Type content='text/html; charset=windows-1252'>" = Encoding.Windows_1252);
  check "encoding: a <meta> inside a comment is not read"
    (enc "<!-- <meta charset=latin1> -->caf\xC3\xA9" = Encoding.Utf8);
  check "encoding: valid UTF-8 guessed, else windows-1252"
    (enc "caf\xC3\xA9" = Encoding.Utf8 && enc "caf\xE9" = Encoding.Windows_1252);
  check "encoding: windows-1252 decoded" (snd (Encoding.to_utf8 "\x80 caf\xE9") = "\xE2\x82\xAC caf\xC3\xA9");
  check "encoding: bad UTF-8 becomes U+FFFD"
    (Encoding.decode Encoding.Utf8 "a\xC3(\xF0\x9F\x98" = "a\xEF\xBF\xBD(\xEF\xBF\xBD");
  check "encoding: UTF-16 with a surrogate pair"
    (Encoding.decode Encoding.Utf16le "A\000\x3D\xD8\x00\xDE" = "A\xF0\x9F\x98\x80")

(* the fonts: values checked against fontTools *)
let fonts () =
  match Fonts.face "LiberationSans-Regular.ttf" with
  | None -> check "fonts: LiberationSans-Regular.ttf found" false
  | Some t ->
    let gi c = Ttf.glyph_index t c in
    check "ttf: cmap (A, e acute, alpha)" (gi 0x41 = 36 && gi 0xE9 = 171 && gi 0x3B1 = 867);
    check "ttf: advances" (Ttf.advance t 36 = 1366 && Ttf.advance t 68 = 1139);
    check "ttf: kerning (A V)" (Ttf.kern t 36 57 = -152);
    check "ttf: a composite glyph has contours" (Ttf.contours t 171 <> []);
    let b = Ttf.rasterize t 36 ~size:16 in
    let inked = String.fold_left (fun k c -> if Char.code c < 128 then k + 1 else k) 0 b.grey in
    check "ttf: A at 16 px is 11 x 12 (its top: 11.008 px), partly inked" (b.width = 11 && b.height = 12 && inked > 10 && inked < 100);
    let f = Fonts.get ~family:Fonts.Sans ~bold:false ~italic:false ~size:16 in
    check "fonts: AV at 16 px, kerned" (Fonts.width f "AV" = 20);
    check "fonts: families" (Fonts.family_of "Arial, sans-serif" = Fonts.Sans
                             && Fonts.family_of "'Linux Libertine','Georgia',serif" = Fonts.Serif
                             && Fonts.family_of "monospace" = Fonts.Mono)

(* an img's source: <picture>, src, srcset (M4) *)
let sources () =
  let first_img html =
    Option.get (Dom.find (fun n -> Dom.is_html n "img") (Html.parse html)) in
  let src ?vw html = Layout.img_source ?vw (first_img html) in
  check "img: src" (src {|<img src="a.png" srcset="b.png 2x">|} = Some "a.png");
  check "img: srcset by density" (src {|<img srcset="a.png 2x, b.png 1x, c.png 1.5x">|} = Some "b.png");
  check "img: srcset by width" (src ~vw:500 {|<img srcset="s.jpg 320w, m.jpg 640w, l.jpg 1280w">|} = Some "m.jpg"
                                && src ~vw:2000 {|<img srcset="s.jpg 320w, l.jpg 1280w">|} = Some "l.jpg");
  check "img: picture: not WebP"
    (src {|<picture><source srcset="a.webp" type="image/webp"><source srcset="a.jpg" type="image/jpeg"><img src="z.png"></picture>|}
     = Some "a.jpg");
  check "img: picture: a media query's source skipped, then src"
    (src {|<picture><source srcset="w.png" media="(min-width: 800px)"><img src="z.png"></picture>|} = Some "z.png")

(* forms: the state, what controls show, a submission (M5) *)
let forms () =
  let doc = Html.parse (List.assoc "forms" Pages.pages) in
  let by_name n = Option.get (Dom.find (fun x -> Dom.attr x "name" = Some n) doc) in
  let forms = let out = ref [] in
    Dom.iter (fun x -> if Dom.is_html x "form" then out := x :: !out) doc; List.rev !out in
  let f = List.hd forms in
  check "forms: the controls of a form, one outside it"
    (List.map (fun n -> Option.value (Dom.attr n "name") ~default:"-") (Forms.controls f)
     = [ "name"; "q"; "pw"; "c"; "d"; "r"; "r"; "s"; "t"; "go"; "-"; "no"; "out" ]);
  check "forms: what they show"
    ((Forms.shown (by_name "pw")).text = "\xe2\x80\xa2\xe2\x80\xa2"
     && (Forms.shown (by_name "q")).placeholder && (Forms.shown (by_name "q")).text = "Search..."
     && (Forms.shown (by_name "s")).text = "second"
     && (Forms.shown (by_name "c")).mark = `Check && (Forms.shown (by_name "d")).mark = `None);
  let base = "about:test/forms" in
  check "forms: GET, by a button"
    (Forms.submit ~base ~submitter:(by_name "go") f
     = Forms.Get "about:test/basic?name=Ada&q=&pw=ab&c=on&r=2&s=b&t=hello&h=x+y%26z&go=Send&out=1");
  Forms.toggle (by_name "d");
  Forms.toggle (Option.get (Dom.find (fun x -> Dom.attr x "value" = Some "1") doc));
  Forms.set_value (by_name "name") "Grace Hopper";
  Forms.select (by_name "s") (List.nth (Forms.options (by_name "s")) 2);
  check "forms: changed, and by Enter (no button)"
    (Forms.submit ~base f
     = Forms.Get "about:test/basic?name=Grace+Hopper&q=&pw=ab&c=on&d=yes&r=1&s=third&t=hello&h=x+y%26z&out=1");
  check "forms: POST, a button element's value"
    (Forms.submit ~base:"https://a.org/x" ~submitter:(by_name "btn") (List.nth forms 1)
     = Forms.Post ("https://a.org/post", "a=b&btn=v"))

(* rule 3: a tree far deeper than any stack would allow a recursion *)
let deep () =
  let depth = 5000 in
  let html = String.concat "" (List.init depth (fun _ -> "<div>")) ^ "deep" in
  let doc = Html.parse html in
  check (Printf.sprintf "dom: %d nested elements, walked in a loop" depth)
    (Dom.count doc = depth + 5 && Dom.text_content doc = "deep")   (* the document, html, head, body, the text *);
  check "text: the deep tree's text" ((Text.of_dom doc).blocks = Text.[ { kind = Paragraph; text = "deep" } ])

let dom () =
  let p = Dom.element "p" and a = Dom.text "a" and b = Dom.text "b" and c = Dom.text "c" in
  Dom.append p a; Dom.append p c; Dom.insert_before p b (Some c);
  check "dom: insert before" (Dom.text_content p = "abc");
  Dom.remove b;
  check "dom: remove" (Dom.text_content p = "ac" && b.Dom.parent = None);
  Dom.append p a;
  check "dom: append moves a node" (Dom.text_content p = "ca" && List.length (Dom.children p) = 2)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "--print-layout"; name ] ->
    (match List.assoc_opt name Pages.pages with
     | Some html -> print_string (layout_of html)
     | None -> prerr_endline ("no test page " ^ name); exit 2)
  | [ "--print"; name ] ->
    (match List.assoc_opt name Pages.pages with
     | Some html -> print_string (dump_of html)
     | None -> prerr_endline ("no test page " ^ name); exit 2)
  | _ ->
    dom ();
    urls ();
    encodings ();
    fonts ();
    sources ();
    forms ();
    deep ();
    pages ();
    layouts ();
    if !failures = 0 then print_endline "ariadne: all checks passed"
    else (Printf.printf "ariadne: FAIL (%d)\n%!" !failures; exit 1)
