# Decision: OCaml compiled to native code

- **Issues:** mynos-btq.4, in the version 2 line (mynos-btq)
- **Date:** 2026-11-25
- **Status:** deferred by the owner (2026-11-25), after the
  measurements below: with a real processor bytecode is not what is
  slow. The design, its trade-offs and risks are kept here for when it
  is worth it (the browser version, a slow processor).

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
