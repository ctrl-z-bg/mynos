(* camlboy: a Game Boy, in a window. The emulator is CAMLBOY, by
   linoscope (MIT, third_party/camlboy); this is its face in MyNOS.

     camlboy ROM.gb

   Arrows: the cross; X: A; Z: B; Enter: Start; Space: Select; P pauses;
   Escape quits. The game runs at its own pace, 60 frames a second, when
   the machine is fast enough: on a PC or under KVM; in QEMU without KVM,
   at about a third of it.

   A button is down while one of its keys is held (Gui's held keys: the
   window gets the keys' releases), several at once: Right held, X
   jumps, and Mario goes on running.

   Sound: the Game Boy's (third_party/camlboy/src/apu.ml), through
   MyNOS's sound service when there is one; M turns it off and on. A
   thread of its own sends the samples, so that the game never waits for
   them; if it falls behind by more than a tenth of a second the oldest
   are dropped. Below 50 frames a second for four seconds (QEMU without
   KVM, v86) the sound would stutter: it goes off by itself. *)

let gb_w = 160 and gb_h = 144 and scale = 3
let width = gb_w * scale and height = gb_h * scale + 24

let colour = function
  | `White -> 0xE5FBF4 | `Light_gray -> 0x97AEB8 | `Dark_gray -> 0x61687D | `Black -> 0x221E31

let () =
  let rom = match List.tl (Array.to_list Sys.argv) with
    | r :: _ -> r
    | [] -> prerr_endline "usage: camlboy ROM.gb"; exit 2 in
  let rom_bytes = match Read_rom_file.f rom with
    | b -> b
    | exception Sys_error m -> prerr_endline ("camlboy: " ^ m); exit 1 in
  let cartridge = Detect_cartridge.f ~rom_bytes in
  let module C = Camlboy.Make (val cartridge) in
  let gb = C.create_with_rom ~rom_bytes ~print_serial_port:false in
  let screen = Gfx.create width (gb_h * scale) in
  let row = Gfx.create width 1 in
  let down = ref [] in                       (* the buttons down *)
  let paused = ref false in
  let frames = ref 0 and since = ref (Mynos.uptime ()) and fps = ref 0. in
  let keys = [ "\027[A", Joypad.Up; "\027[B", Joypad.Down; "\027[D", Joypad.Left;
               "\027[C", Joypad.Right; "x", Joypad.A; "X", Joypad.A; "z", Joypad.B;
               "Z", Joypad.B; "\r", Joypad.Start; "\n", Joypad.Start; " ", Joypad.Select ] in
  let draw fb =
    for y = 0 to gb_h - 1 do
      let line = fb.(y) in
      for x = 0 to gb_w - 1 do
        let c = Int32.of_int (colour line.(x)) in
        let o = x * scale in
        Bigarray.Array1.unsafe_set row.Gfx.pixels o c;
        Bigarray.Array1.unsafe_set row.Gfx.pixels (o + 1) c;
        Bigarray.Array1.unsafe_set row.Gfx.pixels (o + 2) c
      done;
      for k = 0 to scale - 1 do Gfx.blit row 0 0 screen 0 (y * scale + k) width 1 done
    done in
  (* one frame of the Game Boy: instructions until the screen is done *)
  (* frames of the Game Boy: instructions until a screen is done; only
     the last one drawn *)
  let rec frame ~show =
    match C.run_instruction gb with
    | Gpu.In_frame -> frame ~show
    | Gpu.Frame_ended fb -> if show then draw fb in
  (* the frames due: 60 a second since the start, the ticks being at the
     kernel's 10 ms (a tick of 1/60 s comes every 20 ms); 4 at most at
     once, so that a slow machine falls behind instead of stalling *)
  let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
  (* the sound: a stream, fed by a domain from a queue of chunks *)
  let stream = try Some (Sound.open_stream ()) with _ -> None in
  let chunks = Queue.create () and lock = Mutex.create () and ready = Condition.create () in
  let muted = ref false and too_slow = ref false in
  let windows = ref 0 and slow_windows = ref 0 in
  let audio_on () = stream <> None && not !muted && not !too_slow && not !paused in
  C.set_audio gb (audio_on ());
  (match stream with
   | Some s ->
     (* a thread, not a domain: a second domain must join every minor
        collection, and waking it each time slowed the game to 54 frames *)
     ignore (Thread.create (fun () ->
         try
           while true do
             let c = Mutex.protect lock (fun () ->
                 while Queue.is_empty chunks do Condition.wait ready lock done;
                 Queue.pop chunks) in
             Sound.write s c
           done
         with _ -> ()) ())
   | None -> ());
  let send c =
    if c <> "" then
      Mutex.protect lock (fun () ->
          Queue.push c chunks;
          (* 6 chunks: a tenth of a second behind at most *)
          while Queue.length chunks > 6 do ignore (Queue.pop chunks) done;
          Condition.signal ready) in
  Gui.run ~title:("Game Boy: " ^ Filename.basename rom) ~tick:(1. /. 60.) width height ()
    (fun ui () ->
       let now = Mynos.uptime () in
       List.iter (function
           | "\027" -> raise Gui.Quit
           | "p" | "P" ->
             paused := not !paused; start := now; done_frames := 0; C.set_audio gb (audio_on ())
           | "m" | "M" -> muted := not !muted; C.set_audio gb (audio_on ())
           | _ -> ()) ui.Gui.keys;
       (* the buttons of the keys held: pressed, and released, as they change *)
       let now_down = List.sort_uniq compare
           (List.filter_map (fun k -> List.assoc_opt k keys) ui.Gui.held) in
       List.iter (fun b -> if not (List.mem b !down) then C.press gb b) now_down;
       List.iter (fun b -> if not (List.mem b now_down) then C.release gb b) !down;
       down := now_down;
       if ui.Gui.tick && not !paused then begin
         let due = int_of_float ((now -. !start) *. 60.) - !done_frames in
         let n = max 1 (min 4 due) in
         if due > 4 then begin start := now; done_frames := 0 end;
         for i = 1 to n do frame ~show:(i = n); incr done_frames done;
         send (C.audio_samples gb);
         frames := !frames + n;
         if now -. !since >= 2. then begin
           fps := float !frames /. (now -. !since); frames := 0; since := now;
           (* the first two seconds are the start's: not counted; then two
              slow ones in a row turn the sound off *)
           incr windows;
           if !windows > 1 && !fps < 50. then incr slow_windows else slow_windows := 0;
           if !slow_windows >= 2 && not !too_slow then begin
             too_slow := true; C.set_audio gb false end
         end
       end;
       Gfx.blit screen 0 0 ui.Gui.g 0 0 width (gb_h * scale);
       Gfx.fill ui.Gui.g 0 (gb_h * scale) width 24 0x2B2F33;
       ignore (Gfx.text ui.Gui.g 6 (gb_h * scale + 4)
                 (Printf.sprintf "%s%.0f fps%s   arrows X Z Enter Space; P pause, M sound, Esc"
                    (if !paused then "paused  " else "") !fps
                    (if stream = None then "" else if !too_slow then ", no sound (slow)"
                     else if !muted then ", sound off" else ", sound")) 0xB0BEC5);
       ());
  Option.iter (fun s -> try Sound.stop s with _ -> ()) stream;
  exit 0
