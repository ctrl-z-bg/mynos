(* A page rendered to an image on the host, as the window would paint it:
   for comparing Ariadne with a reference browser's screenshot.

     render OUT.ppm WIDTH HEIGHT FILE.html [FILE.css...]

   The page's <style> sheets count, its linked ones are the CSS files
   given; the image is WIDTH x HEIGHT, the page's top. *)

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
    let page = Layout.layout ~width:w ~height:h styles doc in
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
              done) (Fonts.glyphs font s)) page.items;
    Out_channel.with_open_bin out (fun oc ->
        Printf.fprintf oc "P6\n%d %d\n255\n" w h;
        output_bytes oc img)
  | _ -> prerr_endline "usage: render OUT.ppm WIDTH HEIGHT FILE.html [FILE.css...]"; exit 2
