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
