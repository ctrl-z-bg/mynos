(* A page rendered to an image on the host, as the window would paint it:
   for comparing Ariadne with a reference browser's screenshot.

     render OUT.ppm WIDTH HEIGHT FILE.html [FILE.css...]

   The page's <style> sheets count, its linked ones are the CSS files
   given; the image is WIDTH x HEIGHT, the page's top. Pictures: with
   ARIADNE_PICTURES=LIST, a file of lines "src<TAB>local file", decoded by
   imaged's code as the host's command services/image/picture (make -C
   services/image picture; ARIADNE_PICTURE_TOOL says where it is). With
   ARIADNE_PICTURE_CACHE=DIR, a picture that is not in the list and has an
   http(s) URL is read from DIR/(the MD5 of its URL, in hex), or else its
   URL noted in DIR/missing, to be downloaded there for the next run. *)

let tool = Option.value (Sys.getenv_opt "ARIADNE_PICTURE_TOOL") ~default:"../services/image/picture"

let pictures =
  match Sys.getenv_opt "ARIADNE_PICTURES" with
  | None -> []
  | Some f ->
    List.filter_map (fun l -> match String.index_opt l '\t' with
        | Some i -> Some (String.sub l 0 i, String.sub l (i + 1) (String.length l - i - 1))
        | None -> None) (In_channel.with_open_bin f In_channel.input_lines)

(* a picture at w x h (0 x 0: its own size): its own size, and its pixels
   (blue, green, red, alpha) *)
(* a picture's local file: from the list, or downloaded *)
let local src =
  match List.assoc_opt src pictures, Sys.getenv_opt "ARIADNE_PICTURE_CACHE" with
  | Some f, _ -> Some f
  | None, Some dir when String.length src > 4 && String.sub src 0 4 = "http" ->
    let f = Filename.concat dir (Digest.to_hex (Digest.string src)) in
    if Sys.file_exists f then Some f
    else begin
      (* noted in DIR/missing, for a download on the host (no network here) *)
      Out_channel.with_open_gen [ Open_append; Open_creat ] 0o644 (Filename.concat dir "missing")
        (fun oc -> output_string oc (src ^ "\n"));
      None
    end
  | _ -> None

let picture =
  let cache = Hashtbl.create 16 in
  fun src w h ->
    match Hashtbl.find_opt cache (src, w, h) with
    | Some r -> r
    | None ->
      let r = match local src with
        | None -> None
        | Some file ->
          let out = Filename.temp_file "picture" ".bgra" in
          let cmd = Printf.sprintf "%s %s %d %d %s 2>/dev/null" (Filename.quote tool) (Filename.quote file) w h
              (Filename.quote out) in
          let r = if Sys.command cmd <> 0 then None
            else In_channel.with_open_bin out (fun ic ->
                match String.split_on_char ' ' (Option.get (In_channel.input_line ic)) |> List.map int_of_string with
                | [ nw; nh; pw; ph ] -> Some ((nw, nh), (pw, ph, In_channel.input_all ic))
                | _ -> None) in
          Sys.remove out; r in
      Hashtbl.replace cache (src, w, h) r; r

let () =
  match List.tl (Array.to_list Sys.argv) with
  | out :: w :: h :: html :: css ->
    let w = int_of_string w and h = int_of_string h in
    let read f = In_channel.with_open_bin f In_channel.input_all in
    let _, text = Encoding.to_utf8 (read html) in
    let doc = Html.parse text in
    let sheets = List.concat_map (function
        | Style.Inline_sheet (t, media) -> [ Style.parse_sheet ?media t ]
        | Style.Linked _ -> []) (Style.sources doc)
      @ List.map (fun f -> Style.parse_sheet (read f)) css in
    let styles = Style.compute ~width:w ~height:h sheets doc in
    let image src = Option.map fst (picture src 0 0) in
    let page = Layout.layout ~image ~width:w ~height:h styles doc in
    let img = Bytes.make (w * h * 3) '\255' in
    let put x y c a =
      if x >= 0 && y >= 0 && x < w && y < h && a > 0 then begin
        let i = (y * w + x) * 3 in
        let mix k v = let old = Char.code (Bytes.get img (i + k)) in
          Bytes.set img (i + k) (Char.chr ((old * (255 - a) + v * a) / 255)) in
        mix 0 ((c lsr 16) land 255); mix 1 ((c lsr 8) land 255); mix 2 (c land 255)
      end in
    let fill x y fw fh c = for j = max 0 y to min (h - 1) (y + fh - 1) do
        for i = max 0 x to min (w - 1) (x + fw - 1) do put i j c 255 done done in
    fill 0 0 w h page.Layout.background;
    Array.iter (function
        | Layout.Fill { x; y; w = fw; h = fh; color } -> fill x y fw fh color
        | Layout.Text { x; y; s; color; font } ->
          List.iter (fun (dx, dy, (b : Ttf.bitmap)) ->
              for j = 0 to b.height - 1 do
                for i = 0 to b.width - 1 do
                  put (x + dx + i) (y + dy + j) color (255 - Char.code b.grey.[j * b.width + i])
                done
              done) (Fonts.glyphs font s)
        | Layout.Image { x; y; w = iw; h = ih; src; clip } ->
          let x0, y0, x1, y1 = Option.value clip ~default:(min_int, min_int, max_int, max_int) in
          (match picture src iw ih with
           | Some (_, (pw, ph, px)) ->
             for j = 0 to ph - 1 do
               for i = 0 to pw - 1 do
                 let px_x = x + i and px_y = y + j in
                 if px_x >= x0 && px_x < x1 && px_y >= y0 && px_y < y1 then begin
                   let o = (j * pw + i) * 4 in
                   let c k = Char.code px.[o + k] in
                   put px_x px_y ((c 2 lsl 16) lor (c 1 lsl 8) lor c 0) (c 3)
                 end
               done
             done
           | None -> ())
        | Layout.Bg { x; y; w = bw; h = bh; layer; tint; clip } ->
          (match layer.image with
           | Some src ->
             (match picture src 0 0 with
              | Some (natural, _) ->
                let x0, y0, x1, y1 = match clip with
                  | Some (a, b, c, d) -> (max a x, max b y, min c (x + bw), min d (y + bh))
                  | None -> (x, y, x + bw, y + bh) in
                List.iter (fun (tx, ty, tw, th) ->
                    match picture src tw th with
                    | Some (_, (pw, ph, px)) ->
                      for j = 0 to ph - 1 do
                        for i = 0 to pw - 1 do
                          let px_x = tx + i and px_y = ty + j in
                          if px_x >= x0 && px_x < x1 && px_y >= y0 && px_y < y1 then begin
                            let o = (j * pw + i) * 4 in
                            let c k = Char.code px.[o + k] in
                            let colour = match tint with
                              | Some t -> t | None -> (c 2 lsl 16) lor (c 1 lsl 8) lor c 0 in
                            put px_x px_y colour (c 3)
                          end
                        done
                      done
                    | None -> ()) (Layout.tiles ~x ~y ~w:bw ~h:bh layer ~natural)
              | None -> ())
           | None -> ())) page.items;
    Out_channel.with_open_bin out (fun oc ->
        Printf.fprintf oc "P6\n%d %d\n255\n" w h;
        output_bytes oc img)
  | _ -> prerr_endline "usage: render OUT.ppm WIDTH HEIGHT FILE.html [FILE.css...]"; exit 2
