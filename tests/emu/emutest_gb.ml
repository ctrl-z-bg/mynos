(* camlboy driven through emu/1: camlboy<pid> (camlboy --headless ROM),
   its info, registers, the cartridge's entry, a breakpoint on the VBlank
   interrupt's vector (0x0040) hit by frames, keys, a screenshot, and the
   errors of what a Game Boy has not. A line per check, "emu-gb: ... ok". *)
module E = Emu_proto
module C = Emu_proto.I

let rec service tries =
  match E.find "camlboy" with
  | name :: _ -> name
  | [] -> if tries = 0 then failwith "no camlboy<pid>" else (Mynos.sleep 0.5; service (tries - 1))

let () =
  let c = C.connect (service 60) in
  let all = ref true in
  let ok n b = Printf.printf "emu-gb: %-50s %s\n%!" n (if b then "ok" else "FAIL"); if not b then all := false in
  let info = C.call c E.Info in
  ok ("info: " ^ info.E.machine) (info.E.machine = "Game Boy (DMG)");
  ok "regs: PC and SP" (let r = C.call c E.Regs in List.mem_assoc "PC" r && List.mem_assoc "SP" r);
  ok "peek rom 0x100: the entry (NOP, JP)"
    (match C.call c (E.Peek (E.Rom, 0x100, 2)) with [ 0x00; 0xC3 ] -> true | _ -> false);
  ignore (C.call c (E.Frames 120));
  let id = C.call c (E.Break (E.Exec, 0x0040, 1)) in
  ok "break 0040, frames 10: the VBlank interrupt"
    (match C.call c (E.Frames 10) with E.Hit (i, 0x40, _) -> i = id | _ -> false);
  C.call c (E.Unbreak id);
  C.call c E.Resume;
  C.call c (E.Keys "START A");
  ok "keys: START A typed" true;
  let png = C.call c E.Screenshot in
  ok ("screenshot: " ^ png) (Sys.file_exists png);
  let refused r = match C.call c r with _ -> false | exception Ipc.Remote_error _ -> true in
  ok "screen_text: refused" (refused E.Screen_text);
  ok "watchpoints: refused" (refused (E.Break (E.Write, 0xC000, 1)));
  print_endline (if !all then "emu-gb: all checks passed" else "emu-gb: some checks FAILED");
  exit (if !all then 0 else 1)
