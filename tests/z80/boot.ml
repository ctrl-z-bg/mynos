(* The Spectrum without a window: the ROM's message, then PRINT 2+2 typed
   (P in K mode is PRINT), its 4 on the screen; the frames a second. *)
let () =
  let ic = open_in_bin Sys.argv.(1) in
  let rom = really_input_string ic 16384 in
  close_in ic;
  let s = Spectrum.create ~rom in
  let t0 = Unix.gettimeofday () in
  for _ = 1 to 150 do ignore (Spectrum.run_fast s) done;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "boot: 150 frames in %.2f s: %.0f frames a second\n" dt (150. /. dt);
  print_string (Spectrum.screen_text s);
  Spectrum.queue_keys s (Keyboard.parse "P 2 SS+K 2 ENTER");
  let n = ref 0 in
  while Spectrum.keys_pending s && !n < 500 do ignore (Spectrum.run_fast s); incr n done;
  for _ = 1 to 20 do ignore (Spectrum.run_fast s) done;
  let text = Spectrum.screen_text s in
  print_string text;
  let lines = String.split_on_char '\n' text in
  let ok = List.exists (fun l -> String.trim l = "4") lines in
  print_endline (if ok then "boot: PRINT 2+2 gave 4" else "boot: no 4");
  exit (if ok then 0 else 1)
