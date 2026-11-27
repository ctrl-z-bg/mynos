# 25. Emulators as services: emu/1

MyNOS's emulators are not only windows. Each one registers a service of
its own, `<machine><pid>` (`zx1234` for a ZX Spectrum, `camlboy1234` for
a Game Boy), and answers the same typed protocol, emu/1
(`packages/retro/emu_proto.mli`): what the machine is, its registers and
memory, its screen; pausing it, stepping it, running it for some frames,
stopping it at a breakpoint; pressing its keys; loading a tape; saving
its state. A script, the Services window, a test or the agent can do
with an emulated machine what a person does at its keyboard, and what a
debugger does inside it. The design is in
`doc/decisions/retro-emulators.md`; this chapter shows how to use it
(25.1–25.5), with a complete program (25.5), and how an emulator serves
it without slowing down (25.6).

> **THE MyNOS FACTOR.** An emulator here is a citizen of the system: a
> typed service that describes itself. The Services window makes a form
> for any of its requests; the agent gets them as tools (the ones that
> change the machine asked first); the recorder shows its breakpoints
> and its loads among the system's calls. Nothing of this was written
> for the emulators: they speak typed IPC, and the rest follows.

## 25.1 Starting one, finding it

```
zxspectrum [FILE]             a window; FILE a .tap, .sna or .z80
zxspectrum --headless [FILE]  no window: the machine and its service
camlboy ROM.gb                a window
camlboy --headless ROM.gb
```

(`pkg install zxspectrum`, `pkg install camlboy`; each comes with games:
`zxspectrum glazx`, `zxspectrum snake`, `camlboy tobutobugirl`. Your own
tapes and cartridges go in `/disk/roms/zx`, `/disk/roms/gb`: the
packages' READMEs say which ROMs a machine can use.) The window's status line says
the service's name. A program finds the emulators running with
`Emu_proto.find`, which lists the registered names made of a prefix and
digits only:

```ocaml
Emu_proto.find "zx"        (* ["zx18"] *)
Emu_proto.find "camlboy"
```

and talks to one with the protocol's client, `Emu_proto.I`:

```ocaml
let zx = Emu_proto.I.connect "zx18" in
let info = Emu_proto.I.call zx Emu_proto.Info in
print_endline info.Emu_proto.machine        (* ZX Spectrum 48K *)
```

## 25.2 The requests

| Request | Safe | What it does |
|---|---|---|
| `info` | yes | the machine, its ROM, what was loaded, the frame, frames a second, paused or not, the names of its keys |
| `regs` | yes | the CPU's registers, by name |
| `peek space addr len` | yes | up to 4096 bytes: `cpu` (as the CPU sees it), `ram`, `vram`, `rom` |
| `disasm addr n` | yes | n instructions from addr, a line each |
| `screen_text` | yes | the screen as text, a line a row, `?` where a cell is no character |
| `screenshot` | yes | the screen as a PNG in `/tmp`, named after the service and the frame: its path |
| `pause` | no | paused: where it stopped |
| `resume` | no | running again |
| `step n` | no | n instructions (paused first) |
| `frames n` | no | n frames as fast as it can (paused first, paused after) |
| `break kind addr len` | no | `exec` (an instruction about to run), `read`, `write` (a watchpoint on a range): its id |
| `unbreak id`, `breaks` | no, yes | |
| `wait seconds` | no | until a breakpoint is hit or the machine pauses |
| `keys text` | no | the machine's keys (25.3); returns once typed |
| `poke space addr bytes` | no | (not `rom`) |
| `load file` | no | a tape, a snapshot, a cartridge: what it was |
| `save_state file`, `load_state file` | no | the machine's own format (a Spectrum's `.z80` or `.sna`) |
| `reset` | no | |

`screenshot` takes no path: a safe request, which the agent asks
without confirming, must not be able to write over a file of the
caller's choosing.

What stopped the machine comes back as a `stop`: `Running` (a wait ran
out), `Paused pc`, or `Hit (id, pc, addr)`, a breakpoint (`addr`: the
address a watchpoint saw touched; for `exec`, the PC).

A machine without something answers an error that says so: a Game Boy
has no text screen (`screen_text`: use `screenshot`), and camlboy has no
disassembler, watchpoints or saved states yet. The error is the answer:
a caller learns from it what to ask instead.

## 25.3 Keys

`keys` takes groups separated by spaces; a group is key names joined
by `+`, held for 2 frames, or as many as a `:n` after it says; between
two groups the keys are let go for a frame (six when the next group
presses one of the same keys: the Spectrum's ROM takes a key again only
once it has been up for a while). `info` lists the names a machine
knows:

```
Spectrum   A-Z 0-9 ENTER SPACE CS SS       (CS: CAPS SHIFT, SS: SYMBOL SHIFT)
Game Boy   A B START SELECT UP DOWN LEFT RIGHT
```

A Spectrum's BASIC is typed as its keyboard has it: a command is one
key in K mode (`P` is PRINT, `G` GO TO, `R` RUN, `J` LOAD), symbols are
SYMBOL SHIFT and a key (`SS+P` is `"`, `SS+Z` `:`, `SS+K` `+`), letters
are small unless CAPS SHIFT is held. So

```
P 2 SS+K 2 ENTER                          PRINT 2+2
1 0 P SS+P H E L L O SS+P SS+Z G 1 0 ENTER   10 PRINT "hello": GO TO 10
CS+0:5                                    DELETE, held a tenth of a second
```

`keys` returns an error, `paused`, when the machine is paused: its keys
would never be let go. After ENTER, give the ROM a few frames (a
`frames 10`) before the next keys: it is still putting the line into the
program, and a key typed then is lost.

## 25.4 Running, stopping, waiting

`pause`, `resume`, `step n` and `frames n` drive the machine by hand;
`step` and `frames` pause a running machine first, and `frames` runs as
fast as it can, not waiting for the clock, so that a script does a
thousand frames in a few seconds. A breakpoint or a watchpoint stops
the machine wherever it is, even in the middle of a frame; `frames`
returns the `Hit`, and `wait` returns it to whoever was waiting, on
another connection:

```ocaml
let id = I.call zx (Break (Exec, 0x02BF, 1)) in   (* the ROM's keyboard scan *)
match I.call zx (Wait 5.) with
| Hit (i, pc, _) when i = id -> ...               (* stopped at 0x02BF, paused *)
| Running -> ...                                  (* five seconds went by *)
| _ -> ...
```

`wait` on a paused machine answers at once (`Paused pc`). Breakpoints
hit and media loaded are marked in the recording (`Tracer.mark`), so a
recording made meanwhile shows them on its timeline (chapter 22).

## 25.5 A complete program

`examples/25/hello_zx.ml` finds a Spectrum, types a BASIC program,
runs it, reads the screen, then stops the machine at the ROM's
character printer:

```ocaml
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
```

```
mynos:/$ zxspectrum --headless &
mynos:/$ hello_zx
ZX Spectrum 48K, frame 433
| hello
| hello
| hello
22 lines of hello on the screen
stopped at 02BF:
02BF  CD 8E 02     CALL $028E
02C2  C0           RET NZ
02C3  21 00 5C     LD HL,$5C00
```

The 22 lines are a screenful: the program waits at `scroll?`, which the
screen's last line shows. The breakpoint is in KEYBOARD, which the
interrupt calls fifty times a second: `wait` returns within a frame.

## 25.6 How an emulator serves, and runs at full speed

The emulation loop must not slow down because it is a service, and the
machine's state must never be seen half-way through an instruction.
`Emu_service` (`packages/retro/emu_service.mli`) does both:

```
the service's thread                     the emulation loop (50 or 60 a second)
--------------------                     -------------------------------------
listen zx<pid>                           run a frame (no lock here)
recv, decode                             at the frame's end, or stopped:
  an error: answered at once               anything queued? (an Atomic.t)
  a request: queued with its channel         take them (the lock, once)
  listen again                               do each, answer on its channel
                                         wait and keys: kept, answered later
```

- **A thread, not a domain.** A second domain must join every minor
  collection of the emulator's: waiting on IPC, it would slow every
  frame. A thread blocked in `listen` costs nothing.
- **Answers later.** The thread does not use `Ipc.Make`'s `serve`, which
  answers one request before taking the next: a `wait` would hold every
  other caller. It uses the protocol's `decode` and `reply`, and the
  loop answers each channel when it can.
- **Two loops.** Without breakpoints the frame runs instructions with no
  check at all; with them, the PC is looked at before each one, and the
  bus that checks watchpoints is put in only while there are some. An
  idle service costs nothing measurable (`packages/zxspectrum/MYNOS.md`).
