# MyNOS applications journal

The engineering diary of MyNOS's applications: the packages
(`packages/`) and the libraries they share (`packages/retro`). Same
format as `doc/JOURNAL.md`: for every non-trivial finding, the symptom,
the diagnosis, the cause, the fix, the lesson. The kernel, the services,
the system's libraries (`mynos-lib`) and the toolchain keep
`doc/JOURNAL.md`; the version 2 line's own work (branch `next`: other
processors, SMP, the Raspberry Pis) `doc/JOURNAL-next.md` there.
Applications land on `main` and reach `next` with its merges; an entry
about a package goes here on either branch.

## 2026-11-27 — A Z80 in OCaml, and a Spectrum as a service

**What was done.** The first of the retro emulators
(doc/decisions/retro-emulators.md): a Z80 in OCaml (`packages/retro/z80.ml`,
int and Bytes only, every byte masked), a 48K Spectrum around it
(`packages/zxspectrum`), and the protocol emu/1, served from a thread
whose requests the emulation loop does between frames.

**The Z80's tests.**
- FUSE's tests (`tests/z80`: 1356 of them, registers, flags, MEMPTR, Q,
  T-states, memory): 1334 passed at the first run; the 22 others were
  SUB, SBC and CP's overflow, from one wrong table (`overflow_sub` with V
  in its places 1 and 5, where FUSE's has 1 and 6). Then all 1356.
- zexdoc and zexall: 67 of 67 each, at the first run, 46.7 billion
  T-states each in 24 minutes of bytecode (the dev container's
  `ocamlrun`, 31-bit ints): 32 MHz of Z80. No native compiler is in the
  containers, nor OCaml on the host: the decision said native code,
  bytecode it was, fast enough.

**Findings.**
- FUSE now models Q (`last_Q`): SCF and CCF take bits 3 and 5 from
  `(Q xor F) or A`, Q being F when the last instruction set the flags,
  0 otherwise. Its tests expect it; the core follows (`setf`).
- FUSE runs an instruction after a DD or FD that uses no index register
  in the same step (its `end_opcode` again): the T-states of the pair,
  R counted twice, no interrupt between; and that second pass resets
  `last_Q`.
- On the i386 an int is 31 bits: the PNG's CRC and Adler (32 bits)
  overflowed; they are Int32 (only screenshots pay).
- The ROM takes a key again only after it has been up for a few
  interrupts: `LOAD ""` typed by emu/1's keys lost its second quote.
  A group that repeats a key of the one before waits six frames.
- The notation of `keys` first read a number after a group as its
  frames; but `"P 2 SS+K 2 ENTER"` must type PRINT 2+2. Frames are
  `:n` now (`CS+0:5`).
- P and M, which the decision gave to pause and sound, are Spectrum
  keys (PRINT; GLAZX's M ends a game): Page Up and Page Down instead.

**Lesson.** A test suite written by another emulator's authors (FUSE's)
finds in seconds what a month of games would: one wrong table entry,
22 failures, all named.

## 2026-11-27 — The Spectrum's sound off at full speed

**Symptom.** GLAZX in a window at 50 frames a second, under KVM: the
status line said "no sound (slow)".

**Cause.** The rule that turns the sound off when the machine is too slow
came from camlboy: below 50 frames a second for two windows of two
seconds. For the Game Boy, at 60, 50 is a margin; for the Spectrum 50 is
its own rate, and a measure of 49.8 (the timer's jitter) counted as slow.
Once off, it stayed off.

**Fix.** Below 45 (nine tenths of 50); Page Down turns it on again even
after it went off by itself.

**Lesson.** A threshold copied from another machine is a fraction of
that machine's rate: write it as one.

## 2026-11-27 — camlboy serves emu/1

**What was done.** The Game Boy gets the protocol the Spectrum has
(`camlboy<pid>`), with `packages/retro`'s service: what drives one drives
the other; `info` says which.

**What a Game Boy could not give.** CAMLBOY keeps its CPU's PC and SP in
a record of its own and its bus behind a functor: four small changes
(MYNOS.md) expose them. Requests the machine has no answer for say so
with an error rather than an empty reply: `screen_text` (no text mode:
`screenshot` instead), `disasm` (no LR35902 disassembler yet), watchpoints
(they would need a bus that checks, inside CAMLBOY's functor), saved
states, `load` of another cartridge (the cartridge's type picks the
emulator's module at start).

**Test.** `tests/emu/emutest_gb.ml`, in the suite after the Spectrum's:
the cartridge's entry read, a breakpoint on the VBlank interrupt's
vector (0x0040) hit by `frames`, buttons, a screenshot, the refusals.

**Lesson.** A protocol shared by machines that cannot all do everything
is honest when a request a machine cannot serve fails with the reason:
a caller (the agent) learns from the error what to ask instead.

## 2026-11-27 — The manual's example of emu/1, three tries

**Symptom.** `hello_zx` (the manual's chapter 25) typed a BASIC line and
RUN, read the screen and stopped the machine at a breakpoint. In MyNOS:
no `hello` on the screen, then `keys` answered "paused".

**Causes.** Two, both in the example, not in the emulator. RUN was typed
as soon as the line's ENTER was let go: the ROM was still putting the
line into the program, and the R was lost (the same keys, run apart in
a test without MyNOS, had frames between them). And the breakpoint was on
the ROM's character printer, which the running program called at once:
the machine stopped before the next `keys` arrived, and `keys` on a
paused machine is an error by design.

**Fix.** Ten frames after a line's ENTER (written in the chapter's
section on keys); the breakpoint on the ROM's keyboard scan, which every
interrupt calls, reached by `resume` and `wait`.

**Lesson.** An example in a manual is a test that nobody runs: this one
runs (built by `tools/build-examples.sh`, its output pasted from MyNOS).

## 2026-11-27 — The games go into the emulators' packages

**Symptom.** Each game was a package of its own (`glazx`,
`tobutobugirl`, then `zxsnake`): a package of a few kilobytes of data and
a command, and the emulator to install first. The index grew by one for
each game, and nothing said where a user's own ROMs should go.

**Decision.** (Cesare's.) The games for trying an emulator come with it:
zxspectrum 1.1 brings GLAZX and Snake, camlboy 1.3 Tobu Tobu Girl, in
the package's `games/`; the emulator takes a name without a path
(`zxspectrum snake`) and, when a name is neither a file nor a game,
says which games it has. The packages `glazx` and `tobutobugirl` are
taken out of the repository's index (`zxsnake` was never published).

**Where a user's files go.** Not into `/disk/pkg/<name>`: `pkg install`
removes that directory before unpacking a new version (`pkg.ml`,
`rm_rf dir`), so a ROM copied there would go at the next update. They go
in `/disk/roms/<machine>/` (`zx`, `gb`, `msx`), and each emulator's
README says which proprietary ROMs it can use: none for the Spectrum
(its ROM may be given away), none for the Game Boy (no boot ROM needed),
for the MSX a real BIOS in place of C-BIOS, for MSX-BASIC.

**How.** `tools/pkg-build.sh`'s EXTRA takes `SOURCE:PATH`, a file put
somewhere in the package other than its top (`games/glazx.tap`): the
sources in `third_party` keep their names and the archive has the
names a user types. The suite's sec_emu starts camlboy by its game's
name, so the lookup is tested.

**Lesson.** Before choosing where a user puts files, read what the
package manager does to its own directories.
