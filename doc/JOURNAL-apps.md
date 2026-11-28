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

## 2026-11-27 — The MSX1, from C-BIOS to Westen House

**What.** `packages/msx`: an MSX1 (the TMS9918A, the AY-3-8910, slots,
cartridges and MegaROMs, the keyboard), with C-BIOS 0.29a and Westen
House; mynos-0bj.3. The Z80 and emu/1 were already there.

**How it went.** C-BIOS started at the first try (its logo in Graphics
II, then its "No cartridge found." in text mode), and so did Westen
House, a 48 KB cartridge whose "AB" is 16 KB in (so its first byte is at
0x0000, over the BIOS's page once the game selects it). Its intro, its
isometric rooms and its sprites showed in the first screenshots. What
came from documents and was right at once: the slots as C-BIOS's own
openMSX configuration puts them (0 BIOS and logo, 1 cartridge, 3 RAM),
the VDP's two-byte writes to 0x99, Graphics II's masks from registers 3
and 4. Westen's `input.asm` says which keys it reads (row 8: the arrows
and Space; row 4: K to R; the joystick through the PSG's register 14),
which the README repeats instead of guessing.

**Speed.** 600 frames a second in bytecode on the host (no picture),
about 210 in MyNOS under KVM, 7 without: the picture is drawn whole each
frame (the ULA redraws only the rows that change); 60 are needed.

**The front end once.** zxspectrum's main (window, sound, emu/1's
requests, `--headless`, `--bench`) was copied, made a functor
(`packages/retro/emu_frontend.ml`) over what a machine gives; `msx` is
the machine and a page of glue. zxspectrum keeps its own copy for now.

**Lesson.** For a machine as documented as the MSX, the work is in the
chips; the parts that make it a MyNOS program were already written.

## 2026-11-27 — A breakpoint on the interrupt's entry was never hit

**Symptom.** emu/1's test of the MSX: `break exec 0x0038`, `frames 3`:
three frames ran, no hit, though the interrupt's handler runs every
frame (a watchpoint on JIFFY, which it counts, was hit).

**Diagnosis.** The machine's step took the interrupt (the Z80 pushes the
PC and jumps to 0x0038) and then ran an instruction, in the same step:
the handler's first, at 0x0038, ran without the PC being looked at.

**Cause.** `one` in `msx.ml`, as in `spectrum.ml` (from which it came),
did both. The Spectrum's test had its breakpoint in the ROM's keyboard
scan (0x02BF), called from the handler, so it never showed there.

**Fix.** An accepted interrupt is a step of its own (its T-states only):
the next step is the handler's first instruction, with its check. In
both machines; the Spectrum's emu/1 test passes as before.

**Lesson.** A step that does two things hides the second from whoever
looks between steps: breakpoints, `step 1`, the recorder.

## 2026-11-27 — The PSG one sample in twelve short

**Symptom.** Westen House's music, with the sound on: 339 samples a
frame where 22050 / 59.92 = 368 were due; a sound stream would run dry
and stutter.

**Diagnosis.** The chip is run in ticks of clock / 8 (223,722 a second,
10.15 a sample). A sample was emitted when its ticks reached 10.15, that
is at the eleventh tick, and the count restarted at 0: each sample took
11 ticks, not 10.15.

**Fix.** The part of the tick past the sample starts the next one (its
mean carried with it); and the half tick a frame leaves (3733.5 ticks)
is carried to the next frame too. 368 samples a frame, and the test's
note of 440.4 Hz (register 0 at 254) measures 440.0.

**Lesson.** Where two rates meet (ticks and samples, T-states and
ticks), carry the remainder; a test that counts the samples finds it.

## 2026-11-27 — zxspectrum onto Emu_frontend; msx's window looked at

**What.** zxspectrum's main (window, sound, emu/1's requests,
`--headless`, `--bench`) was the model `Emu_frontend` was copied from;
it now uses it, as msx does: `zxspectrum_main.ml` is the machine (the
ROM, its keys from a window's) and the functor, 419 lines down to 107.
zxspectrum 1.2.

**One difference found.** emu/1's `reset` emptied `info`'s `loaded` on
the Spectrum (its reset drops the tape) and kept it on the MSX (the
cartridge stays in its slot). The functor did the MSX's; a machine now
says which (`reset_keeps_loaded`).

**msx in a window.** Not seen until now (the tests run without one):
`tools/pkg-shots.sh` with a throwaway `shots.sh` started `msx westen`
in the graphical session under QEMU, its pictures taken and QEMU's sound
recorded. 60 frames a second, the picture right, the keys reach the
game; with Page Down, the PSG's music in the WAV file. The music stops
for some seconds after the title (the letter's screen): Westen's own,
the same on the host (`Msx.audio_samples` second by second, the same
keys). Both emulators start with the sound off, as zxspectrum did.

**A short tap lost.** The same look at zxspectrum on the functor:
`zxspectrum snake`, the keys 9 then Enter (QEMU's `sendkey`, 100 ms
down) left the level at 5, once both, once the 9 only; 1.1, the hand
written main, took both in its one try. The code is the same in both:
the machine's key goes down when `Gui`'s `held` has it and up when it
has it no more, and frames run only at the window's ticks. When the
window is late, the press and the release wait together in its queue,
are handled one after the other with no tick between, and the machine
never sees the key; 1.1 had been lucky. **Fix.** A key that goes down
stays down for two of the machine's frames at least, as emu/1's `keys`
holds one: 9, 3, 7 and Enter then each reached Snake, and a space
Westen. msx 1.1 for it.

**Lesson.** A copy made generic should take the original back soon:
two copies drift, and the drift (here, `reset`) is found only by
putting them side by side. And a window's keys are events, not a state
sampled at the machine's pace: an event shorter than a frame must still
make a frame.

## 2026-11-27 — bench: measuring with a clock of 10 ms, on 31-bit integers

**What.** A benchmark package (mynos-dbt): the processor through OCaml,
the system, the network, the drawing; each measure in its unit and as a
score against a reference run under KVM.

**The clock.** `Mynos.uptime` is `clock_gettime(CLOCK_MONOTONIC)`, and
MyNOS's answers in the PIT's ticks of 10 ms (`time_now` in
`kernel/time.c`): a measure of 50 ms could be off by a fifth. Each
measure waits for the clock to move (a tick's edge), runs a number of
operations grown until they take 0.3 s, three times, the median kept.
Two runs in a row then agree within 6%, most measures within 2%.

**A crash in the sieve.** The first run in MyNOS ended at the first
measure: `process 19 killed: invalid memory access`. The sieve marks
multiples from `i * i`; on the i386 OCaml's integers have 31 bits, and
for `i` above 46340 `i * i` wraps to a negative number: `while !j <= n`
held, and `Bytes.unsafe_set` wrote far before the buffer. On a 64-bit
host it never shows. **Fix**: `i * i` only while `i <= n / i`. The same
line of thought for the pseudo-random generator, whose multiplier did
not even compile (1103515245 is above the 31-bit range): 69069.

**The window went blank while measuring.** A measure ran inside `Gui`'s
frame, after `Gui` had filled the window's buffer with the background
and before the program drew: the buffer is shared with displayd, which
shows it as it is when it composes, so a measure of a second showed a
blank window. **Fix**: draw first, measure at the end of the frame.

**Frames.** `Display.damage` is answered before displayd composes, so a
loop of damages could seem to measure only messages; but displayd is one
thread, and the next damage waits for the last composition: about
17,000 frames of 270 x 200 a second under KVM, the composition's rate.

**Found in the system.** Writing 1 MB to `/disk` takes 1.6 s (0.63
MB/s) when reading it back takes 3 ms (mynos-ro7); fetching a 13 KB file
over HTTP from the host takes 1.5 s every time (mynos-yxl).

**Lesson.** On the i386, an OCaml program's arithmetic is 31-bit: a
product of two numbers above 46340 must be guarded, and code that works
on the host proves nothing about it.

## 2026-11-27 — The MSX2: the VDP a line at a time, then the V9938

**What.** `msx` 2.0 (mynos-ccb): an MSX2 beside the MSX1, `msx2` (or
`msx --msx2`), with C-BIOS's MSX2 ROMs. The test game is the owner's
Robotron (SCREEN 4, sprites of mode 2), not in the package yet.

**The picture a line at a time.** MSX2 games split the screen with the
line interrupt, so the VDP could no longer draw its picture once, at the
frame's end, from the VRAM as it was then. The machine now calls
`Vdp.line` at each of the frame's 262 lines (228 T-states each), the
picture's lines drawn with the registers and VRAM of that moment, the
sprites' status found as each line goes, the frame's interrupt at the
picture's end (line 192, or 212). The MSX1's pictures were checked
unchanged (Westen's) and a test changes the backdrop at line 100.

**And the suite failed.** Lane c's emu-msx stopped after `regs`: the
test asks the headless emulator for 600 frames, which used to cost no
drawing (the picture was made only for a screenshot) and now drew 600
pictures, longer than the test's wait. **Fix**: `Vdp.set_draw`: without
a window the lines only find their sprites' status, and `pixels` draws
the whole picture when asked, the status left alone; `Emu_frontend`'s
headless mode turns the drawing off.

**The V9938.** In the same `vdp.ml`, behind a flag: 128 KB of VRAM, the
palette (port 0x9A), registers 0-46 (port 0x9B too) and status 0-9,
SCREEN 4 to 8 and 80 columns, sprites of mode 2 (eight a line, a colour
a line; CC or's a sprite's colour with the one before, IC keeps it out
of collisions), register 23's scroll, register 19's line interrupt, and
a command engine (`vdp_cmd.ml`) whose commands are done at once. The
machine: slot 3 expanded (0xFFFF, read back complemented), the SUB-ROM
in 3-0, a mapper of 512 KB in 3-2, the RP5C01 clock, as openMSX's
`C-BIOS_MSX2` configuration lays them out.

**C-BIOS stuck, blue.** C-BIOS's MSX2 and Robotron both showed a blue
screen for ever. The PC went round 0x11C2-0x11C8 in the SUB-ROM
(page 0 in slot 3-0): status register 2 read, bit 0, CE, until clear.
A command was still running: C-BIOS writes its text with HMMC, whose
first byte is register 44 *before* the command starts; the engine
waited for that byte from the CPU too, one more than C-BIOS sends.
**Fix**: HMMC and LMMC take register 44 as their first unit. C-BIOS's
message and Robotron then showed, and openMSX's pictures of the same
frames (taken on the host with the owner's msxdsl `run --screenshot`)
match them, but for the blinking and the colour-cycling border.

**Speed.** Under KVM, 164 frames a second for the MSX2 (Robotron), 212
for the MSX1 (as before); on the host in bytecode 157 and 209.

**Lesson.** A change of when the work is done (each line instead of on
demand) is a change of how much: the headless user that asked for 600
frames found it first. And a protocol's first step can be a register
written before the go: read the chip's sequence, not just its list of
commands.

## 2026-11-28 — nettools: SSH in OCaml, and the console's ends

**Goal.** A package of network commands: `ssh` and `sshd` that work with
OpenSSH, `ssh-keygen`, and small tools (`nc`, `dig`, `sntp`, `whois`,
`portscan`), without touching the system: a package is bytecode, so the
cryptography is OCaml too (netd's mbedTLS is out of reach, and has no
Ed25519).

**Design.** One algorithm of each kind, OpenSSH's first since 2014:
curve25519-sha256 with strict kex (Terrapin), ssh-ed25519,
chacha20-poly1305@openssh.com. MyNOS's ints are 31 bits on i386, the
trap bench fell into, so: SHA-256 and SHA-512 on Int32 and Int64;
ChaCha20, the hot one, on halves of 16 bits in plain ints (nothing
boxed); Poly1305 and the curves on Num's big integers, whose C is in the
runtime already. SHA-2's constants are computed (cube and square roots
of the primes, with Num) instead of copied. The protocol is apart from
MyNOS (the transport takes two functions, read and write), so the client
and the server could be tried against each other on the host, and the
server against the host's OpenSSH, before MyNOS saw them.

**Results.** The vectors (made by the host's OpenSSH and OpenSSL with
throwaway keys, and RFC 8439's) passed the first time, on the host and
in MyNOS (`ssh-keygen --selftest`); OpenSSH 10.2 logged in to sshd with
a key and with a password, ran commands with their exit status, and a
shell with a terminal; `ssh-keygen -y` read our key files and we read
its. Under KVM an X25519 takes 2.7 ms and a signature 7.

**Bugs on the way, all of the edges.**
- The host's test hung: the client waited for the reply to `exec` and
  threw away what came before it, the command's output (a fast command
  answers before the reply). The reply is now waited for with the rest.
- In the same test, the server's backend wrote from the connection's
  reader thread: with the window full, the reader waited for an adjust
  that only it could read. A session's output must come from another
  thread (in MyNOS, the console's).
- One run in ten of the same test hung, with 3 MB going both ways. Each
  end's reader, given data, sent a window adjust; sending took the
  transport's lock, held by that end's writer, itself stuck in a write
  because the other end was not reading: both readers were waiting to
  write. Waiting by window alone was not enough. Now nothing that sends
  waits: packets go into a queue that a thread of the transport writes
  out; a rekey the peer asks for puts its own packets first and holds
  the others' until NEWKEYS. Then, also intermittent, EPIPE: a closed
  connection's writer outlived it and shut down its descriptor, by then
  the next connection's. The writer is waited for when a connection ends.
- After `exit` from a session, the first letters of the next command
  were lost. The client's keyboard thread was still in a read when the
  program ended; the console kept that read and gave it the next keys
  (mynos-3j9). `ssh` and `nc` now read only when `select` says there is
  input.
- `ssh HOST 'cat > file' < binary` hung. The console's end of input was
  given once, as a Ctrl-D is, and `cat`'s last line, without a newline,
  used it up: the read after waited for ever. An SSH channel's EOF is
  final: every read gets it. And without a terminal Ctrl-C is a byte
  like any other: a `\003` in the data used to end the program.
- The password showed as it was typed: consoled edits a line with the
  echo on whatever the mode says (mynos-tk0z). `ssh` reads it in raw
  mode, a key at a time.
- A client that sent nothing kept a connection for ever: two minutes to
  log in, then no limit.

**Lesson.** The middle (the cryptography, the protocol) was right at
once, because it had vectors and a real peer to answer to. The bugs were
at the ends, where data meets a thread or a console: who reads, who is
left waiting, how often an end is said. A reader that can block on a
write is a deadlock waiting for full buffers: run a test of this kind
tens of times, not once.
