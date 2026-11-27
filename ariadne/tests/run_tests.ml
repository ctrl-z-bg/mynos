(* Ariadne's core, checked: the test pages' text against the expected
   dumps, URLs, a deep tree. The same program runs on the host (make -C
   ariadne test) and in MyNOS, as init.byte of its own RAM disk
   (tests/ariadne, a boot of tools/run-tests.sh).

     run_tests              every check
     run_tests --print NAME the dump of the test page NAME (to write its
                            expected text: tests/expected/NAME.txt) *)

let dump_of html = Text.to_text (Text.of_dom (Html.parse html))

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

(* rule 3: a tree far deeper than any stack would allow a recursion *)
let deep () =
  let depth = 5000 in
  let html = String.concat "" (List.init depth (fun _ -> "<div>")) ^ "deep" in
  let doc = Html.parse html in
  check (Printf.sprintf "dom: %d nested elements, walked in a loop" depth)
    (Dom.count doc = depth + 2 && Dom.text_content doc = "deep");
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
  | [ "--print"; name ] ->
    (match List.assoc_opt name Pages.pages with
     | Some html -> print_string (dump_of html)
     | None -> prerr_endline ("no test page " ^ name); exit 2)
  | _ ->
    dom ();
    urls ();
    deep ();
    pages ();
    if !failures = 0 then print_endline "ariadne: all checks passed"
    else (Printf.printf "ariadne: FAIL (%d)\n%!" !failures; exit 1)
