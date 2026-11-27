(* The Spectrum's speed on the host, in bytecode, as zxspectrum --bench
   measures it in MyNOS: GLAZX loaded (its title screen, animated), then
   N frames, each run and its picture made *)
let () =
  let read f = let ic = open_in_bin f in let s = really_input_string ic (in_channel_length ic) in close_in ic; s in
  let s = Spectrum.create ~rom:(read Sys.argv.(1)) in
  ignore (Spectrum.load s Sys.argv.(2));
  for _ = 1 to 600 do ignore (Spectrum.run_fast s) done;
  let n = int_of_string Sys.argv.(3) in
  let t0 = Unix.gettimeofday () in
  for _ = 1 to n do ignore (Spectrum.run_fast s); ignore (Spectrum.screen s) done;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "bench: %d frames in %.2f s: %.0f frames a second\n" n dt (float n /. dt)
