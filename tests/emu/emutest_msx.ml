(* msx driven through emu/1: msx<pid> (msx --headless westen, the game
   named as a user names it), its info, registers, the cartridge in the
   CPU's memory, the VRAM, a breakpoint on the interrupt's entry (0x0038)
   hit by frames, a watchpoint on the BIOS's JIFFY (0xFC9E, counted at
   each interrupt), keys, a disassembly, a screenshot, a state saved and
   loaded, and screen_text refused in Graphics II. A line per check,
   "emu-msx: ... ok". *)
module E = Emu_proto
module C = Emu_proto.I

let rec service tries =
  match E.find "msx" with
  | name :: _ -> name
  | [] -> if tries = 0 then failwith "no msx<pid>" else (Mynos.sleep 0.5; service (tries - 1))

let () =
  let c = C.connect (service 60) in
  let all = ref true in
  let ok n b = Printf.printf "emu-msx: %-49s %s\n%!" n (if b then "ok" else "FAIL"); if not b then all := false in
  let info = C.call c E.Info in
  ok ("info: " ^ info.E.machine ^ ", " ^ info.E.rom) (info.E.machine = "MSX1");
  ok ("loaded: " ^ info.E.loaded)
    (String.length info.E.loaded > 9 && String.sub info.E.loaded 0 9 = "cartridge");
  ok "regs: PC and SP" (let r = C.call c E.Regs in List.mem_assoc "PC" r && List.mem_assoc "SP" r);
  ignore (C.call c (E.Frames 600));
  ok "peek cpu 0x4000: the cartridge's AB"
    (match C.call c (E.Peek (E.Cpu, 0x4000, 2)) with [ 0x41; 0x42 ] -> true | _ -> false);
  ok "peek vram: something drawn"
    (List.exists (( <> ) 0) (C.call c (E.Peek (E.Vram, 0x1800, 768))));
  let id = C.call c (E.Break (E.Exec, 0x0038, 1)) in
  ok "break 0038, frames 3: the interrupt"
    (match C.call c (E.Frames 3) with E.Hit (i, 0x38, _) -> i = id | _ -> false);
  ok "disasm 0038" (String.length (C.call c (E.Disasm (0x38, 2))) > 0);
  C.call c (E.Unbreak id);
  let w = C.call c (E.Break (E.Write, 0xFC9E, 2)) in
  ok "watch write FC9E (JIFFY), frames 3"
    (match C.call c (E.Frames 3) with E.Hit (i, _, a) -> i = w && (a = 0xFC9E || a = 0xFC9F) | _ -> false);
  C.call c (E.Unbreak w);
  C.call c (E.Save_state "/tmp/emutest.state");
  let jiffy () = match C.call c (E.Peek (E.Ram, 0xFC9E, 1)) with [ v ] -> v | _ -> -1 in
  let before = jiffy () in
  ignore (C.call c (E.Frames 30));
  C.call c (E.Load_state "/tmp/emutest.state");
  ok "state saved, 30 frames, loaded: JIFFY back" (jiffy () = before);
  C.call c E.Resume;
  C.call c (E.Keys "SPACE");
  ok "keys: SPACE typed" true;
  let png = C.call c E.Screenshot in
  ok ("screenshot: " ^ png) (Sys.file_exists png);
  let refused r = match C.call c r with _ -> false | exception Ipc.Remote_error _ -> true in
  ok "screen_text: refused in Graphics II" (refused E.Screen_text);
  print_endline (if !all then "emu-msx: all checks passed" else "emu-msx: some checks FAILED");
  exit (if !all then 0 else 1)
