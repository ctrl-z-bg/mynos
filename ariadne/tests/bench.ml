(* The core's stages timed on saved pages, on the host: decoding, parsing,
   reading the text. The best of three runs of each.
     bench FILE...        (make -C ariadne tests/bench.byte) *)

let time f =
  let best = ref infinity and result = ref None in
  for _ = 1 to 3 do
    let t0 = Unix.gettimeofday () in
    let r = f () in
    best := Float.min !best (Unix.gettimeofday () -. t0);
    result := Some r
  done;
  (Option.get !result, !best *. 1000.)

let () =
  Array.iteri (fun i file ->
      if i > 0 then begin
        let bytes = In_channel.with_open_bin file In_channel.input_all in
        let (e, text), t_dec = time (fun () -> Encoding.to_utf8 bytes) in
        let ntok, t_tok = time (fun () ->
            let tk = Tokenizer.create text in
            let rec go n = match Tokenizer.next tk with Tokenizer.Eof -> n | _ -> go (n + 1) in
            go 0) in
        Printf.printf "%-28s tokenizer alone %5.0f ms (%d tokens)\n" (Filename.basename file) t_tok ntok;
        let doc, t_parse = time (fun () -> Html.parse text) in
        let page, t_text = time (fun () -> Text.of_dom doc) in
        Printf.printf "%-28s %7d bytes %-12s decode %5.0f ms  parse %5.0f ms (%d nodes)  text %4.0f ms (%d blocks)\n%!"
          (Filename.basename file) (String.length bytes) (Encoding.name e) t_dec t_parse
          (Dom.count doc) t_text (List.length page.Text.blocks)
      end) Sys.argv
