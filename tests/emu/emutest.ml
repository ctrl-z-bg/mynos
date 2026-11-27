(* A Spectrum driven through emu/1 (doc/decisions/retro-emulators.md,
   section 8): the zx<pid> running (zxspectrum --headless), its info; the
   ROM's message on its screen; PRINT 2+2 typed (P 2 SS+K 2 ENTER), its 4
   read back; then the rest of the protocol: registers, memory, the
   disassembly, a screenshot, a poke, a breakpoint hit by frames, the
   waits, a state saved and loaded. A line per check, "emu: ... ok". *)

module E = Emu_proto
module C = Emu_proto.I

let check name ok =
  Printf.printf "emu: %-58s %s\n%!" name (if ok then "ok" else "FAIL");
  ok

let has text sub =
  let n = String.length sub in
  let rec f i = i + n <= String.length text && (String.sub text i n = sub || f (i + 1)) in
  f 0

let rec service tries =
  match E.find "zx" with
  | name :: _ -> name
  | [] -> if tries = 0 then failwith "no zx<pid>" else (Mynos.sleep 0.5; service (tries - 1))

let () =
  let name = service 60 in
  let c = C.connect name in
  let all = ref true in
  let ok n b = if not (check n b) then all := false in
  let info = C.call c E.Info in
  ok ("info: " ^ info.E.machine) (info.E.machine = "ZX Spectrum 48K");
  (* the ROM ready: its message *)
  let rec ready k =
    let t = C.call c E.Screen_text in
    if has t "Sinclair Research" || k = 0 then t else (Mynos.sleep 0.5; ready (k - 1)) in
  let t = ready 60 in
  ok "screen_text: the ROM's message" (has t "\u{a9} 1982 Sinclair Research Ltd");
  C.call c (E.Keys "P 2 SS+K 2 ENTER");
  let t = C.call c E.Screen_text in
  let lines = String.split_on_char '\n' t in
  ok "keys: P 2 SS+K 2 ENTER, then 4 on the screen" (List.exists (fun l -> String.trim l = "4") lines);
  ok "screen_text: 0 OK" (has t "0 OK, 0:1");
  let regs = C.call c E.Regs in
  ok "regs: PC and SP" (List.mem_assoc "PC" regs && List.mem_assoc "SP" regs);
  let rom = C.call c (E.Peek (E.Rom, 0, 4)) in
  ok "peek rom 0: F3 AF 11 FF (DI, XOR A, LD DE,...)" (rom = [ 0xF3; 0xAF; 0x11; 0xFF ]);
  let d = C.call c (E.Disasm (0, 3)) in
  ok "disasm 0: DI, XOR A, LD DE,$FFFF" (has d "DI" && has d "XOR A" && has d "LD DE,$FFFF");
  let png = C.call c E.Screenshot in
  ok ("screenshot: " ^ png) (Sys.file_exists png && String.length png > 5);
  (* a poke into the screen's attributes, read back *)
  C.call c (E.Poke (E.Ram, 0x1800, [ 0x38 ]));
  ok "poke ram, peek cpu" (C.call c (E.Peek (E.Cpu, 0x5800, 1)) = [ 0x38 ]);
  (* the ROM's keyboard scan (KEYBOARD, 0x02BF), called by every
     interrupt: a breakpoint there is hit within a frame *)
  let id = C.call c (E.Break (E.Exec, 0x02BF, 1)) in
  let stop = C.call c (E.Frames 5) in
  ok "break 02BF, frames 5: hit there"
    (match stop with E.Hit (i, pc, _) -> i = id && pc = 0x02BF | _ -> false);
  ok "breaks: one" (List.length (C.call c E.Breaks) = 1);
  ok "wait, paused: at once" (match C.call c (E.Wait 5.) with E.Paused _ | E.Hit _ -> true | _ -> false);
  ok "keys, paused: an error"
    (match C.call c (E.Keys "A") with () -> false | exception Ipc.Remote_error _ -> true);
  C.call c (E.Unbreak id);
  ok "step 3: paused" (match C.call c (E.Step 3) with E.Paused _ -> true | _ -> false);
  (* a watchpoint on FRAMES (0x5C78), which the interrupt writes *)
  let w = C.call c (E.Break (E.Write, 0x5C78, 1)) in
  C.call c E.Resume;
  ok "watch write 5C78, wait: hit"
    (match C.call c (E.Wait 5.) with E.Hit (i, _, a) -> i = w && a = 0x5C78 | _ -> false);
  C.call c (E.Unbreak w);
  C.call c E.Resume;
  ok "wait 0.3, running: running" (C.call c (E.Wait 0.3) = E.Running);
  (* a state saved, the screen changed, the state back *)
  let f = "/tmp/emutest.z80" in
  C.call c (E.Save_state f);
  C.call c (E.Keys "C");                 (* CLS *)
  C.call c (E.Keys "ENTER");
  C.call c (E.Load_state f);
  ignore (C.call c (E.Frames 2));
  ok "save_state, load_state: the 4 back" (has (C.call c E.Screen_text) "0 OK, 0:1");
  C.call c E.Resume;
  print_endline (if !all then "emu: all checks passed" else "emu: some checks FAILED");
  exit (if !all then 0 else 1)
