(* The core's stages timed on saved pages, on the host: decoding, parsing,
   reading the text; with style sheets, their parsing, the cascade and
   layout. The best of three runs of each.
     bench FILE.html... [--css FILE.css...]   (make -C ariadne tests/bench.byte)
   The pages' <style> sheets count; their linked ones are the --css files. *)

let time f =
  let best = ref infinity and result = ref None in
  for _ = 1 to 3 do
    let t0 = Unix.gettimeofday () in
    let r = f () in
    best := Float.min !best (Unix.gettimeofday () -. t0);
    result := Some r
  done;
  (Option.get !result, !best *. 1000.)

let read f = In_channel.with_open_bin f In_channel.input_all

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let rec split pages = function
    | "--css" :: css -> (List.rev pages, css)
    | p :: r -> split (p :: pages) r
    | [] -> (List.rev pages, []) in
  let pages, css = split [] args in
  List.iter (fun file ->
      let bytes = read file in
      let (e, text), t_dec = time (fun () -> Encoding.to_utf8 bytes) in
      let ntok, t_tok = time (fun () ->
          let tk = Tokenizer.create text in
          let rec go n = match Tokenizer.next tk with Tokenizer.Eof -> n | _ -> go (n + 1) in
          go 0) in
      let doc, t_parse = time (fun () -> Html.parse text) in
      let page, t_text = time (fun () -> Text.of_dom doc) in
      Printf.printf "%s: %d bytes %s\n  decode %5.0f ms\n  tokens %5.0f ms (%d tokens)\n  parse  %5.0f ms (%d nodes)\n  text   %5.0f ms (%d blocks)\n%!"
        (Filename.basename file) (String.length bytes) (Encoding.name e) t_dec t_tok ntok t_parse
        (Dom.count doc) t_text (List.length page.Text.blocks);
      let sheets, t_css = time (fun () ->
          List.concat_map (function
              | Style.Inline_sheet (t, media) -> [ Style.parse_sheet ?media t ]
              | Style.Linked _ -> []) (Style.sources doc)
          @ List.map (fun f -> Style.parse_sheet (read f)) css) in
      let rules = List.fold_left (fun a (s : Style.sheet) -> a + List.length s.rules) 0 sheets in
      let styles, t_cascade = time (fun () -> Style.compute ~width:866 ~height:600 sheets doc) in
      let p, t_layout = time (fun () -> Layout.layout ~width:866 ~height:600 styles doc) in
      Printf.printf "  css    %5.0f ms (%d sheets, %d rules)\n  cascade %4.0f ms\n  layout %5.0f ms (%d items)\n%!"
        t_css (List.length sheets) rules t_cascade t_layout (Array.length p.Layout.items);
      (* BENCH_DUMP=file: the display list, written there *)
      match Sys.getenv_opt "BENCH_DUMP" with
      | Some f -> Out_channel.with_open_bin f (fun oc -> output_string oc (Layout.dump p))
      | None -> ()) pages
