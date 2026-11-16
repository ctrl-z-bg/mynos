# MyNOS — Project Status

> The MyNOS project aims at developing a new and different operating
> system, based on high-level languages. MyNOS will be based on the
> OCaml bytecode interpreter. We'd like to explore microkernel
> architecture and new language definition too.

This document has two parts. **Architecture** describes how the system is
built and changes rarely. **Current state** describes what works, what
doesn't, and the known shortcuts. It changes as work progresses.
Actionable work is tracked in beads (`bd list`); this document refers to
issues by ID instead of keeping its own TODO lists.

Last updated: 2026-11-16

---

## Architecture

### The idea

A minimal microkernel written in C and assembly for 32-bit x86, and on top of it
user programs written in OCaml, run by the OCaml bytecode interpreter
(`ocamlrun`) ported to run as an ordinary user process. Safety and abstraction
were meant to come from the language, not only from the hardware. Everything
else (drivers, filesystem, services) runs outside the kernel as processes
talking through IPC.

### Components

| Directory | What it is |
|---|---|
| `mynos-core/` | The microkernel: boot, memory, processes, threads, scheduler, IPC, syscalls |
| `mynos-lib/` | User-space library wrapping the native MyNOS syscalls (`include/mynos.h`) |
| `services/` | User-space servers: `registry`, `keyboard`, `serial`, `fs/memrofs` |
| `mynos-byterun/` | The OCaml 3.06 bytecode runtime, patched to run on MyNOS |

#### mynos-core — the microkernel

- **Boot:** multiboot compliant and loaded by GRUB. `boot/` contains a
  separate floppy-disk bootloader (`boot.asm`, `kernel.asm`) that is not used
  when booting with GRUB. `kernel/start.asm` enables paging and jumps to
  `mynos_main` (`kernel/main.c`). The kernel is linked at `0x200000`.
- **Memory** (`kernel/mem/`): each process has its own page directory. The
  first 1 GB of linear space is the kernel and is shared by every process.
  User code starts at 1 GB (`0x40000000`). The last page directory entries map
  the current process's page tables so the kernel can edit them (full layout in
  `mynos-core/doc/MyNOS-note.txt`). Physical pages are tracked with a bitmap
  (`physicalmem.c`). The kernel allocator is `kmalloc`/`kfree` (`dynalloc.c`).
  `externalmem.c` lets the kernel manipulate another process's virtual memory.
  Fork uses copy-on-write.
- **Processes and threads:** a single hardware TSS. Context switching is done in
  software (`softtaskswitch.c`). The scheduler (`sched.c`) runs on the PIT at
  100 Hz. Threads are supported (`threads.c`).
- **Synchronization:** kernel semaphores (`sem.c`). Every thread has a private
  semaphore.
- **IPC** (`kernel/ipc/`): **ports** are used to establish connections, and
  bidirectional **channels** carry messages. Short messages (≤ 8 bytes) are
  copied; larger ones can be shared (`MYNOS_IPC_SHARED`). Port 0 is reserved
  for the registry.
- **Drivers in user space:** a process calls `mynos_driverRegister(name, irq, …)`
  and gets a semaphore. The kernel signals it (`V`) on every interrupt of that
  IRQ.
- **Two syscall interfaces:**
  - `int 0x90`: the native MyNOS API (send/recv, ports, semaphores, IRQs,
    threads, timer, stats). See `kernel/syscalls.c` and `mynos-lib`.
  - `int 0x80`: a small **Linux-compatible** subset (`exit`, `fork`, `read`,
    `write`, `open`, `close`, `getpid`, `getppid`, `pause`, `times`, `mmap`,
    `munmap`, `llseek`) in `kernel/linux_syscalls.c`. This lets programs built
    with **dietlibc** for Linux, statically linked, run unmodified, so MyNOS
    needs no libc of its own.

#### services

All services are built with `diet gcc`, linked statically against `libmynos`
and placed at `0x40000000`.

- `registry`: maps names to ports, like a name server (`mynos_registry.h`).
- `keyboard`, `serial`: drivers using `mynos_driverRegister` and port I/O.
- `fs/memrofs`: a read-only in-memory filesystem. GRUB loads it as a module
  starting with the `.RAMDISK` magic. The image is built on the host with
  `fs/memrofs/tool/createDisk.c`.

#### mynos-byterun

This is the standard `ocamlrun` from OCaml 3.06 (imported in October 2002). It is
built with `diet gcc` and linked statically at `0x40000000`. Under `MYNOS`:

- `main()` forces `argv` to `"mynos_bytecode"`;
- `getenv()` always returns `NULL`;
- dynamic loading of C primitives is disabled;
- `frexp()` and `modf()` are stubs (see mynos-pg9).

### Boot flow

1. GRUB loads `kernel.elf` plus a list of modules.
2. The kernel initializes memory, the PIC, the IDT, the PIT, semaphores and the
   services registry.
3. Every module that is an ELF file is started as a process: the services and
   `ocamlrun`.
4. **Module 1 is treated as the OCaml bytecode to execute.** When `ocamlrun`
   opens and reads its "file", the Linux `read` reads from that module.
5. After that, the kernel runs the idle loop.

---

## Current state

### Build and run

**The original system builds and runs again**, as it did in 2004–2008
(tag `revival-baseline`):
`tools/build-all.sh` then `tools/run-demo.sh`. In QEMU it boots the kernel,
runs a test OCaml program (`tests/hello`) on `ocamlrun`, starts the registry,
the keyboard and serial drivers and memrofs, and memrofs's built-in test reads
a file from the RAM disk over IPC. Typed keys are echoed on screen and sent to
the serial port.

- **Toolchain.** The November 2008 commits add `-fno-stack-protector`, so
  the last original state targets gcc ≥ 4.1 (gcc 4.3, Ubuntu 8.10 era). The
  host (gcc 15, no multilib, x86_64-only dietlibc) cannot build it. Builds run
  in the **legacy container** (`tools/containers/legacy`): Debian lenny i386
  with gcc 4.3.2, binutils 2.18, nasm 2.03, dietlibc 0.31, plus OCaml 3.06
  built from source. A container with a modern toolchain is planned
  (mynos-aji).
- **Booting.** `tools/run-qemu.sh` uses QEMU's multiboot loader, no GRUB.
  Modules are passed in order; module 1 must be the OCaml bytecode.
  `tools/run-demo.sh` passes the standard set.
- **Fixes needed to get here** (bugs hidden by the old compilers):
  - Top-level `asm` blocks (interrupt, trap and syscall entry points) had no
    section directive; gcc 4.3 placed `pit_ISR` in `.bss` and `int7_TRAP` in
    `.data`, so the first timer tick hit an invalid opcode. They now use
    `.pushsection .text`.
  - `spawnProcess` (`process.c`) used `baseaddr` uninitialized when sizing
    the process image; with gcc 4.3 it asked for about 1 GB of pages and
    hung. Now initialized to 0.
  - `memrofs/tool/createDisk` is a host tool but was built like a MyNOS
    program (dietlibc, libmynos, `0x40000000`) and crashed on Linux. Now
    built with plain gcc.
- `mynos-core/boot/` (floppy bootloader) does not assemble with nasm 2.x
  (mynos-s96); the build uses `mynos-core/kernel` directly.

### Known shortcuts and bugs

| Issue | Where | Problem |
|---|---|---|
| mynos-nxa | `mynos-core/kernel/linux_syscalls.c` | `open()` always returns 5; `read()` copies from GRUB module 1 whatever the fd. memrofs is not used by the runtime. |
| mynos-pg9 | `mynos-byterun/src/floats.c` | `frexp()`/`modf()` return 1.0. |
| mynos-jwl | `mynos-core/kernel/syscalls.c` | Syscall id 9 is used for both semInit and semFree, so semFree is never reached. |

### Not started

- No OCaml service or driver exists yet; the only OCaml code is the test
  program `tests/hello/hello.ml`. The "OS based on a high-level language"
  part never went beyond running the bytecode interpreter.
- Nothing on "new language definition".

### Direction

Planned work, in order. Details live in the beads issues.

1. **Revive** (mynos-bo2): boot the kernel in QEMU, then the services, then a
   hello world bytecode. This is the baseline for everything else.
2. **Decide on the OCaml runtime** (mynos-4er): stay on 3.06, or move to 4.14
   or 5.x.
3. **A demonstrable OS with a terminal** (mynos-a2j): OCaml bindings for the
   MyNOS API, starting bytecode programs from user space, file I/O through
   memrofs, a console service, and the OCaml toplevel as the shell.
4. Later: networking (mynos-4f6), a GUI toolkit (mynos-9lr), distinctive
   applications (mynos-3h1).

Side task: archive the old SourceForge site (mynos-db2).

### History

- 2002-02 → 2004-12: active development. The busiest period is June–November
  2002; the IPC was completed in September 2004. 191 commits by Cesare
  Zavattari (bradstallion), 8 by Tommaso Schiavinotto (Teudimundo), 6 by
  Alessandro Tommasi (aaaaale). The project was hosted on SourceForge under
  GPL v2.
- 2005, 2008: a few minor commits. The last original commit (2008-11-25) is
  tagged `legacy-2008`.
- Originally four CVS modules, later four separate git repositories,
  merged here into one repository. The content and history were verified
  as equivalent on 2026-11-15.

---

## Work log

- **2026-11-16** — Added `.gitignore`: beads, files generated for agents, editor
  backups and personal notes are kept out of git. Wrote this document after a
  full read of the codebase. Opened mynos-bo2, mynos-nxa, mynos-pg9, mynos-jwl.
  Added `README.md`. Planned the roadmap and opened the issues listed under
  "Direction".
- **2026-11-16** — Legacy build container and `tools/run-qemu.sh`. The kernel
  builds with the 2008 toolchain and boots in QEMU after fixing the section of
  top-level asm blocks. Closed mynos-bo2.1, mynos-o7z; opened mynos-aji,
  mynos-s96.
- **2026-11-16** — Whole system built in the legacy container and running in
  QEMU: OCaml bytecode, registry, keyboard, serial, memrofs. Fixed an
  uninitialized variable in `spawnProcess` and made `createDisk` a host tool.
  Added `tools/build-all.sh`, `tools/run-demo.sh` and `tests/`. Closed
  mynos-bo2 (with bo2.2, bo2.3); opened mynos-tuy.
