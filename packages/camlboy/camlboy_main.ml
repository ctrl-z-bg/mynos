(* camlboy: a Game Boy, in a window. The emulator is CAMLBOY, by
   linoscope (MIT, third_party/camlboy); this is its face in MyNOS.

     camlboy ROM.gb

   Arrows: the cross; X: A; Z: B; Enter: Start; Space: Select; P pauses;
   Escape quits. The game runs at its own pace, 60 frames a second, when
   the machine is fast enough: on a PC or under KVM; in QEMU without KVM,
   at about a third of it.

   MyNOS's windows get keys, not their release: a key counts as held for
   a moment after each press, longer after the first (the keyboard's
   repeat starts after half a second). *)

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
  let held = Hashtbl.create 8 in             (* key -> held until *)
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
  Gui.run ~title:("Game Boy: " ^ Filename.basename rom) ~tick:(1. /. 60.) width height ()
    (fun ui () ->
       let now = Mynos.uptime () in
       List.iter (fun k ->
           match List.assoc_opt k keys with
           | Some b ->
             let repeat = match Hashtbl.find_opt held b with Some t -> t > now | None -> false in
             if not repeat then C.press gb b;
             Hashtbl.replace held b (now +. if repeat then 0.15 else 0.55)
           | None ->
             match k with
             | "\027" -> raise Gui.Quit
             | "p" | "P" ->
               paused := not !paused; start := now; done_frames := 0
             | _ -> ()) ui.Gui.keys;
       Hashtbl.filter_map_inplace (fun b t -> if t <= now then (C.release gb b; None) else Some t) held;
       if ui.Gui.tick && not !paused then begin
         let due = int_of_float ((now -. !start) *. 60.) - !done_frames in
         let n = max 1 (min 4 due) in
         if due > 4 then begin start := now; done_frames := 0 end;
         for i = 1 to n do frame ~show:(i = n); incr done_frames done;
         frames := !frames + n;
         if now -. !since >= 2. then begin
           fps := float !frames /. (now -. !since); frames := 0; since := now end
       end;
       Gfx.blit screen 0 0 ui.Gui.g 0 0 width (gb_h * scale);
       Gfx.fill ui.Gui.g 0 (gb_h * scale) width 24 0x2B2F33;
       ignore (Gfx.text ui.Gui.g 6 (gb_h * scale + 4)
                 (Printf.sprintf "%s%.0f fps   arrows, X, Z, Enter, Space; P pauses, Esc quits"
                    (if !paused then "paused  " else "") !fps) 0xB0BEC5);
       ())
