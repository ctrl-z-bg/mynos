# Decision: home computers of the 1980s, emulated, and emulators as services

- **Issue:** mynos-0bj
- **Date:** 2026-11-27
- **Status:** accepted (2026-11-27). Done: the ZX Spectrum 48K
  (`zxspectrum` 1.0, with GLAZX), camlboy on emu/1 (1.2), the manual's
  chapter 25; section 11 has the results. Next: a one-player Spectrum
  game, then the MSX (mynos-0bj.3).

## What it is for

MyNOS has a Game Boy, `camlboy`. The owner would like the home computers
of the 1980s too: the ZX Spectrum, the MSX, the Commodore 64. And with
MyNOS's factor, as Studio has it: an emulator that is not only a window
but a citizen of the system, a typed service that a script, the Services
window, the agent and the tests can ask what the machine is doing, and
make it do things.

## What exists

Searched on 2026-11-27. In OCaml, for these three machines, nothing to
port:

- **Z80** (Spectrum, MSX): no core in OCaml. The good ones are in C (the
  "Z80" library of redcode, FUSE's), Rust, C#, Go, JavaScript, Erlang.
- **6502/6510** (C64): `6502-ml` (Virgile Robles, MIT, about 1,100 lines,
  github.com/Firobe/6502-ml), written for `nes-ml`, a NES in OCaml. It
  passes Klaus Dormann's functional tests and nestest, with exact cycle
  counts, unofficial instructions too. A functor over the memory map. It
  needs `stdint` (C stubs) and the ppx `stdint-literals`: to be replaced
  by `int` and masks, as `Bigstringaf` was replaced in CAMLBOY.
- **The C64's chips** (VIC-II, SID, CIA), **the Spectrum's ULA**, **the
  MSX's TMS9918A**: nothing in OCaml.
- In OCaml there are consoles only: CAMLBOY, Goodboy (Game Boy),
  `nes-ml`, a few CHIP-8.

So the emulators are written for MyNOS, MIT, as `apu.ml` was.

## Choices

### 1. The order: Spectrum, MSX, then perhaps the C64

| Machine | Parts | Lines (estimated) |
|---|---|---|
| ZX Spectrum 48K | Z80 (~1,800), ULA (~400), `.sna`/`.z80` and `.tap` with a trap (~300) | ~2,700 |
| + 128K | paging, AY-3-8912 (~350) | +350 |
| MSX1 (the Z80 written) | TMS9918A (~800), the AY (shared), PPI and slots (~250), MegaROM mappers (~350) | ~1,500 |
| C64, line by line | 6502-ml without stdint, VIC-II by lines (~1,300), two CIAs (~500), a simpler SID (~600), PLA (~200), `.prg`, `.crt`, `.d64` by a KERNAL trap (~500) | ~3,500 |

CAMLBOY, for scale: 4,170 lines, of which the CPU 479, the GPU 386, the
APU (MyNOS's) 384.

The Spectrum first: the simplest machine, a ROM that may be shipped,
plenty of free homebrew. The MSX next: it shares the Z80 and the AY. The
C64 last, if at all: the largest, its ROMs cannot be shipped (section 3),
and its speed in bytecode is the open question (section 9).

### 2. Shared code: `packages/retro`

`z80.ml`, `z80_disasm.ml`, later `ay8910.ml`, the protocol
`emu_proto.ml` (section 5) and `emu_service.ml`, the service's thread
and its queue (section 6), in `packages/retro`; each machine's package
lists them in its `spec`, as `camlboy` lists `third_party/camlboy/src`.
Pure OCaml: `int` and `Bytes`, no C stubs, no `stdint`, no `Bigstringaf`,
since the runtime is the bytecode one and packages are compiled inside
MyNOS when their bytecode does not match. Bytes are masked
(`land 0xFF`), never left to overflow: integers are 31 bits on the i386,
63 on x86-64 and AArch64.

The Z80 runs an instruction at a time and returns its T-states (the
cheapest model in bytecode); memory and ports through a record of
closures (`read`, `write`, `input`, `output`), which the MSX's slots
need and which costs the Spectrum a `Bytes.unsafe_get`. The undocumented
flags (bits 3 and 5) and MEMPTR as FUSE has them; the flag tables
precomputed. `set_bus` lets the machine swap the bus for one that checks
watchpoints, only while there are some (section 6).

### 3. ROMs: what may be shipped

- **Spectrum**: Amstrad allows the ROMs to be distributed, keeping their
  copyright, not to be sold nor put in hardware. The 48K ROM goes in the
  package with Amstrad's text: "Amstrad have kindly given their
  permission for the redistribution of their copyrighted material but
  retain that copyright".
- **MSX**: C-BIOS (BSD 2-clause), written from scratch, made to be
  shipped with emulators. It runs cartridges only: no BASIC, no tape, no
  disk. Enough for most MSX1 games, homebrew included.
- **C64**: Commodore's ROMs may not be shipped. The MEGA65's Open ROMs
  (GPLv3, a clean-room reimplementation) can be, as a separate file, with
  less compatibility; or the user puts their own in `/disk`.

### 4. The Spectrum, as a package

`packages/zxspectrum`: `ula`, `keyboard`, `beeper`, `tape`, `snapshot`,
`spectrum`, and `zxspectrum_main.ml` on the model of `camlboy_main.ml`
(a window of 640 x 480 and a status line, 50 frames a second, the sound
from a thread, off by default and turned off by itself below 50 frames
a second; Page Up pauses, Page Down the sound, Escape quits: P and M
are Spectrum keys). Frames of 69,888
T-states, the interrupt at the start, no memory contention (later, if a
game needs it). `.tap` loaded through a trap on LD-BYTES (0x0556):
instant. The game, a package of data as `tobutobugirl`: GLAZX (Eugeny
Novikov, 2019, MIT), two players at one keyboard, which exercises keys
held together. (Changed afterwards, 2026-11-27: the test games come in
the emulator's package, `games/`, named without a path, `zxspectrum
glazx`; a user's own ROMs and tapes in `/disk/roms/<machine>/`, each
README naming the proprietary ROMs a machine can use. The MSX comes
with C-BIOS and one game.)

Keys: Shift and a letter give CAPS SHIFT and the letter, Ctrl and a letter
SYMBOL SHIFT and the letter. Shift or Ctrl alone do not reach a window
(the console reports only keys that type something); some games use CAPS
or SYMBOL alone. Left for later: it would be a change to `consoled` (the
kitty protocol has codes for modifiers), not to the package. Through
"emu/1" they can be pressed alone already.

### 5. The emulators are services: "emu/1"

One protocol for every emulator (Spectrum, MSX, C64, and `camlboy`
adapted), so that what uses one uses them all; only what `info` says
changes. Each registers `<machine><pid>` (`zx<pid>`, `msx<pid>`,
`camlboy<pid>`), as Studio registers `studio<pid>`; `Emu_proto.find
"zx"` lists the names made of the prefix and digits only (`zx1234`,
not `zxspectrum`). Made with `Ipc.Make`, so it describes itself.

Requests that only read (`safe`):

- `info`: the machine, its ROM, what is loaded, the frame, frames a
  second, paused or not.
- `regs`: the CPU's registers.
- `peek space addr len`: memory; `space` is `"cpu"` (as the CPU sees
  it), `"ram"`, `"vram"` (the MSX's VDP), `"rom"`.
- `disasm addr n`: `n` instructions from `addr`.
- `screen_text`: the screen as text. The Spectrum: each 8 x 8 cell
  compared with the ROM's font (0x3D00), inverse cells too, `?` for the
  others; the MSX in its text modes: the name table. A model that reads
  only text sees the screen.
- `screenshot`: the screen as a PNG in `/tmp`, named after the
  service and the frame (`zx1234-5000.png`), which `view` opens: its
  path. The caller chooses no path: a safe request, which the agent asks
  without confirming, must not be able to overwrite a file.

Requests that change things (confirmed first when the agent asks them):

- `pause`, `resume`, `step n` (instructions), `frames n`. `step` and
  `frames` pause a running machine first, then advance it; `frames` runs
  as fast as it can, not waiting for the clock (in a window or
  headless), so that tests stay quick.
- `break`, `unbreak`, `breaks`: on the PC (the fetch of an
  instruction's opcode), and watchpoints on reads or writes of memory
  (the CPU's reads: not its fetches of instructions).
- `wait timeout`: returns when a breakpoint is hit or the machine
  pauses; at once, `Paused pc`, if it is paused. One connection per
  call, so a call that waits costs nothing.
- `keys`: a sequence of the machine's keys, each group held for some
  frames, in a small notation: groups separated by spaces, names joined
  by `+`, held 2 frames unless `:n` says (`"CS+0:5"`); on the Spectrum
  `"P 2 SS+K 2 ENTER"` types `PRINT 2+2`; it returns once the last
  key is let go, so that what follows (`screen_text`) sees its effect;
  an error ("paused") at once if the machine is paused, whose keys would
  never be let go.
- `poke`, `load` (tape, snapshot, cartridge), `save_state`, `load_state`
  (on the Spectrum the native `.z80` and `.sna`), `reset`.

Breakpoints hit and media loaded are marked in the recording
(`Tracer.mark`): the recordings window shows them on the timeline.

No `type` of free text for now: on the 48K a BASIC command is entered
as a keyword (P in K mode is PRINT), so typing "PRINT" letter by letter
does not mean PRINT. A translation from text to keys can come later.

### 6. How the service lives beside the emulation

- **A thread, not a domain.** The lesson of 2026-11-22 (JOURNAL: "A
  second domain slowed camlboy by a tenth"): a domain that waits slows
  every minor collection of the emulator. The service waits on IPC: it
  is a `Thread`.
- **A queue, done between frames.** The service's thread puts each
  request in a queue; the emulation loop does them at the end of a frame,
  or when it stops at a breakpoint, and answers. No lock in the loop that
  runs the CPU; the machine's state is never seen half-way through an
  instruction; a request waits at most a frame (20 ms). The thread does
  not use `Ipc.Make`'s `serve`, which answers one request at a time
  before taking the next (a `wait` would hold every other caller): it
  listens, decodes (`decode`), and queues the request with its channel;
  the loop answers on the channel (`reply`), at once, or later for
  `wait` and `keys`. The loop looks at the queue once a frame through an
  `Atomic.t` (the cost of a field read, and right with any number of
  domains); the lock only when there is something. The thread and the
  queue are the same for every machine: `emu_service.ml`.
- **Two loops.** `run_fast` checks nothing per instruction; `run_checked`
  checks the PC against the breakpoints before each one, and the bus
  that checks watchpoints is put in only while there are watchpoints. An
  emulator whose service is idle runs as fast as one without: to be
  measured.
- **The bus.** The Z80's has `fetch` (an opcode's read, the M1 cycle)
  apart from `read`: the watchpoints on reads look at `read` only (the
  instructions' fetches are the breakpoints'), and the machines that
  need it (contention, paging on M1) can tell them apart. On the
  Spectrum, `fetch` is `read`.

### 7. What the services give, and what they make possible

Because `Ipc.Make` services describe themselves, the emulator gets, for
the price of the protocol:

- **A debugger with a window, unwritten.** The Services window makes a
  form for any request of any typed service from its description:
  registers, memory, disassembly, breakpoints, steps, all there.
- **Scripts.** `sh`, the OCaml toplevel or a program call `zx<pid>` as
  any service: load a tape, run a thousand frames, read the screen.
- **The agent.** `Tools` turns the description into a model's tools; the
  agent uses the emulator as it uses Studio, the requests that change
  things confirmed first. "Load the game, reach the first level, tell me
  how many lives it gives": with `peek` and watchpoints it can find where
  the lives are kept, as players once looked for their POKEs.
- **Tests of the emulators themselves, through the service.** Boot the
  Spectrum, send `"P 2 SS+K 2 ENTER"`, find `4` in `screen_text`,
  rather than by looking at a window. (zexdoc and zexall run elsewhere,
  as native code on the host: section 8.)
- **Retro development inside MyNOS.** Write in Studio, run in the
  emulator, debug with breakpoints and `disasm`; an assembler (Z80, 6502)
  is the missing piece, for later.
- **The recorder.** Breakpoints and loads among the system's calls, on
  one timeline.

### 8. Tests

- The Z80: zexdoc and zexall as CP/M programs (a trap on BDOS 0x0005,
  C = 2 and C = 9, the end at 0x0000), run on the host
  (`tests/z80/run.sh zex`): as bytecode in the dev container, since no
  native compiler is there (about 24 minutes each); FUSE's tests,
  registers, memory and T-states instruction by instruction.
- The Spectrum through "emu/1": the test of section 7, in the suite.
  For it, and for scripts, `zxspectrum --headless`: the machine and its
  service without a window, 50 frames a second by the clock.
- A JOURNAL entry with the results.

### 9. Speed

Measured (`packages/zxspectrum/MYNOS.md`): the Spectrum makes about 300
frames a second in bytecode on the host, about 330 in MyNOS under QEMU
with KVM, 10 without it (a fifth of the 50 it needs, not the third
expected); an idle service costs nothing measurable.

Expected beforehand: CAMLBOY, in bytecode: 360 frames a second on the host, 357 inside MyNOS
under QEMU with KVM, 18 without KVM; the Game Boy needs 60, at 4.19 MHz.
The Spectrum's and the MSX's Z80 run at about 3.5 MHz, with simpler
video: the same margin is expected, full speed under KVM, about a third
of it without. The C64 is the risk: a VIC-II and a SID stepped cycle by
cycle could leave only two or three times real time even with KVM; a
VIC-II drawn line by line is the choice for bytecode. The figures to be
measured and written in the package's `MYNOS.md`, as for `camlboy`.

### 10. Branches

The emulators are packages: user space only, on `Ipc`, `Gui`, `Sound`,
`Tracer` and threads, which `main` (version 1, the book's) and `next`
(version 2) both have. Packages land on `main` and reach `next` when
`main` is merged into it (as `sysmonitor` 1.1 and `utils` 1.2 did).
The Spectrum went so: a branch `retro` from `main`, merged into `main`
when it and its tests were done, then `main` into `next`. Since then
(2026-11-27) the applications have a branch of their own, `apps` (its
worktree `../mynos-apps`): the emulators' work is on `retro`, merged
into `apps`; `apps` goes into `main`, and `main` into `next`, as
someone decides. On `next`
they must also build and run on x86-64 and AArch64 (section 2: masks,
not overflow); without KVM, as on a Raspberry Pi, expect a third of the
speed or less.

### 11. Results (2026-11-27)

- **The Z80** (`packages/retro/z80.ml`, about 900 lines): FUSE's 1356
  tests, zexdoc and zexall (67 of 67 each, 24 minutes each in bytecode)
  all passed; the one bug they found was a table entry (`overflow_sub`).
  FUSE's Q (SCF and CCF's undocumented bits) and its handling of a
  prefix that touches no index register are followed.
- **The Spectrum**: GLAZX loads at once and plays at 50 frames a second
  under KVM; the suite drives it through emu/1 (lane c): the ROM's
  message read, PRINT 2+2 typed and its 4 read back, breakpoints,
  watchpoints, waits, a state saved and loaded, on the i386, x86-64 and
  AArch64.
- **emu/1** served by camlboy too (1.2): what a Game Boy cannot give
  answers an error; the suite drives it after the Spectrum.
- **Changes to this decision while doing it**: `keys`'s frames are
  written `:n` (a number after a group would have been a digit key);
  Page Up and Page Down pause and sound the Spectrum (P and M are its
  keys); the sound goes off below 45 frames a second, not 50; zexall
  ran as bytecode (no native compiler in the containers).

## Not now

The 128K and the AY (with the MSX, which needs the AY); memory
contention; Shift and Ctrl alone in windows; the MSX2 (its V9938 is
another VDP); the C64 cycle by cycle, its 1541 drive emulated; a `type`
of free text with BASIC's keywords; an assembler.
