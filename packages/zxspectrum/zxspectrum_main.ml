(* zxspectrum: a ZX Spectrum 48K in a window, and the service zx<pid>
   (emu/1) that lets anyone else look at it and drive it
   (doc/decisions/retro-emulators.md).

     zxspectrum [FILE]               a window; FILE a .tap, .sna or .z80
     zxspectrum --headless [FILE]    no window: the machine and its service
     zxspectrum --bench N [--no-service] [FILE]
                                     N frames as fast as it can, the screen
                                     made each frame as for a window: frames
                                     a second (the package's MYNOS.md)

   Keys: letters, digits, Enter, Space; Shift and a letter: CAPS SHIFT
   and it, Ctrl and a letter: SYMBOL SHIFT and it; the punctuation the
   Spectrum has (the double quote, the colon, the comma, the signs...)
   as SYMBOL SHIFT and its key; Backspace: DELETE (CAPS SHIFT and 0); the arrows:
   CAPS SHIFT and 5-8. Page Up pauses, Page Down turns the sound on and
   off, Escape quits (P and M are the Spectrum's).

   The service's requests are done here, between frames (Emu_service). *)

let scale = 2
let width = Ula.width * scale and height = Ula.height * scale + 24

let rom_path () =
  let beside = Filename.concat (Filename.dirname Sys.argv.(0)) "48.rom" in
  if Sys.file_exists beside then beside else "/disk/pkg/zxspectrum/48.rom"

let read_file f =
  let ic = open_in_bin f in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

(* ---- a window's key: the Spectrum's keys it holds ---- *)

let ss k = Some [ Keyboard.Symbol_shift; k ]
let cs k = Some [ Keyboard.Caps_shift; k ]
let symbols = [
  "\"", 'P'; ":", 'Z'; ";", 'O'; ",", 'N'; ".", 'M'; "+", 'K'; "-", 'J'; "*", 'B'; "/", 'V';
  "=", 'L'; "<", 'R'; ">", 'T'; "?", 'C'; "^", 'H'; "'", '7'; "!", '1'; "@", '2'; "#", '3';
  "$", '4'; "%", '5'; "&", '6'; "(", '8'; ")", '9'; "_", '0' ]

let keys_of s =
  let open Keyboard in
  match s with
  | "\r" | "\n" -> Some [ Enter ]
  | " " -> Some [ Space ]
  | "\127" | "\b" -> cs (Digit 0)
  | "\027[D" -> cs (Digit 5) | "\027[B" -> cs (Digit 6)
  | "\027[A" -> cs (Digit 7) | "\027[C" -> cs (Digit 8)
  | _ when String.length s = 1 ->
    let c = s.[0] in
    if c >= 'a' && c <= 'z' then Some [ Letter (Char.uppercase_ascii c) ]
    else if c >= 'A' && c <= 'Z' then cs (Letter c)
    else if c >= '0' && c <= '9' then Some [ Digit (Char.code c - 48) ]
    else if c >= '\001' && c <= '\026' then ss (Letter (Char.chr (Char.code c + 64)))
    else (match List.assoc_opt s symbols with
        | Some k when k >= '0' && k <= '9' -> ss (Digit (Char.code k - 48))
        | Some k -> ss (Letter k)
        | None -> None)
  | _ -> None

(* ---- the emulator: the machine, its service, its breakpoints ---- *)

type st = {
  m : Spectrum.t;
  svc : Emu_service.t;
  mutable paused : bool;
  mutable loaded : string;
  mutable fps : float;
  mutable breaks : Emu_proto.breakpoint list;
  mutable next_id : int;
  exec_map : Bytes.t;                   (* 64 KB: an Exec breakpoint's addresses *)
  watch_map : Bytes.t;                  (* bit 0 read, bit 1 write *)
  mutable waiters : (Emu_service.reply_to * float) list;   (* wait: its deadline *)
  mutable key_waiters : Emu_service.reply_to list;
  mutable last_stop : Emu_proto.stop;
}

let pc st = Z80.get (Spectrum.z80 st.m) Z80.PC

let rebuild st =
  Bytes.fill st.exec_map 0 0x10000 '\000';
  Bytes.fill st.watch_map 0 0x10000 '\000';
  let watches = ref false in
  List.iter (fun (b : Emu_proto.breakpoint) ->
      for a = b.addr to b.addr + max 1 b.len - 1 do
        let a = a land 0xFFFF in
        match b.kind with
        | Emu_proto.Exec -> Bytes.set st.exec_map a '\001'
        | Emu_proto.Read ->
          watches := true;
          Bytes.set st.watch_map a (Char.chr (Char.code (Bytes.get st.watch_map a) lor 1))
        | Emu_proto.Write ->
          watches := true;
          Bytes.set st.watch_map a (Char.chr (Char.code (Bytes.get st.watch_map a) lor 2))
      done) st.breaks;
  Spectrum.set_watch st.m
    (if !watches then
       Some (fun a write ->
           Char.code (Bytes.unsafe_get st.watch_map a) land (if write then 2 else 1) <> 0)
     else None)

let which st kind a =
  match List.find_opt (fun (b : Emu_proto.breakpoint) ->
      b.kind = kind && a >= b.addr && a < b.addr + max 1 b.len) st.breaks with
  | Some b -> b.id | None -> -1

(* the machine stopped (a breakpoint, a pause): the waits answered *)
let stopped st stop =
  st.paused <- true;
  st.last_stop <- stop;
  List.iter (fun (ch, _) -> Emu_service.answer ch (Emu_proto.Wait 0.) stop) st.waiters;
  st.waiters <- [];
  List.iter (fun ch -> Emu_service.fail ch "paused") st.key_waiters;
  st.key_waiters <- []

let hit st (r : Spectrum.stop) =
  match r with
  | Spectrum.Frame_done -> None
  | Spectrum.Breakpoint pc ->
    let id = which st Emu_proto.Exec pc in
    Tracer.mark (Printf.sprintf "%s: breakpoint %d at %04X" (Emu_service.name st.svc) id pc);
    Some (Emu_proto.Hit (id, pc, pc))
  | Spectrum.Watch (pc, a) ->
    let id = match which st Emu_proto.Write a with -1 -> which st Emu_proto.Read a | i -> i in
    Tracer.mark (Printf.sprintf "%s: watchpoint %d at %04X (address %04X)" (Emu_service.name st.svc) id pc a);
    Some (Emu_proto.Hit (id, pc, a))

(* a frame: the fast loop without breakpoints, the checked one with *)
let run_frame st =
  let r =
    if st.breaks = [] then Spectrum.run_fast st.m
    else Spectrum.run_checked st.m ~check:(fun pc -> Bytes.unsafe_get st.exec_map pc <> '\000') in
  match hit st r with
  | Some stop -> stopped st stop; false
  | None -> true

(* ---- emu/1's requests ---- *)

let info st : Emu_proto.info =
  { machine = "ZX Spectrum 48K"; rom = "Sinclair 48K BASIC (Amstrad)"; loaded = st.loaded;
    frame = Spectrum.frame st.m; fps = st.fps; paused = st.paused; key_names = Keyboard.names }

let pause st = if not st.paused then stopped st (Emu_proto.Paused (pc st))

let do_job st (Emu_service.Job (ch, r)) =
  let open Emu_proto in
  let ok v = Emu_service.answer ch r v in
  try
    match r with
    | Info -> ok (info st)
    | Regs -> ok (Z80.registers (Spectrum.z80 st.m))
    | Peek (space, a, n) ->
      if n < 0 || n > 4096 then failwith "peek: len 0 to 4096";
      ok (List.init n (fun i -> Spectrum.peek st.m space (a + i)))
    | Disasm (a, n) ->
      ok (Z80_disasm.lines (fun a -> Spectrum.peek st.m Cpu a) a (max 0 (min n 1000)))
    | Screen_text -> ok (Spectrum.screen_text st.m)
    | Screenshot ->
      let path = Printf.sprintf "/tmp/%s-%d.png" (Emu_service.name st.svc) (Spectrum.frame st.m) in
      Png.save path ~width:Ula.width ~height:Ula.height (Spectrum.screen st.m);
      ok path
    | Pause -> pause st; ok (Paused (pc st))
    | Resume -> st.paused <- false; ok ()
    | Step n ->
      pause st;
      let rec go k =
        if k = 0 then Paused (pc st)
        else match hit st (Spectrum.step st.m) with
          | Some stop -> stop
          | None -> go (k - 1) in
      ok (go (max 0 n))
    | Frames n ->
      pause st;
      let rec go k =
        if k = 0 then Paused (pc st)
        else if run_frame st then go (k - 1)
        else st.last_stop in
      ok (go (max 0 n))
    | Break (kind, a, len) ->
      if len < 0 then failwith "break: len >= 0";
      let id = st.next_id in
      st.next_id <- id + 1;
      st.breaks <- st.breaks @ [ { id; kind; addr = a land 0xFFFF; len = max 1 len } ];
      rebuild st;
      ok id
    | Unbreak id ->
      if not (List.exists (fun (b : breakpoint) -> b.id = id) st.breaks) then
        failwith (Printf.sprintf "unbreak: no breakpoint %d" id);
      st.breaks <- List.filter (fun (b : breakpoint) -> b.id <> id) st.breaks;
      rebuild st;
      ok ()
    | Breaks -> ok st.breaks
    | Wait secs ->
      if st.paused then ok st.last_stop
      else st.waiters <- st.waiters @ [ (ch, Mynos.uptime () +. secs) ]
    | Keys k ->
      if st.paused then failwith "paused";
      Spectrum.queue_keys st.m (Keyboard.parse k);
      st.key_waiters <- st.key_waiters @ [ ch ]
    | Poke (space, a, bytes) -> List.iteri (fun i v -> Spectrum.poke st.m space (a + i) v) bytes; ok ()
    | Load f ->
      let what = Spectrum.load st.m f in
      st.loaded <- what;
      Tracer.mark (Printf.sprintf "%s: loaded %s" (Emu_service.name st.svc) what);
      ok what
    | Save_state f -> Spectrum.save_state st.m f; ok ()
    | Load_state f ->
      let what = Spectrum.load st.m f in
      Tracer.mark (Printf.sprintf "%s: state %s" (Emu_service.name st.svc) what);
      ok ()
    | Reset -> Spectrum.reset st.m; st.loaded <- ""; ok ()
  with
  | Failure m | Sys_error m | Invalid_argument m -> Emu_service.fail ch m
  | e -> Emu_service.fail ch (Printexc.to_string e)

(* between frames: the requests, the waits that ran out, the keys typed *)
let serve st =
  if Emu_service.pending st.svc then List.iter (do_job st) (Emu_service.take st.svc);
  if st.waiters <> [] then begin
    let now = Mynos.uptime () in
    let due, rest = List.partition (fun (_, d) -> d <= now) st.waiters in
    List.iter (fun (ch, _) -> Emu_service.answer ch (Emu_proto.Wait 0.) Emu_proto.Running) due;
    st.waiters <- rest
  end;
  if st.key_waiters <> [] && not (Spectrum.keys_pending st.m) then begin
    List.iter (fun ch -> Emu_service.answer ch (Emu_proto.Keys "") ()) st.key_waiters;
    st.key_waiters <- []
  end

let make ?(service = true) file =
  let m = Spectrum.create ~rom:(read_file (rom_path ())) in
  let st = { m; svc = (if service then Emu_service.start "zx" else Emu_service.none ());
             paused = false; loaded = ""; fps = 0.;
             breaks = []; next_id = 1; exec_map = Bytes.make 0x10000 '\000';
             watch_map = Bytes.make 0x10000 '\000'; waiters = []; key_waiters = [];
             last_stop = Emu_proto.Running } in
  (match file with
   | Some f -> st.loaded <- Spectrum.load m f;
     Tracer.mark (Printf.sprintf "%s: loaded %s" (Emu_service.name st.svc) st.loaded)
   | None -> ());
  st

(* ---- without a window: 50 frames a second by the clock ---- *)

let headless file =
  let st = make file in
  Printf.printf "zxspectrum: %s, no window\n%!" (Emu_service.name st.svc);
  let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
  let frames = ref 0 and since = ref !start in
  while true do
    serve st;
    let now = Mynos.uptime () in
    if st.paused then begin start := now; done_frames := 0; Thread.delay 0.02 end
    else begin
      let due = int_of_float ((now -. !start) *. 50.) - !done_frames in
      if due > 4 then begin start := now; done_frames := 0 end;
      if due >= 1 then begin
        ignore (run_frame st); incr done_frames; incr frames
      end else Thread.delay 0.005
    end;
    if now -. !since >= 2. then begin
      st.fps <- float !frames /. (now -. !since); frames := 0; since := now
    end
  done

(* ---- a benchmark: the machine and its picture, no window ---- *)

let bench n service file =
  let st = make ~service file in
  for _ = 1 to 150 do ignore (run_frame st) done;      (* the ROM, the tape *)
  let t0 = Mynos.uptime () in
  for _ = 1 to n do
    serve st;
    ignore (run_frame st);
    ignore (Spectrum.screen st.m)
  done;
  let dt = Mynos.uptime () -. t0 in
  Printf.printf "zxspectrum: %d frames in %.2f s: %.0f frames a second (service %s)\n%!"
    n dt (float n /. dt) (if service then "on" else "off");
  exit 0

(* ---- in a window ---- *)

let windowed file =
  let st = make file in
  let screen = Gfx.create width (Ula.height * scale) in
  let row = Gfx.create width 1 in
  let down = ref [] in
  let draw () =
    let px = Spectrum.screen st.m and changed = Spectrum.changed st.m in
    for y = 0 to Ula.height - 1 do
      if changed.(y) then begin
        changed.(y) <- false;
        let base = y * Ula.width in
        for x = 0 to Ula.width - 1 do
          let c = Int32.of_int (Array.unsafe_get px (base + x)) in
          Bigarray.Array1.unsafe_set row.Gfx.pixels (2 * x) c;
          Bigarray.Array1.unsafe_set row.Gfx.pixels (2 * x + 1) c
        done;
        Gfx.blit row 0 0 screen 0 (2 * y) width 1;
        Gfx.blit row 0 0 screen 0 (2 * y + 1) width 1
      end
    done in
  (* the sound, as camlboy's: a thread writes the chunks a queue holds *)
  let stream = try Some (Sound.open_stream ()) with _ -> None in
  let chunks = Queue.create () and lock = Mutex.create () and ready = Condition.create () in
  let muted = ref true and too_slow = ref false in
  let windows = ref 0 and slow_windows = ref 0 in
  let audio () = Spectrum.set_audio st.m (stream <> None && not !muted && not !too_slow && not st.paused) in
  audio ();
  (match stream with
   | Some s ->
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
          while Queue.length chunks > 5 do ignore (Queue.pop chunks) done;
          Condition.signal ready) in
  let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
  let frames = ref 0 and since = ref (Mynos.uptime ()) in
  let title = "ZX Spectrum" ^ (match file with Some f -> ": " ^ Filename.basename f | None -> "") in
  Gui.run ~title ~tick:(1. /. 50.) width height ()
    (fun ui () ->
       let now = Mynos.uptime () in
       List.iter (function
           | "\027" -> raise Gui.Quit
           | "\027[5~" ->
             if st.paused then st.paused <- false else pause st;
             start := now; done_frames := 0; audio ()
           | "\027[6~" ->
             (* on again, even if it went off by itself: tried anew *)
             if !too_slow then begin too_slow := false; slow_windows := 0; muted := false end
             else muted := not !muted;
             audio ()
           | _ -> ()) ui.Gui.keys;
       (* the keys held: the Spectrum's down and up as they change *)
       let now_down = List.sort_uniq compare
           (List.concat (List.filter_map keys_of ui.Gui.held)) in
       List.iter (fun k -> if not (List.mem k !down) then Spectrum.press st.m k true) now_down;
       List.iter (fun k -> if not (List.mem k now_down) then Spectrum.press st.m k false) !down;
       down := now_down;
       if ui.Gui.tick then begin
         serve st;
         if not st.paused then begin
           let due = int_of_float ((now -. !start) *. 50.) - !done_frames in
           let n = max 1 (min 4 due) in
           if due > 4 then begin start := now; done_frames := 0 end;
           let i = ref 0 in
           while !i < n && not st.paused do
             if run_frame st then begin incr done_frames; incr frames; send (Spectrum.audio_samples st.m) end;
             incr i
           done;
           if st.paused then audio ()
         end;
         if now -. !since >= 2. then begin
           st.fps <- float !frames /. (now -. !since); frames := 0; since := now;
           incr windows;
           (* below 45 (the Spectrum's 50 measured a little under it is
              not slow: 50 there turned the sound off at 49.8) *)
           if !windows > 1 && not st.paused && st.fps < 45. then incr slow_windows else slow_windows := 0;
           if !slow_windows >= 2 && not !too_slow then begin too_slow := true; audio () end
         end;
         draw ()
       end;
       Gfx.blit screen 0 0 ui.Gui.g 0 0 width (Ula.height * scale);
       Gfx.fill ui.Gui.g 0 (Ula.height * scale) width 24 0x2B2F33;
       ignore (Gfx.text ui.Gui.g 6 (Ula.height * scale + 4)
                 (Printf.sprintf "%s%.0f fps%s   %s   PgUp pause, PgDn sound, Esc"
                    (if st.paused then "paused  " else "") st.fps
                    (if stream = None then "" else if !too_slow then ", no sound (slow)"
                     else if !muted then ", sound off" else ", sound")
                    (Emu_service.name st.svc)) 0xB0BEC5));
  Option.iter (fun s -> try Sound.stop s with _ -> ()) stream;
  exit 0

let () =
  match List.tl (Array.to_list Sys.argv) with
  | "--headless" :: rest -> headless (match rest with f :: _ -> Some f | [] -> None)
  | "--bench" :: n :: rest ->
    let service = not (List.mem "--no-service" rest) in
    bench (int_of_string n) service
      (match List.filter (( <> ) "--no-service") rest with f :: _ -> Some f | [] -> None)
  | f :: _ -> windowed (Some f)
  | [] -> windowed None
