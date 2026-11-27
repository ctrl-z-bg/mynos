(* camlboy: a Game Boy, in a window, and the service camlboy<pid> (emu/1,
   doc/decisions/retro-emulators.md). The emulator is CAMLBOY, by
   linoscope (MIT, third_party/camlboy); this is its face in MyNOS.

     camlboy ROM.gb
     camlboy --headless ROM.gb     no window: the machine and its service

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
   KVM, v86) the sound would stutter: it goes off by itself.

   The service: emu/1's requests, done between frames (Emu_service).
   A Game Boy has no text screen, no disassembler here yet, no
   watchpoints, no saved states: those requests answer an error. *)

let gb_w = 160 and gb_h = 144 and scale = 3
let width = gb_w * scale and height = gb_h * scale + 24

let colour = function
  | `White -> 0xE5FBF4 | `Light_gray -> 0x97AEB8 | `Dark_gray -> 0x61687D | `Black -> 0x221E31

let key_names = "A B START SELECT UP DOWN LEFT RIGHT"

let key_of_name s =
  match String.uppercase_ascii s with
  | "A" -> Joypad.A | "B" -> Joypad.B | "START" -> Joypad.Start | "SELECT" -> Joypad.Select
  | "UP" -> Joypad.Up | "DOWN" -> Joypad.Down | "LEFT" -> Joypad.Left | "RIGHT" -> Joypad.Right
  | _ -> failwith ("no key " ^ s ^ " (" ^ key_names ^ ")")

(* emu/1's notation: groups of names joined by +, held 2 frames or :n *)
let parse_keys s =
  List.map (fun w ->
      let keys, n = match String.index_opt w ':' with
        | Some i -> String.sub w 0 i, int_of_string (String.sub w (i + 1) (String.length w - i - 1))
        | None -> w, 2 in
      List.map key_of_name (String.split_on_char '+' keys), max 1 n)
    (List.filter (( <> ) "") (String.split_on_char ' ' s))

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let headless = List.mem "--headless" args in
  let rom = match List.filter (( <> ) "--headless") args with
    | r :: _ -> r
    | [] -> prerr_endline "usage: camlboy [--headless] ROM.gb"; exit 2 in
  let rom_bytes = match Read_rom_file.f rom with
    | b -> b
    | exception Sys_error m -> prerr_endline ("camlboy: " ^ m); exit 1 in
  let cartridge = Detect_cartridge.f ~rom_bytes in
  let module C = Camlboy.Make (val cartridge) in
  let gb = ref (C.create_with_rom ~rom_bytes ~print_serial_port:false) in
  let svc = Emu_service.start "camlboy" in
  let name = Emu_service.name svc in
  let last_fb = ref None in                  (* the last frame, for screenshots *)
  let frame_no = ref 0 in
  let paused = ref false and fps = ref 0. in
  (* breakpoints (on the PC only), the waits, the keys typed *)
  let breaks = ref [] and next_id = ref 1 in
  let exec_map = Bytes.make 0x10000 '\000' in
  let rebuild () =
    Bytes.fill exec_map 0 0x10000 '\000';
    List.iter (fun (b : Emu_proto.breakpoint) ->
        for a = b.addr to b.addr + max 1 b.len - 1 do Bytes.set exec_map (a land 0xFFFF) '\001' done)
      !breaks in
  let waiters = ref [] and key_waiters = ref [] in
  let last_stop = ref Emu_proto.Running in
  let keys_queue = Queue.create () and key_now = ref None and key_gap = ref 0 in
  let queued = ref [] in                     (* the buttons emu/1 holds now *)
  let window_down = ref [] and down = ref [] in
  let keys_pending () = !key_now <> None || !key_gap > 0 || not (Queue.is_empty keys_queue) in
  let keys_frame () =
    match !key_now with
    | Some (keys, n) ->
      if n <= 1 then begin
        queued := []; key_now := None;
        key_gap := (match Queue.peek_opt keys_queue with
            | Some (next, _) when List.exists (fun k -> List.mem k keys) next -> 6 | _ -> 1)
      end else key_now := Some (keys, n - 1)
    | None ->
      if !key_gap > 0 then decr key_gap
      else if not (Queue.is_empty keys_queue) then begin
        let keys, n = Queue.pop keys_queue in
        queued := keys; key_now := Some (keys, n)
      end in
  (* the buttons down: the window's and emu/1's, pressed and released as
     they change *)
  let apply_buttons () =
    let now_down = List.sort_uniq compare (!window_down @ !queued) in
    List.iter (fun b -> if not (List.mem b !down) then C.press !gb b) now_down;
    List.iter (fun b -> if not (List.mem b now_down) then C.release !gb b) !down;
    down := now_down in
  let stopped stop =
    paused := true;
    last_stop := stop;
    List.iter (fun ch -> Emu_service.answer ch (Emu_proto.Wait 0.) stop) (List.map fst !waiters);
    waiters := [];
    List.iter (fun ch -> Emu_service.fail ch "paused") !key_waiters;
    key_waiters := [] in
  let pause () = if not !paused then stopped (Emu_proto.Paused (C.pc !gb)) in
  (* a frame: instructions until the screen is done; with breakpoints,
     the PC looked at before each one (the first excepted: resuming from
     a breakpoint); false if one stopped it *)
  let frame () =
    let rec go first =
      if !breaks <> [] && not first && Bytes.unsafe_get exec_map (C.pc !gb) <> '\000' then begin
        let pc = C.pc !gb in
        let id = match List.find_opt (fun (b : Emu_proto.breakpoint) ->
            pc >= b.addr && pc < b.addr + max 1 b.len) !breaks with Some b -> b.id | None -> -1 in
        Tracer.mark (Printf.sprintf "%s: breakpoint %d at %04X" name id pc);
        stopped (Emu_proto.Hit (id, pc, pc));
        false
      end else
        match C.run_instruction !gb with
        | Gpu.In_frame -> go false
        | Gpu.Frame_ended fb -> last_fb := Some fb; incr frame_no; keys_frame (); apply_buttons (); true in
    go true in
  let pixels () =
    match !last_fb with
    | None -> Array.make (gb_w * gb_h) 0
    | Some fb -> Array.init (gb_w * gb_h) (fun i -> colour fb.(i / gb_w).(i mod gb_w)) in
  let do_job (Emu_service.Job (ch, r)) =
    let open Emu_proto in
    let ok v = Emu_service.answer ch r v in
    try
      match r with
      | Info -> ok { machine = "Game Boy (DMG)"; rom = Filename.basename rom;
                     loaded = Filename.basename rom; frame = !frame_no; fps = !fps;
                     paused = !paused; key_names }
      | Regs -> ok (C.registers !gb)
      | Peek (space, a, n) ->
        if n < 0 || n > 4096 then failwith "peek: len 0 to 4096";
        let base, size = match space with
          | Cpu -> 0, 0x10000 | Rom -> 0, 0x8000 | Vram -> 0x8000, 0x2000 | Ram -> 0xC000, 0x2000 in
        ok (List.init n (fun i ->
            if a + i < 0 || a + i >= size then failwith "peek: out of the space"
            else C.peek !gb (base + a + i)))
      | Disasm _ -> failwith "camlboy: no disassembler for the Game Boy's CPU (yet)"
      | Screen_text -> failwith "a Game Boy's screen has no text: screenshot shows it"
      | Screenshot ->
        let path = Printf.sprintf "/tmp/%s-%d.png" name !frame_no in
        Png.save path ~width:gb_w ~height:gb_h (pixels ());
        ok path
      | Pause -> pause (); ok (Paused (C.pc !gb))
      | Resume -> paused := false; ok ()
      | Step n ->
        pause ();
        for _ = 1 to max 0 n do
          match C.run_instruction !gb with
          | Gpu.In_frame -> ()
          | Gpu.Frame_ended fb -> last_fb := Some fb; incr frame_no
        done;
        ok (Paused (C.pc !gb))
      | Frames n ->
        pause ();
        let rec go k = if k = 0 then Paused (C.pc !gb) else if frame () then go (k - 1) else !last_stop in
        ok (go (max 0 n))
      | Break (Exec, a, len) ->
        let id = !next_id in
        incr next_id;
        breaks := !breaks @ [ { id; kind = Exec; addr = a land 0xFFFF; len = max 1 len } ];
        rebuild ();
        ok id
      | Break _ -> failwith "camlboy: no watchpoints (yet): only exec breakpoints"
      | Unbreak id ->
        if not (List.exists (fun (b : breakpoint) -> b.id = id) !breaks) then
          failwith (Printf.sprintf "unbreak: no breakpoint %d" id);
        breaks := List.filter (fun (b : breakpoint) -> b.id <> id) !breaks;
        rebuild ();
        ok ()
      | Breaks -> ok !breaks
      | Wait secs ->
        if !paused then ok !last_stop
        else waiters := !waiters @ [ (ch, Mynos.uptime () +. secs) ]
      | Keys k ->
        if !paused then failwith "paused";
        List.iter (fun g -> Queue.push g keys_queue) (parse_keys k);
        key_waiters := !key_waiters @ [ ch ]
      | Poke (space, a, bytes) ->
        let base = match space with
          | Cpu -> 0 | Vram -> 0x8000 | Ram -> 0xC000 | Rom -> failwith "the rom is read only" in
        List.iteri (fun i v -> C.poke !gb (base + a + i) v) bytes;
        ok ()
      | Load _ -> failwith "camlboy: start camlboy with another ROM"
      | Save_state _ | Load_state _ -> failwith "camlboy: no saved states (yet)"
      | Reset ->
        gb := C.create_with_rom ~rom_bytes ~print_serial_port:false;
        down := []; apply_buttons ();
        ok ()
    with
    | Failure m | Sys_error m | Invalid_argument m -> Emu_service.fail ch m
    | e -> Emu_service.fail ch (Printexc.to_string e) in
  let serve () =
    if Emu_service.pending svc then List.iter do_job (Emu_service.take svc);
    if !waiters <> [] then begin
      let now = Mynos.uptime () in
      let due, rest = List.partition (fun (_, d) -> d <= now) !waiters in
      List.iter (fun (ch, _) -> Emu_service.answer ch (Emu_proto.Wait 0.) Emu_proto.Running) due;
      waiters := rest
    end;
    if !key_waiters <> [] && not (keys_pending ()) then begin
      List.iter (fun ch -> Emu_service.answer ch (Emu_proto.Keys "") ()) !key_waiters;
      key_waiters := []
    end in
  Tracer.mark (Printf.sprintf "%s: loaded %s" name (Filename.basename rom));
  if headless then begin
    Printf.printf "camlboy: %s, no window\n%!" name;
    let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
    let frames = ref 0 and since = ref !start in
    while true do
      serve ();
      let now = Mynos.uptime () in
      if !paused then begin start := now; done_frames := 0; Thread.delay 0.02 end
      else begin
        let due = int_of_float ((now -. !start) *. 60.) - !done_frames in
        if due > 4 then begin start := now; done_frames := 0 end;
        if due >= 1 then begin ignore (frame ()); incr done_frames; incr frames end
        else Thread.delay 0.005
      end;
      if now -. !since >= 2. then begin fps := float !frames /. (now -. !since); frames := 0; since := now end
    done
  end;
  let screen = Gfx.create width (gb_h * scale) in
  let row = Gfx.create width 1 in
  let frames = ref 0 and since = ref (Mynos.uptime ()) in
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
  (* the frames due: 60 a second since the start, the ticks being at the
     kernel's 10 ms (a tick of 1/60 s comes every 20 ms); 4 at most at
     once, so that a slow machine falls behind instead of stalling *)
  let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
  (* the sound: a stream, fed by a thread from a queue of chunks *)
  let stream = try Some (Sound.open_stream ()) with _ -> None in
  let chunks = Queue.create () and lock = Mutex.create () and ready = Condition.create () in
  let muted = ref false and too_slow = ref false in
  let windows = ref 0 and slow_windows = ref 0 in
  let audio_on () = stream <> None && not !muted && not !too_slow && not !paused in
  C.set_audio !gb (audio_on ());
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
  let shown = ref (-1) in
  Gui.run ~title:("Game Boy: " ^ Filename.basename rom) ~tick:(1. /. 60.) width height ()
    (fun ui () ->
       let now = Mynos.uptime () in
       List.iter (function
           | "\027" -> raise Gui.Quit
           | "p" | "P" ->
             if !paused then paused := false else pause ();
             start := now; done_frames := 0; C.set_audio !gb (audio_on ())
           | "m" | "M" -> muted := not !muted; C.set_audio !gb (audio_on ())
           | _ -> ()) ui.Gui.keys;
       window_down := List.sort_uniq compare (List.filter_map (fun k -> List.assoc_opt k keys) ui.Gui.held);
       apply_buttons ();
       if ui.Gui.tick then begin
         serve ();
         if not !paused then begin
           let due = int_of_float ((now -. !start) *. 60.) - !done_frames in
           let n = max 1 (min 4 due) in
           if due > 4 then begin start := now; done_frames := 0 end;
           let i = ref 0 in
           while !i < n && not !paused do
             if frame () then incr done_frames;
             incr i
           done;
           frames := !frames + !i;
           send (C.audio_samples !gb);
           if !paused then C.set_audio !gb (audio_on ())
         end;
         if now -. !since >= 2. then begin
           fps := float !frames /. (now -. !since); frames := 0; since := now;
           (* the first two seconds are the start's: not counted; then two
              slow ones in a row turn the sound off *)
           incr windows;
           if !windows > 1 && not !paused && !fps < 50. then incr slow_windows else slow_windows := 0;
           if !slow_windows >= 2 && not !too_slow then begin
             too_slow := true; C.set_audio !gb false end
         end;
         (match !last_fb with
          | Some fb when !frame_no <> !shown -> draw fb; shown := !frame_no
          | _ -> ())
       end;
       Gfx.blit screen 0 0 ui.Gui.g 0 0 width (gb_h * scale);
       Gfx.fill ui.Gui.g 0 (gb_h * scale) width 24 0x2B2F33;
       ignore (Gfx.text ui.Gui.g 6 (gb_h * scale + 4)
                 (Printf.sprintf "%s%.0f fps%s  %s  arrows X Z Enter Space; P, M, Esc"
                    (if !paused then "paused  " else "") !fps
                    (if stream = None then "" else if !too_slow then ", no sound (slow)"
                     else if !muted then ", sound off" else ", sound") name) 0xB0BEC5);
       ());
  Option.iter (fun s -> try Sound.stop s with _ -> ()) stream;
  exit 0
