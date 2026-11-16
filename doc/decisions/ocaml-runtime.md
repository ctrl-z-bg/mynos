# Decision: which OCaml runtime for MyNOS

- **Issue:** mynos-4er
- **Date:** 2026-11-16
- **Status:** proposed
- **Experiment:** `tools/experiments/ocaml-runtime/run.sh`

## Question

MyNOS runs the bytecode interpreter of **OCaml 3.06** (2002). Should it stay
there, move to **4.14** (the long-term support branch, 4.14.5 released in
November 2026) or to **5.x** (5.5.2, with effect handlers and parallel
domains)?

## What we did

Instead of reasoning from release notes, we built both modern runtimes for
MyNOS and ran them on the MyNOS kernel in QEMU:

1. In the dev container (Debian trixie i386), build the regular compiler of
   each version, to compile test programs.
2. Build the bytecode runtime `ocamlrun` as a static Linux i386 binary, linked
   at `0x40000000` for the MyNOS loader, with a 10-line `main` that passes
   the bytecode name (the same trick `mynos-byterun/src/main.c` uses).
3. Boot the kernel with that `ocamlrun` and a bytecode program as modules, and
   read the console. The kernel reports every Linux system call it does not
   implement, which tells exactly what each runtime needs.

## Findings

### dietlibc is a dead end; musl works out of the box

With dietlibc 0.34 neither runtime even configures: its `libm` lacks C99
functions (`fmin`, `isfinite`, `nextafter`, …) and its headers lack
`UINT64_C`. Patching them one by one is endless; it is the same gap that
gives us the fake `frexp`/`modf` in the 3.06 port (mynos-pg9).

With **musl** (Debian's `musl-tools`, i386) both runtimes configure and build
**without any change**. musl speaks the same Linux i386 system call ABI as
dietlibc, so nothing changes for the kernel's design, but it is a complete,
maintained libc meant for static linking.

### Both runtimes run on MyNOS

After a handful of kernel fixes (below), both run the same test program:
`Printf`, a 100 000-element list through the GC, floats. Both also give
**correct floats**, since musl has a real `libm`.

| | 3.06 (today) | 4.14.5 | 5.5.2 |
|---|---|---|---|
| Builds with dietlibc | yes (patched) | no | no |
| Builds with musl | – | yes, unchanged | yes, unchanged |
| Hello, GC, floats on MyNOS | yes (floats wrong) | **yes** | **yes** |
| Effect handlers | – | – | **yes**, no kernel support needed |
| Domains (`Domain.spawn`) | – | – | no: needs `clone` |
| Threads (`Thread`) | no | needs `clone` | needs `clone` |
| Minimum RAM (kernel included) | – | 12 MB | 12 MB |
| `ocamlrun` size (static) | 157 KB | 1.1 MB | 1.7 MB |
| hello bytecode size | 32 KB | 172 KB | 219 KB |

Effect handlers were tested with two cooperative "threads" that alternate
through a `Yield` effect: they work today, entirely in user space.

`Domain.spawn` fails cleanly with `failed to create domain backup thread`:
domains need kernel threads through the Linux `clone` call (120). Real
parallelism would also need SMP support in the kernel, which MyNOS does not
have (single CPU, PIC/PIT, no APIC).

### What the runtimes need from the kernel

Both runtimes and musl together use these Linux system calls. Those in bold
were added or fixed during this evaluation:

- process and memory: `exit`, **`exit_group`**, **`set_tid_address`**,
  `set_thread_area`, `mmap2`, `munmap`, **`mprotect`** (accepted), `brk`
  (-ENOSYS is fine: musl falls back to `mmap`);
- files: `open`, `read`, `close`, **`lseek`**, **`_llseek`**, **`stat64`**,
  **`fstat64`**, `readlink` (-ENOSYS is fine), `statx` (-ENOSYS is fine);
- output: `write`, **`writev`** (musl's stdio writes through it);
- signals, 5.x only: **`sigaltstack`**, **`rt_sigaction`**,
  **`rt_sigprocmask`**, accepted and ignored since MyNOS delivers no signals.

The evaluation also exposed **four kernel bugs**, all fixed (see
`doc/JOURNAL.md`): the Linux syscall entry did not preserve registers as
Linux does; multiboot modules beyond 4 MB were neither reserved nor mapped;
pages allocated on first use were not zeroed; the fake bytecode file had no
real seek semantics.

## Options

**Stay on 3.06.** No work, but the compiler is from 2002, needs its own
container, has wrong floats, and no current OCaml library or tool can be
used. Not an option for a living project.

**4.14.5.** Runs today. Smaller binaries, no signal or thread machinery at
startup. Still maintained, but a branch in maintenance mode: new language
features and most of the ecosystem now target 5.x.

**5.5.2.** Runs today with exactly the same kernel support as 4.14 (plus
three signal calls that are accepted and ignored), and the same memory. It
adds **effect handlers**, which fit MyNOS particularly well: services that
wait on IPC can be written as direct-style code over a small scheduler, all
in OCaml, without kernel threads. Domains become possible later if MyNOS
gains `clone` and, for real parallelism, SMP.

## Recommendation

1. **Move user space from dietlibc to musl.** It unblocks every modern
   runtime and fixes the float functions. Services and `mynos-lib` should
   build with `musl-gcc` the same way (to be verified).
2. **Adopt OCaml 5.5 (bytecode)** as the MyNOS runtime, replacing 3.06 in
   the dev toolchain; keep 3.06 in the legacy container as the historical
   baseline. 4.14 would work too, but costs the same and gives less.
3. **Do not port the MyNOS changes to the old `byterun` forward.** Use the
   upstream runtime unchanged plus a small MyNOS `main` (as in the
   experiment), so future OCaml releases are a version bump.
4. Later, as separate work: Linux `clone` for threads (needed by `Thread` and
   `Domain`), real files through memrofs instead of the single bytecode file
   (mynos-nxa), signal delivery.

Effect handlers are the reason to choose 5.x now rather than later: they are
the natural way to write the OCaml services of mynos-a2j.
