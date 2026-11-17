(* A clock: its hands drawn with Gfx.line, every second. *)

let () =
  let size = 220 in
  Gui.run ~title:"Clock" ~tick:1.0 size (size + 30) () (fun ui () ->
      let g = ui.Gui.g in
      let cx = size / 2 and cy = size / 2 and r = size / 2 - 14 in
      (* the face *)
      for y = -r to r do
        let half = int_of_float (sqrt (float (r * r - y * y))) in
        Gfx.fill g (cx - half) (cy + y) (2 * half) 1 0xFFFFFF
      done;
      for i = 0 to 59 do
        let a = float i *. Float.pi /. 30. in
        let l = if i mod 5 = 0 then 12 else 4 in
        let x0 = cx + int_of_float (float (r - l) *. sin a)
        and y0 = cy - int_of_float (float (r - l) *. cos a)
        and x1 = cx + int_of_float (float (r - 2) *. sin a)
        and y1 = cy - int_of_float (float (r - 2) *. cos a) in
        Gfx.line g x0 y0 x1 y1 (if i mod 5 = 0 then 0x1A2228 else 0x9AA5AF)
      done;
      let now = Mynos.time () in
      let secs = int_of_float (Float.rem now 86400.) in   (* now: beyond 31-bit ints *)
      let h = secs / 3600 and m = secs / 60 mod 60 and s = secs mod 60 in
      let hand frac len colour width =
        let a = frac *. 2. *. Float.pi in
        let x = cx + int_of_float (float len *. sin a)
        and y = cy - int_of_float (float len *. cos a) in
        for d = -(width / 2) to width / 2 do
          Gfx.line g (cx + d) cy (x + d) y colour;
          Gfx.line g cx (cy + d) x (y + d) colour
        done in
      hand ((float (h mod 12) +. float m /. 60.) /. 12.) (r * 5 / 10) 0x1A2228 4;
      hand ((float m +. float s /. 60.) /. 60.) (r * 8 / 10) 0x1A2228 2;
      hand (float s /. 60.) (r * 9 / 10) 0xD9534F 0;
      Gfx.fill g (cx - 3) (cy - 3) 6 6 0xD9534F;
      let label = Printf.sprintf "%02d:%02d:%02d UTC" h m s in
      Gui.label ~bold:true ui ((size - Gfx.cells label * 8) / 2) (size + 4) label)
