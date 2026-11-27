# The Z80's tests

`packages/retro/z80.ml` checked against (`tests/z80/run.sh`; with `zex`
the long ones too):

- `tests.in`, `tests.expected`: FUSE's tests of its Z80 core (FUSE, the
  Free Unix Spectrum Emulator, GPL 2 or later: its `z80/tests`), 1356
  tests: each instruction's registers, flags (bits 3 and 5 too), MEMPTR,
  Q, T-states and memory. `fuse.ml` runs them as FUSE's `coretest.c` does.
- `zexdoc.com`, `zexall.com`: Frank D. Cringle's Z80 instruction
  exercisers (1994, GPL 2), CP/M programs, the documented flags and all
  of them; from github.com/anotherlin/z80emu (`testfiles`). `cpm.ml`
  runs them with a trap on BDOS.
- `disasm.ml`: `Z80_disasm` on known instructions, and every opcode's
  length (all prefixes) against the bytes the core reads.

Beside them, the Spectrum without MyNOS (the modules of
packages/zxspectrum, compiled with `ocamlc` in the dev container):
`boot.ml` (the ROM's message, PRINT 2+2), `glazx.ml` (GLAZX's tape, its
screens as PNG files), `bench.ml` (frames a second: MYNOS.md's figures).

They run as bytecode in the dev container: no native compiler is there.
The results, and their times, are in doc/JOURNAL.md (2026-11-27).
