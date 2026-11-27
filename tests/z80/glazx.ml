(* GLAZX's tape, loaded at once: frames until its blocks are read, then
   its title screen, as PNG files *)
let () =
  let read f = let ic = open_in_bin f in let s = really_input_string ic (in_channel_length ic) in close_in ic; s in
  let s = Spectrum.create ~rom:(read Sys.argv.(1)) in
  print_endline (Spectrum.load s Sys.argv.(2));
  let t0 = Unix.gettimeofday () in
  for i = 1 to 600 do
    ignore (Spectrum.run_fast s);
    if i mod 150 = 0 then
      Png.save (Printf.sprintf "%s/glazx-%d.png" Sys.argv.(3) i) ~width:Ula.width ~height:Ula.height (Spectrum.screen s)
  done;
  Printf.printf "600 frames in %.1f s\n" (Unix.gettimeofday () -. t0);
  print_string (Spectrum.screen_text s)
