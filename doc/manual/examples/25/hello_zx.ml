(* hello_zx: a ZX Spectrum driven through emu/1 (chapter 25). It finds a
   running zxspectrum (zx<pid>), types a BASIC program with the
   Spectrum's own keys, runs it, reads the screen as text, then stops the
   machine in the ROM's keyboard scan with a breakpoint.

     zxspectrum --headless &
     hello_zx *)

module E = Emu_proto
module C = Emu_proto.I

let rec find tries =
  match E.find "zx" with
  | name :: _ -> name
  | [] when tries > 0 -> Mynos.sleep 0.5; find (tries - 1)
  | [] -> failwith "no zxspectrum running"

let () =
  let zx = C.connect (find 20) in
  let info = C.call zx E.Info in
  Printf.printf "%s, frame %d\n" info.E.machine info.E.frame;
  (* 10 PRINT "hello": GO TO 10: in K mode P is PRINT and G is GO TO;
     SS+P is the quote, SS+Z the colon; letters are small without CAPS
     SHIFT (CS+H would be an H) *)
  C.call zx (E.Keys "1 0 P SS+P H E L L O SS+P SS+Z G 1 0 ENTER");
  (* the ROM takes a few frames to put the line in the program: R typed
     at once was lost *)
  ignore (C.call zx (E.Frames 10));
  C.call zx E.Resume;
  C.call zx (E.Keys "R ENTER");                    (* RUN *)
  ignore (C.call zx (E.Frames 100));               (* two seconds, at full speed *)
  let screen = C.call zx E.Screen_text in
  let lines = String.split_on_char '\n' screen in
  List.iteri (fun i l -> if i < 3 then Printf.printf "| %s\n" l) lines;
  let hellos = List.length (List.filter (fun l -> String.trim l = "hello") lines) in
  Printf.printf "%d lines of hello on the screen\n" hellos;
  (* KEYBOARD, the ROM's scan of the keys (0x02BF), runs at every
     interrupt: a breakpoint there, the machine let go, a wait *)
  let id = C.call zx (E.Break (E.Exec, 0x02BF, 1)) in
  C.call zx E.Resume;
  (match C.call zx (E.Wait 5.) with
   | E.Hit (_, pc, _) -> Printf.printf "stopped at %04X:\n%s" pc (C.call zx (E.Disasm (pc, 3)))
   | _ -> print_endline "no stop");
  C.call zx (E.Unbreak id);
  C.call zx E.Resume
