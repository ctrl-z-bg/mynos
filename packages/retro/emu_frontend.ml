(* An emulated machine's window, service and command line
   (emu_frontend.mli): zxspectrum_main.ml's, made generic. The service's
   requests are done here, between frames (Emu_service). *)

type stop = Frame_done | Breakpoint of int | Watch of int * int

module type MACHINE = sig
  type t
  type key
  val program : string
  val service : string
  val title : string
  val hz : float
  val width : int
  val height : int
  val game_exts : string list
  val create : unit -> t
  val machine : t -> string
  val rom_name : t -> string
  val z80 : t -> Z80.t
  val frame : t -> int
  val run_fast : t -> stop
  val run_checked : t -> check:(int -> bool) -> stop
  val step : t -> stop
  val set_watch : t -> (int -> bool -> bool) option -> unit
  val press : t -> key -> bool -> unit
  val keys_of : string -> key list option
  val queue_keys : t -> string -> unit
  val keys_pending : t -> bool
  val key_names : string
  val peek : t -> Emu_proto.space -> int -> int
  val poke : t -> Emu_proto.space -> int -> int -> unit
  val screen : t -> int array
  val changed : t -> bool array
  val screen_text : t -> string
  val set_audio : t -> bool -> unit
  val audio_samples : t -> string
  val load : t -> string -> string
  val save_state : t -> string -> unit
  val reset : t -> unit
end

module Make (M : MACHINE) = struct

  (* ---- a game of the package's, by its name ---- *)

  let games_dir () =
    let beside = Filename.concat (Filename.dirname Sys.argv.(0)) "games" in
    if Sys.file_exists beside then beside else "/disk/pkg/" ^ M.program ^ "/games"

  let games () =
    match Sys.readdir (games_dir ()) with
    | names ->
      List.sort compare (List.filter_map (fun n ->
          if List.exists (Filename.check_suffix n) M.game_exts
          then Some (Filename.remove_extension n) else None) (Array.to_list names))
    | exception Sys_error _ -> []

  let resolve f =
    if Sys.file_exists f then f
    else
      let candidates = List.map (fun e -> Filename.concat (games_dir ()) (f ^ e)) ("" :: M.game_exts) in
      match List.find_opt Sys.file_exists candidates with
      | Some g -> g
      | None ->
        Printf.eprintf "%s: %s: no such file, nor a game of the package's (%s)\n" M.program f
          (String.concat ", " (games ()));
        exit 2

  (* ---- the emulator: the machine, its service, its breakpoints ---- *)

  type st = {
    m : M.t;
    svc : Emu_service.t;
    mutable paused : bool;
    mutable loaded : string;
    mutable fps : float;
    mutable breaks : Emu_proto.breakpoint list;
    mutable next_id : int;
    exec_map : Bytes.t;
    watch_map : Bytes.t;                (* bit 0 read, bit 1 write *)
    mutable waiters : (Emu_service.reply_to * float) list;
    mutable key_waiters : Emu_service.reply_to list;
    mutable last_stop : Emu_proto.stop;
  }

  let pc st = Z80.get (M.z80 st.m) Z80.PC

  let rebuild st =
    Bytes.fill st.exec_map 0 0x10000 '\000';
    Bytes.fill st.watch_map 0 0x10000 '\000';
    let watches = ref false in
    List.iter (fun (b : Emu_proto.breakpoint) ->
        for a = b.addr to b.addr + max 1 b.len - 1 do
          let a = a land 0xFFFF in
          let mark bit =
            watches := true;
            Bytes.set st.watch_map a (Char.chr (Char.code (Bytes.get st.watch_map a) lor bit)) in
          match b.kind with
          | Emu_proto.Exec -> Bytes.set st.exec_map a '\001'
          | Emu_proto.Read -> mark 1
          | Emu_proto.Write -> mark 2
        done) st.breaks;
    M.set_watch st.m
      (if !watches then
         Some (fun a write ->
             Char.code (Bytes.unsafe_get st.watch_map a) land (if write then 2 else 1) <> 0)
       else None)

  let which st kind a =
    match List.find_opt (fun (b : Emu_proto.breakpoint) ->
        b.kind = kind && a >= b.addr && a < b.addr + max 1 b.len) st.breaks with
    | Some b -> b.id | None -> -1

  let stopped st stop =
    st.paused <- true;
    st.last_stop <- stop;
    List.iter (fun (ch, _) -> Emu_service.answer ch (Emu_proto.Wait 0.) stop) st.waiters;
    st.waiters <- [];
    List.iter (fun ch -> Emu_service.fail ch "paused") st.key_waiters;
    st.key_waiters <- []

  let hit st r =
    match r with
    | Frame_done -> None
    | Breakpoint pc ->
      let id = which st Emu_proto.Exec pc in
      Tracer.mark (Printf.sprintf "%s: breakpoint %d at %04X" (Emu_service.name st.svc) id pc);
      Some (Emu_proto.Hit (id, pc, pc))
    | Watch (pc, a) ->
      let id = match which st Emu_proto.Write a with -1 -> which st Emu_proto.Read a | i -> i in
      Tracer.mark (Printf.sprintf "%s: watchpoint %d at %04X (address %04X)" (Emu_service.name st.svc) id pc a);
      Some (Emu_proto.Hit (id, pc, a))

  let run_frame st =
    let r =
      if st.breaks = [] then M.run_fast st.m
      else M.run_checked st.m ~check:(fun pc -> Bytes.unsafe_get st.exec_map pc <> '\000') in
    match hit st r with
    | Some stop -> stopped st stop; false
    | None -> true

  (* ---- emu/1's requests ---- *)

  let info st : Emu_proto.info =
    { machine = M.machine st.m; rom = M.rom_name st.m; loaded = st.loaded;
      frame = M.frame st.m; fps = st.fps; paused = st.paused; key_names = M.key_names }

  let pause st = if not st.paused then stopped st (Emu_proto.Paused (pc st))

  let do_job st (Emu_service.Job (ch, r)) =
    let open Emu_proto in
    let ok v = Emu_service.answer ch r v in
    try
      match r with
      | Info -> ok (info st)
      | Regs -> ok (Z80.registers (M.z80 st.m))
      | Peek (space, a, n) ->
        if n < 0 || n > 4096 then failwith "peek: len 0 to 4096";
        ok (List.init n (fun i -> M.peek st.m space (a + i)))
      | Disasm (a, n) ->
        ok (Z80_disasm.lines (fun a -> M.peek st.m Cpu a) a (max 0 (min n 1000)))
      | Screen_text -> ok (M.screen_text st.m)
      | Screenshot ->
        let path = Printf.sprintf "/tmp/%s-%d.png" (Emu_service.name st.svc) (M.frame st.m) in
        Png.save path ~width:M.width ~height:M.height (M.screen st.m);
        ok path
      | Pause -> pause st; ok (Paused (pc st))
      | Resume -> st.paused <- false; ok ()
      | Step n ->
        pause st;
        let rec go k =
          if k = 0 then Paused (pc st)
          else match hit st (M.step st.m) with
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
        M.queue_keys st.m k;
        st.key_waiters <- st.key_waiters @ [ ch ]
      | Poke (space, a, bytes) -> List.iteri (fun i v -> M.poke st.m space (a + i) v) bytes; ok ()
      | Load f ->
        let what = M.load st.m f in
        st.loaded <- what;
        Tracer.mark (Printf.sprintf "%s: loaded %s" (Emu_service.name st.svc) what);
        ok what
      | Save_state f -> M.save_state st.m f; ok ()
      | Load_state f ->
        let what = M.load st.m f in
        Tracer.mark (Printf.sprintf "%s: state %s" (Emu_service.name st.svc) what);
        ok ()
      | Reset -> M.reset st.m; ok ()
    with
    | Failure m | Sys_error m | Invalid_argument m -> Emu_service.fail ch m
    | e -> Emu_service.fail ch (Printexc.to_string e)

  let serve st =
    if Emu_service.pending st.svc then List.iter (do_job st) (Emu_service.take st.svc);
    if st.waiters <> [] then begin
      let now = Mynos.uptime () in
      let due, rest = List.partition (fun (_, d) -> d <= now) st.waiters in
      List.iter (fun (ch, _) -> Emu_service.answer ch (Emu_proto.Wait 0.) Emu_proto.Running) due;
      st.waiters <- rest
    end;
    if st.key_waiters <> [] && not (M.keys_pending st.m) then begin
      List.iter (fun ch -> Emu_service.answer ch (Emu_proto.Keys "") ()) st.key_waiters;
      st.key_waiters <- []
    end

  let make ?(service = true) file =
    let m = try M.create () with Failure e -> Printf.eprintf "%s: %s\n" M.program e; exit 1 in
    let st = { m; svc = (if service then Emu_service.start M.service else Emu_service.none ());
               paused = false; loaded = ""; fps = 0.;
               breaks = []; next_id = 1; exec_map = Bytes.make 0x10000 '\000';
               watch_map = Bytes.make 0x10000 '\000'; waiters = []; key_waiters = [];
               last_stop = Emu_proto.Running } in
    (match file with
     | Some f ->
       (try st.loaded <- M.load m (resolve f)
        with Failure e | Sys_error e -> Printf.eprintf "%s: %s\n" M.program e; exit 1);
       Tracer.mark (Printf.sprintf "%s: loaded %s" (Emu_service.name st.svc) st.loaded)
     | None -> ());
    st

  (* ---- without a window: by the clock ---- *)

  let headless file =
    let st = make file in
    Printf.printf "%s: %s, no window\n%!" M.program (Emu_service.name st.svc);
    let start = ref (Mynos.uptime ()) and done_frames = ref 0 in
    let frames = ref 0 and since = ref !start in
    while true do
      serve st;
      let now = Mynos.uptime () in
      if st.paused then begin start := now; done_frames := 0; Thread.delay 0.02 end
      else begin
        let due = int_of_float ((now -. !start) *. M.hz) - !done_frames in
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
    for _ = 1 to 150 do ignore (run_frame st) done;
    let t0 = Mynos.uptime () in
    for _ = 1 to n do
      serve st;
      ignore (run_frame st);
      ignore (M.screen st.m)
    done;
    let dt = Mynos.uptime () -. t0 in
    Printf.printf "%s: %d frames in %.2f s: %.0f frames a second (service %s)\n%!"
      M.program n dt (float n /. dt) (if service then "on" else "off");
    exit 0

  (* ---- in a window ---- *)

  let windowed file =
    let st = make file in
    let scale = 2 in
    let width = M.width * scale and pic_h = M.height * scale in
    let screen = Gfx.create width pic_h in
    let row = Gfx.create width 1 in
    let down = ref [] in
    let draw () =
      let px = M.screen st.m and changed = M.changed st.m in
      for y = 0 to M.height - 1 do
        if changed.(y) then begin
          changed.(y) <- false;
          let base = y * M.width in
          for x = 0 to M.width - 1 do
            let c = Int32.of_int (Array.unsafe_get px (base + x)) in
            Bigarray.Array1.unsafe_set row.Gfx.pixels (2 * x) c;
            Bigarray.Array1.unsafe_set row.Gfx.pixels (2 * x + 1) c
          done;
          Gfx.blit row 0 0 screen 0 (2 * y) width 1;
          Gfx.blit row 0 0 screen 0 (2 * y + 1) width 1
        end
      done in
    let stream = try Some (Sound.open_stream ()) with _ -> None in
    let chunks = Queue.create () and lock = Mutex.create () and ready = Condition.create () in
    let muted = ref true and too_slow = ref false in
    let windows = ref 0 and slow_windows = ref 0 in
    let audio () = M.set_audio st.m (stream <> None && not !muted && not !too_slow && not st.paused) in
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
    let title = M.title ^ (match file with Some f -> ": " ^ Filename.basename f | None -> "") in
    Gui.run ~title ~tick:(1. /. M.hz) width (pic_h + 24) ()
      (fun ui () ->
         let now = Mynos.uptime () in
         List.iter (function
             | "\027" -> raise Gui.Quit
             | "\027[5~" ->
               if st.paused then st.paused <- false else pause st;
               start := now; done_frames := 0; audio ()
             | "\027[6~" ->
               if !too_slow then begin too_slow := false; slow_windows := 0; muted := false end
               else muted := not !muted;
               audio ()
             | _ -> ()) ui.Gui.keys;
         let now_down = List.sort_uniq compare (List.concat (List.filter_map M.keys_of ui.Gui.held)) in
         List.iter (fun k -> if not (List.mem k !down) then M.press st.m k true) now_down;
         List.iter (fun k -> if not (List.mem k now_down) then M.press st.m k false) !down;
         down := now_down;
         if ui.Gui.tick then begin
           serve st;
           if not st.paused then begin
             let due = int_of_float ((now -. !start) *. M.hz) - !done_frames in
             let n = max 1 (min 4 due) in
             if due > 4 then begin start := now; done_frames := 0 end;
             let i = ref 0 in
             while !i < n && not st.paused do
               if run_frame st then begin incr done_frames; incr frames; send (M.audio_samples st.m) end;
               incr i
             done;
             if st.paused then audio ()
           end;
           if now -. !since >= 2. then begin
             st.fps <- float !frames /. (now -. !since); frames := 0; since := now;
             incr windows;
             (* slow: below nine tenths of the machine's rate, for two
                windows of two seconds *)
             if !windows > 1 && not st.paused && st.fps < 0.9 *. M.hz then incr slow_windows
             else slow_windows := 0;
             if !slow_windows >= 2 && not !too_slow then begin too_slow := true; audio () end
           end;
           draw ()
         end;
         Gfx.blit screen 0 0 ui.Gui.g 0 0 width pic_h;
         Gfx.fill ui.Gui.g 0 pic_h width 24 0x2B2F33;
         ignore (Gfx.text ui.Gui.g 6 (pic_h + 4)
                   (Printf.sprintf "%s%.0f fps%s   %s   PgUp pause, PgDn sound, Esc"
                      (if st.paused then "paused  " else "") st.fps
                      (if stream = None then "" else if !too_slow then ", no sound (slow)"
                       else if !muted then ", sound off" else ", sound")
                      (Emu_service.name st.svc)) 0xB0BEC5));
    Option.iter (fun s -> try Sound.stop s with _ -> ()) stream;
    exit 0

  let main () =
    match List.tl (Array.to_list Sys.argv) with
    | "--headless" :: rest -> headless (match rest with f :: _ -> Some f | [] -> None)
    | "--bench" :: n :: rest ->
      let service = not (List.mem "--no-service" rest) in
      bench (int_of_string n) service
        (match List.filter (( <> ) "--no-service") rest with f :: _ -> Some f | [] -> None)
    | f :: _ -> windowed (Some f)
    | [] -> windowed None
end
