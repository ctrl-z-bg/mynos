(* play: sound from the command line (mynos-7jn), through soundd.

     play FILE.wav        a WAV file (PCM, 8 or 16 bits, mono or stereo)
     play -t HZ [MS]      a tone (200 ms by default)
     play -v [LEVEL]      the volume (0 to 100), or what it is
     play check           compare soundd's description of its protocol
                          with module Sound's (the tests) *)

let usage () =
  prerr_endline "usage: play FILE.wav | play -t HZ [MS] | play -v [LEVEL]";
  exit 2

let sound () =
  try Sound.connect () with Mynos.Error _ ->
    prerr_endline "play: no sound service (soundd: a Sound Blaster 16 is needed)";
    exit 1

let int s = match int_of_string_opt s with Some n -> n | None -> usage ()

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "check" ] ->
    ignore (sound ());
    let shape (rs : Ipc.request_doc list) =
      List.map (fun (r : Ipc.request_doc) -> (r.case, r.name, r.args, r.reply, r.safe)) rs in
    let d = Ipc.describe "sound" in
    if d.Ipc.protocol = "sound/1" && shape d.requests = shape Sound.Protocol.requests
       && d.requests = Sound.Protocol.requests
    then print_endline "play: soundd describes sound/1 as sound.ml does"
    else (print_endline "play: soundd's description differs from sound.ml's"; exit 1)
  | [ "-t"; hz ] -> Sound.tone ~sound:(sound ()) (int hz) 200; Mynos.sleep 0.2
  | [ "-t"; hz; ms ] ->
    Sound.tone ~sound:(sound ()) (int hz) (int ms); Mynos.sleep (float (int ms) /. 1000.)
  | [ "-v" ] -> Printf.printf "volume %d\n" (Sound.volume ~sound:(sound ()) (-1))
  | [ "-v"; v ] -> Printf.printf "volume %d\n" (Sound.volume ~sound:(sound ()) (int v))
  | [ file ] when file <> "" && file.[0] <> '-' ->
    (match Sound.play_file ~sound:(sound ()) file with
     | () -> ()
     | exception (Failure m | Sys_error m) -> prerr_endline ("play: " ^ m); exit 1)
  | _ -> usage ()
