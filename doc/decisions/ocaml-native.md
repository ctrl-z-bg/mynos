# Decision: OCaml compiled to native code

- **Issues:** mynos-btq.4, in the version 2 line (mynos-btq)
- **Date:** 2026-11-25
- **Status:** deferred by the owner (2026-11-25), after the
  measurements below: with a real processor bytecode is not what is
  slow. Taken up again and accepted (the owner, 2026-11-28) for the
  slow processor it was kept for: the Raspberry Pi 400, where the
  emulators run in bytecode below their machines' speed. First on
  AArch64; the prototype's numbers are in "The Pi 400" below.

## The design proposed

- **64 bits only.** OCaml 5 compiles to native code for 64-bit
  processors (amd64, arm64, riscv64...), not for the i386, where
  everything stays bytecode.
- **The toolchain.** The `dev-x86_64` container gets a second OCaml
  5.5.2 built with its native compiler (`ocamlopt`) for musl; the native
  runtime (`libasmrun`) is linked statically with `libmynos` and MyNOS's
  stubs (`Mynos`, `Gfx`, unix, threads), as `ocamlrun` is today. A native
  program is a static ELF at `0x40000000`, as a C program is.
- **One source.** The same sources build as bytecode (i386) or native
  (x86-64); the 64-bit RAM disk holds native executables in place of the
  chosen `.byte` files, and `init.rc` starts them by the same logical
  name. What is compiled inside MyNOS (`ocamlc`, the toplevel, the agent,
  packages) stays bytecode: no `ocamlopt` inside MyNOS.
- **Which programs:** the busiest, chosen by measurement.

## Trade-offs and risks

- **Two kinds of OCaml program.** A native service is not run by
  `ocamlrun`: `Mynos.processes` reports it as native, and the System
  window and `ps` would call it C. They need another way to know the
  language (a note in the ELF, or a list).
- **Signals.** The native runtime detects a stack overflow with a
  SIGSEGV handler on an alternate stack; MyNOS has no signals: a native
  program's stack overflow is a crash, not the exception `Stack_overflow`
  that bytecode raises.
- **Fibers' stacks.** OCaml 5's effects allocate fiber stacks with
  `mmap`, and guard pages with `mprotect`: MyNOS's `mprotect` accepts and
  does nothing, so a fiber that overflows writes into the next mapping.
- **Size.** A native program carries its runtime (about 1 MB) and its
  code is larger than bytecode: the RAM disk grows, and pages are not
  shared between processes (MyNOS has no shared libraries).
- **The debugging story.** Bytecode's backtraces and the recorder's view
  of `ocamlrun` change: a native crash is a page fault at an address,
  to be read against the ELF's symbols.
- **Two builds to keep green.** Every service in both forms, the suite
  on both: more build time, and a failure that shows on one only.
- **Linking.** Native programs link the C stubs at build time: a new
  primitive needs the program rebuilt (bytecode finds it by name).

## The measurements (2026-11-25, x86-64, all bytecode)

Workloads run as scripts by `sh` (`source`), timed by MyNOS's clock;
`tests/cpu/ticks.byte` gives each process's CPU ticks. QEMU emulating
the processor (TCG, as the suite and the browser version run) and with
KVM (the real processor):

| Workload | TCG | KVM | Where the time goes |
|---|---|---|---|
| 5 starts of `hello.byte` | 0.34 s | 0.02 s | `sh`, `memrofsd` |
| `ls -l /`, `ps`, `cat` | 0.30 s | 0.03 s | `sh` |
| 3 compilations with `ocamlc` | 1.17 s | 0.11 s | `ocamlc` |
| 1.5 MB copied to `/disk`, read twice, copied in `/tmp` | 2.55 s | 11.5 s | `ata` 42% (TCG), 98% (KVM); `fatfs` 34% (TCG) |

And in the suite, and in interactive use under TCG, the processor is
idle 75-95% of the time: its time is waiting, not computing.

## What they say

- **With a real processor, bytecode is not the bottleneck**: starting
  programs, the shell, compiling are already tens of milliseconds.
  Native code would be felt under emulation (TCG, v86 in the browser)
  and on slow processors.
- **The disk driver is**, and not for its language: `ata` waits for each
  sector by reading the status port in a loop (and `delay ()` reads it
  four times more); under KVM every port read leaves the virtual
  machine, so 1.5 MB cost millions of exits. A native `ata` would wait
  the same; waiting for the disk's interrupt would not.
- **The suite would not be faster**: its time is waits.

## Next

Deferred (the owner, 2026-11-25); the disk driver's waiting fixed
instead (mynos-9rw: the interrupt, not a loop on the status port). A
table of bytecode against native times needs the prototype: the
toolchain above and the services built with it.

## The Pi 400 (2026-11-28, AArch64)

On the Pi 400 (Cortex-A72, 1.8 GHz, measured) the MSX ran below 10
frames a second in its window, the Spectrum at 20: bytecode, at about
an eighth of the reference PC's speed (the PC's own bytecode, not
KVM's: the MSX1's bench 197 frames a second on the PC, 24 on the Pi).

**The prototype.** A cross `ocamlopt` 5.5.2 for aarch64-linux-musl
(built in a container from the dev-aarch64 one: the build host's OCaml
must have its native compiler; `STRIP`, `AS` and `ASPP` given to
`configure` as the cross binutils', or the build strips a target
binary with the host's strip and looks for `aarch64-linux-musl-as`).
Programs are linked as MyNOS's C ones (static, at 0x40000000) with
`-cclib "-lasmrun -L.../mynos-lib/lib -lmynos"`. The emulators' modules
(the Z80, the Spectrum's ULA, the MSX's VDP, PSG and cartridges) built
unchanged, without MyNOS's libraries (`tests/z80/bench.ml`, an MSX
bench of the same shape).

**The kernel had to change once.** OCaml 5's arm64 runtime marks the
frames its GC has scanned with bit 60 of their return addresses, which
works because Linux ignores the top byte of user addresses (TBI): MyNOS
now does too (TCR_EL1.TBI0; doc/JOURNAL-next.md, 2026-11-28).

| on the Pi 400 | native | bytecode | |
|---|---|---|---|
| the Spectrum's bench (GLAZX), frames a second (50 needed) | 724 | 40 | 18x |
| the MSX1's (Westen House), frames a second (60 needed) | 410 | 24 | 17x |
| 35 M integer additions | 0.028 s | 0.600 s | 21x |
| 1 M float array updates | 0.006 s | 0.112 s | 19x |
| 1 M square roots | 0.016 s | 0.118 s | 7x |
| 1 M three-element lists | 0.085 s | 0.288 s | 3.4x |
| exceptions, system calls, large allocations | about the same | | |

**What it says.** The emulators gain what a language change can give,
and their machines' speed with room to spare; what the system does
(calls, pages) gains nothing. The steps from here: the toolchain in the
dev-aarch64 container, the native `Mynos` and `Gfx` libraries with
MyNOS's stubs, then the emulators built native (packages: per
architecture, bytecode where there is no native build; agreed with the
applications' session).

## ocamlopt inside MyNOS (2026-11-28, btq.4.1)

The owner asked whether the compiler itself could run in MyNOS (to
optimise on the fly), and to drop it if it were a bloodbath. It is not:
**it works, end to end**, on QEMU and on the Pi 400: `ocamlopt` compiles
`hello.ml` inside MyNOS, runs the assembler and the linker, and the
program it makes runs.

**The pieces.**
- **The assembler and the linker**: GNU binutils 2.44 (`as`, `ld`),
  cross-built for aarch64-linux-musl and linked with libmynos (through a
  `musl-gcc` wrapper: binutils' configure empties `LIBS`, and without
  libmynos their file functions were musl's raw system calls, which MyNOS
  does not serve). They built at once (with `-D_LARGEFILE64_SOURCE`) and
  run unchanged: a C program and an OCaml one assembled and linked in
  MyNOS. A few calls answer ENOSYS harmlessly (getrlimit, prlimit64,
  fcntl, umask, fchmodat).
- **Starting them**: `system(3)` in libmynos (MyNOS has no `execve`):
  `sh -c`, spawned and waited for; OCaml's `Sys.command` goes through it.
- **The compiler**: the cross tree's `utils/config.generated.ml` edited
  for MyNOS (`asm` /disk/bu/as; `mkexe` `ld` itself with the start files;
  `native_c_libraries` libmynosrt, libmynos, libgcc, libc and the end
  files), the standard library found through `OCAMLLIB`. As bytecode
  (`ocamlrun ocamlopt.byte`, 4.6 MB) or native (`ocamlopt.opt`, linked
  from the target's compiler-libs, 11 MB).
- **The kernel**: a program could be 4 MB at most (the RAM disk was
  mapped right after it, at 0x40400000); the 64-bit kernels now take
  256 MB and map the RAM disk at 256 GB.
- **On the card**: the native standard library without its debugging
  sections, 10 MB; binutils and the C libraries, 13 MB.

**The time, for a hello world** (compiled, assembled, linked):

| | QEMU (TCG) | Pi 400 |
|---|---|---|
| all, the program written to /disk | 23 s | 29.6 s |
| all, the program written to /tmp | 17.9 s | 10.3 s |
| compiling and assembling only (`-S -c`) | 2.3 s | 3.1 s |
| `as` alone | 0.5 s | |

The Pi being slower than an emulator says where the time goes: not in
computing (the bytecode and the native compiler take the same time) but
in **input and output in small pieces**. musl's `FILE`s have 1 KB
buffers, and in MyNOS each read or write of a file is an IPC request to
its service (and, on the SD card, a command to a polled controller): a
C test writing 2.7 MB in 100-byte `fwrite`s takes 1.34 s to /tmp and
8.6 s to /disk with musl's buffer, 0.12 s and 0.61 s with a 1 MB one.
GNU ld reads archives in pieces with seeks between them, and writes its
output so. Each `system()` also starts `ocamlrun` and the shell.

**What would make it fast**, none of it done yet:
1. Bigger stdio buffers in libmynos (it already replaces musl's
   `__stdio_read` and `__stdio_write`: a larger buffer for files, freed
   in its `__stdio_close`): every C program gains, ld most.
2. `system()` starting simple commands directly (their words parsed,
   quotes honoured) instead of through the shell.
3. A cache in fatfs, or the toolchain's libraries in the RAM disk.

The expected result is a few seconds for a small program, which makes
compiling a hot module in MyNOS usable. **Verdict:** feasible; what is
slow is MyNOS's file I/O granularity, which C programs in general
suffer from as well.
