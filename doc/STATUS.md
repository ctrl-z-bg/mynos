# MyNOS — Project Status

> The MyNOS project aims at developing a new and different operating
> system, based on high-level languages. MyNOS will be based on the
> OCaml bytecode interpreter. We'd like to explore microkernel
> architecture and new language definition too.

This document has two parts. **Architecture** describes how the system is
built and changes rarely. **Current state** describes what works, what
doesn't, and the known shortcuts. It changes as work progresses.
Actionable work is tracked in beads (`bd list`); this document refers to
issues by ID instead of keeping its own TODO lists. The story of what was
found along the way, bug by bug, is in `doc/JOURNAL.md`.

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
| `mynos-lib/` | User-space library wrapping the native MyNOS syscalls (`include/mynos.h`), and the OCaml library `Mynos` (`ocaml/`) |
| `services/` | User-space servers: `registry`, `keyboard`, `serial`, `fs/memrofs` |
| `mynos-runtime/` | The OCaml 5.5 bytecode runtime for MyNOS: upstream runtime, unchanged, plus a MyNOS `main()` (dev toolchain) |
| `mynos-byterun/` | The OCaml 3.06 bytecode runtime, patched to run on MyNOS (legacy toolchain) |
| `shell/` | The shell: the OCaml toplevel as `init.byte`, module `Shell` (commands), and its RAM disk |
| `mynos.mk` | Toolchain variables for user-space programs (`MYNOS_CC`, `MYNOS_LDFLAGS`) |

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
  (`physicalmem.c`); each process's free linear space is a list of areas
  (`lmemtrack.c`). The kernel allocator is `kmalloc`/`kfree` (`dynalloc.c`).
  The RAM disk is mapped read-only from `0x40400000` in every process, by
  page tables shared between processes (up to 64 MB).
  `externalmem.c` lets the kernel manipulate another process's virtual memory.
  Fork uses copy-on-write.
- **Processes and threads:** a single hardware TSS. Context switching is done in
  software (`softtaskswitch.c`). The scheduler (`sched.c`) is a round robin
  run on the PIT at 100 Hz and whenever a thread blocks; the idle thread
  (process 0, `hlt`) runs only when nothing else is ready. Threads are
  supported (`threads.c`). Processes are created from
  an ELF image (`createProcess` in `process.c`): at boot from the GRUB
  modules, and since 2026 by a process through the native `spawn` call,
  with real `argv`/`envp` on the Linux initial stack. A parent collects a
  child's exit status with `waitpid`/`wait4`. A process that ends gives
  everything back: its IPC objects and semaphores at once, its memory
  (pages, page tables, kernel stacks, `tss`) from the next context switch
  (`reapZombies`: it cannot free the stack it runs on), its descriptor and
  pid when the parent has collected the status. Pids are reused. Exited
  threads leave their `tss` and kernel stack to the next thread.
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
    threads, timer, stats, spawn). See `kernel/syscalls.c` and `mynos-lib`.
  - `int 0x80`: a **Linux-compatible** subset in `kernel/linux_syscalls.c`.
    This lets static Linux i386 programs run unmodified, so MyNOS needs no
    libc of its own: they were built with **dietlibc** originally, with
    **musl** today. In 2008 it covered `exit`, `fork`, `read`, `write`,
    `open`, `close`, `getpid`, `getppid`, `pause`, `times`, `mmap`, `munmap`,
    `llseek`; musl and modern OCaml added `set_thread_area` (TLS), `mmap2`,
    `writev`, `lseek`, `stat64`, `fstat64`, `exit_group`,
    `set_tid_address`, `mprotect`, the signal calls (accepted, no delivery
    yet), `kill`/`tkill`/`tgkill` on oneself, `waitpid`/`wait4`, and the
    clock and sleep calls
    (`kernel/time.c`: PIT ticks plus the CMOS clock read at boot). Unknown
    calls return `-ENOSYS`.

#### services

All services are linked statically against `libmynos` and placed at
`0x40000000`: with musl in the dev toolchain, with dietlibc in the legacy one
(`mynos.mk`).

- `registry`: maps names to ports, like a name server (`mynos_registry.h`).
  It serves one request at a time (2026; it used to start a thread per
  request).
- `keyboard`, `serial`: drivers using `mynos_driverRegister` and port I/O.
- `console`: the console service (2026). Owns the keyboard, edits the line
  being typed and gives lines to programs reading their standard input,
  through `read` in `mynos-lib/src/fileio.c` (`doc/decisions/terminal.md`).
  It replaces `keyboard` in the demo when built.
- `fs/memrofs`: a read-only in-memory filesystem. GRUB loads it as a module
  starting with the `.RAMDISK` magic. The image is built on the host with
  `fs/memrofs/tool/createDisk.c`. Protocol (2026):
  `mynos-lib/include/mynos_memrofs.h`. Programs reach it through `open`,
  `read`, `lseek`, `stat`, `opendir`, ... of `mynos-lib/src/fileio.c`. The
  namespace is flat (names up to 63 characters); `/`, `.` and the empty
  path name its only directory.

#### shell

The shell is the OCaml 5.5 toplevel itself (`shell/main.ml` calls
`Topmain.main`), linked with the `Mynos` library and module `Shell`
(`help`, `ls`, `cat`, `run`, `free`), which is opened at startup. Its RAM
disk holds the toplevel as `init.byte`, a stripped `ocamlrun` for `run`,
the standard library's `.cmi` files and a few programs. Typed lines come
from the console service. `tools/run-demo.sh` boots it.

#### mynos-runtime (OCaml 5.5)

The upstream OCaml 5.5.2 bytecode runtime, **unchanged**: the dev container
builds it with musl (`/opt/ocaml-runtime-musl`), and `mynos-runtime/Makefile`
links it with a short `main()` that picks the bytecode file to open
(`mynos-runtime/main.c`): `ocamlrun prog.byte args…` as on Unix, otherwise
`init.byte` from the RAM disk, otherwise GRUB module 1. Programs start other
programs with `Mynos.spawn "ocamlrun" [| "ocamlrun"; "prog.byte"; … |]`
and `Mynos.wait`. Bytecode is compiled with `ocamlc` 5.5.2.
Effect handlers work; `Domain` and `Thread` need `clone` (mynos-l9h).
Decision and evidence: `doc/decisions/ocaml-runtime.md`.

#### mynos-byterun (OCaml 3.06, legacy)

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
4. `ocamlrun` runs `init.byte` from the RAM disk if there is one (through
   memrofs): with `shell/ramdisk.dsk`, that is the shell. Otherwise, as
   originally, **module 1 is treated as the OCaml bytecode to execute**:
   the kernel serves it as the single file it knows.
5. After that, the kernel runs the idle loop.

---

## Current state

### Build and run

**The original system builds and runs again**, as it did in 2004–2008
(tag `revival-baseline`), **with both the 2008 toolchain and a modern one**:
`tools/build-all.sh [dev|legacy]` then `tools/run-demo.sh`. With the modern
toolchain **MyNOS boots into a shell, the OCaml toplevel**, in about a
second: phrases typed on the keyboard are compiled and run, files of the RAM
disk can be read and programs started (`help ();;`). With the 2008 toolchain
(or `DEMO=2008`) the demo is the original one: a test OCaml program
(`tests/hello`) on `ocamlrun`, the registry, the keyboard and serial
drivers and memrofs, whose built-in test reads a file from the RAM disk over
IPC; typed keys are echoed on screen and sent to the serial port.

- **Toolchains.** Builds run in containers; the host (gcc 15, no multilib,
  x86_64-only dietlibc) is not used.
  - **dev** (`tools/containers/dev`, default): Debian trixie i386, gcc 14.2,
    binutils 2.44, nasm 2.16, **musl** 1.2.5 for user space, **OCaml 5.5.2**
    (compiler, and the runtime built with musl).
  - **legacy** (`tools/containers/legacy`): Debian lenny i386, gcc 4.3.2,
    binutils 2.18, nasm 2.03, dietlibc 0.31, OCaml 3.06 built from source on
    sarge: what the November 2008 commits expect (they add
    `-fno-stack-protector`, gcc ≥ 4.1). Kept to compare behaviour with the
    original.
  - Between the two, the dev toolchain went through dietlibc 0.34 with
    OCaml 3.06 (see the journal); that is where the Linux ABI work began.
- **Tests.** `tools/run-tests.sh` boots the whole system headless and checks
  the console output, which the kernel mirrors to COM2. `tests/abi` checks
  the system call fixes; with the dev toolchain, OCaml tests cover effects,
  the `Mynos` library, files, the console, spawning programs
  (`tests/spawn`) and the shell, typing phrases through QEMU's monitor
  (`tools/type-keys.py`). Both toolchains pass.
- **Booting.** `tools/run-qemu.sh` uses QEMU's multiboot loader, no GRUB.
  Modules are passed in order; module 1 must be the OCaml bytecode.
  `tools/run-demo.sh` passes the standard set. The kernel is built with `-g`,
  so `qemu-system-i386 -s -S` plus `gdb mynos-core/kernel/kernel.elf` gives
  source-level debugging.
- **Bugs hidden by the old compilers**, fixed:
  - Top-level `asm` blocks (interrupt, trap and syscall entry points) had no
    section directive; gcc 4.3 placed `pit_ISR` in `.bss` and `int7_TRAP` in
    `.data`. They now use `.pushsection .text`.
  - `spawnProcess` used `baseaddr` uninitialized when sizing the process
    image (asked for about 1 GB of pages and hung).
  - `switchTo` loaded `cr3` through `%eax` without telling the compiler; with
    position-independent code `%eax` held the base of the static variables.
    The kernel is now built with `-fno-pie` and the asm is fixed.
  - The `mynos-lib` system call wrappers loaded each register in a separate
    `asm` statement; now one statement with proper constraints
    (`mynos-lib/src/syscall.h`).
  - `memrofsd` replied on an uninitialized `sender` instead of the request's
    channel.
  - `pqNElem` called itself forever; `main.c` set `prev` twice instead of
    `next` and `prev`; `_insertBlock` was a non-static `inline` (no external
    definition in C99).
  - `keyboardd` tracked the Alt key only when no other modifier was held
    (`!` vs `&` precedence).
  - `semFree` shared syscall number 9 with `semInit` in the kernel, and the
    library called 10 (`driverRegister`); it is now 13 on both sides.
  - Unknown system calls panicked the kernel; now they fail with `-ENOSYS`
    (Linux) or `MYNOS_ERR_INVALID` (native).
  - The kernel heap allocator (`dynalloc.c`, 2003) could place a block
    across the end of a heap page into a page owned by something else (a
    process's page directory), and freed pages still in use. It also took
    the page after a block ending exactly at a page boundary as its own,
    though `kfree` may have given it back.
  - A channel id from a process was used as a table index unchecked: a
    negative id faulted the kernel.
  - The linear space map (`lmemtrack.c`, 2003) freed a list element while
    its successor still pointed to it, so the list got corrupted after a
    few `munmap` calls; it also could not free an area above the last free
    one ("Problems releasing pages"), and reserved the top pages of the
    address space instead of the stacks.
  - The scheduler gave the idle thread a full time slice in the round
    robin even when other threads were ready: every IPC exchange could wait
    for the next timer tick. The shell started in 32 s; now in 1 s.
  - The RAM size probe in `start.asm` (2002) wrote `0x12345678` into the
    last dword of every megabyte without restoring it, corrupting modules
    that crossed a megabyte boundary. The size now comes from multiboot.
  - The Linux syscall entry did not preserve registers; multiboot modules
    above 4 MB were neither reserved nor mapped; pages allocated on first use
    were not zeroed; the bytecode "file" had no real seek semantics. Found
    while running modern OCaml runtimes (`doc/JOURNAL.md`).
- **OCaml 5.5 and musl (dev toolchain).** User space is built with musl and
  the runtime is OCaml 5.5.2 (`mynos-runtime/`), as decided in
  `doc/decisions/ocaml-runtime.md`. `tools/run-tests.sh` also runs an effect
  handlers test. The legacy toolchain keeps dietlibc and OCaml 3.06.
  - `memrofs/tool/createDisk` is a host tool but was built like a MyNOS
    program; now built with plain gcc.
- **Changes for the modern toolchain:**
  - Programs are linked with `-Wl,-N -Wl,--build-id=none`: modern `ld` puts
    the ELF headers and a build-id note in an extra segment far below
    `0x40000000`, while the kernel loads one contiguous image from there. The
    kernel now also jumps to the ELF entry point instead of a fixed address.
  - dietlibc 0.34 needs three Linux ABI features the 2008 kernel lacked:
    `set_thread_area` (TLS, used for `errno`), `mmap2`, and a Linux-style
    initial stack (`argc`/`argv`/`envp`/`auxv`). They are implemented
    minimally (mynos-51c).
  - Small C fixes: a K&R parameter, missing `<unistd.h>`, `errno`
    declaration, a `return` without value.
  - Remaining warnings are expected: RWX segments (from `-N`) and a few in
    the unchanged OCaml 3.06 runtime sources.
- `mynos-core/boot/` (floppy bootloader) does not assemble with nasm 2.x
  (mynos-s96); the build uses `mynos-core/kernel` directly.

### Known shortcuts and bugs

| Issue | Where | Problem |
|---|---|---|
| mynos-pg9 | `mynos-byterun/src/floats.c` | `frexp()`/`modf()` return 1.0 (legacy 3.06 runtime only; the 5.5 runtime uses musl's libm). |
| mynos-l9h | `mynos-core/kernel/threads.c` | Threads share their creator's TLS; no `clone`, so no OCaml `Thread` or `Domain`. |
| — | `mynos-lib/src/fileio.c` | One read-only flat directory (memrofs); no writable storage (mynos-rf4). |

### Not started

- No OCaml service or driver exists yet: OCaml runs programs and the shell,
  while services and drivers are still in C.
- Nothing on "new language definition".

### Direction

Planned work, in order. Details live in the beads issues.

1. **Revive** (mynos-bo2): boot the kernel in QEMU, then the services, then a
   hello world bytecode. This is the baseline for everything else.
2. **Decide on the OCaml runtime** (mynos-4er): stay on 3.06, or move to 4.14
   or 5.x.
3. **A demonstrable OS with a terminal** (mynos-a2j, done): OCaml bindings
   for the MyNOS API, starting bytecode programs from user space, file I/O
   through memrofs, a console service, and the OCaml toplevel as the shell.
   Then processes that free their memory (mynos-pg6, done). Next: threads
   and domains (mynos-l9h).
4. Later: real external storage, a disk driver and a filesystem as services
   (mynos-rf4); networking (mynos-4f6), a GUI toolkit (mynos-9lr), distinctive
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
- **2026-11-16** — Tagged `revival-baseline`. Added the dev container
  (trixie i386, gcc 14). First build with gcc 14: one error in the kernel,
  four in user space, plus warnings that point at real bugs; all listed in
  mynos-v8s. Closed mynos-aji.
- **2026-11-16** — Ported to the modern toolchain (gcc 14, dietlibc 0.34):
  the whole demo runs the same with `dev` and `legacy`. Fixed several bugs
  the old compilers hid, added `set_thread_area`, `mmap2` and a Linux
  initial stack. `tools/build-all.sh` now defaults to `dev`. Closed
  mynos-v8s; opened mynos-j17, mynos-51c.
- **2026-11-16** — Fixed the Alt key, `semFree` numbering and kernel panics on
  unknown system calls; kernel console mirrored to COM2; added
  `tools/run-tests.sh`, `tests/abi` and `doc/JOURNAL.md`. Closed mynos-jwl,
  mynos-j17.
- **2026-11-16** — OCaml runtime evaluation: 4.14.5 and 5.5.2 built with musl
  run on MyNOS. Fixed four kernel bugs found on the way (register
  preservation, modules above 4 MB, zeroing of new pages, file seeks) and
  added the Linux calls the runtimes need. Proposal written in
  `doc/decisions/ocaml-runtime.md`.
- **2026-11-16** — Implemented the runtime decision: dev toolchain on musl and
  OCaml 5.5.2 (`mynos-runtime/`, `mynos.mk`), effect handler test. Fixed the
  kernel and library bugs musl exposed (modules above 4 MB at boot, RAM disk
  in the linear map, user faults now kill only the process, boot race with
  the registry, TLS for threads and fork children). Closed mynos-3rz,
  mynos-4er, mynos-pg9; opened mynos-l9h, mynos-e1k, mynos-dha.
- **2026-11-16** — Time: CMOS clock at boot, working native sleep
  (`mynos_sleep`), Linux clock and sleep calls; the registry client no longer
  spins. Closed mynos-e1k (its first description was wrong: the timer queue
  did work).
- **2026-11-16** — OCaml bindings: the `Mynos` library and its primitives in
  `mynos-runtime`; an OCaml program reads a file from memrofs over IPC.
  Found and fixed the destructive RAM probe of 2002. Design for the terminal
  proposed in `doc/decisions/terminal.md`. Closed mynos-a2j.1.
- **2026-11-16** — Terminal design accepted (I/O in user space). Console
  service `consoled` and the `read` replacement in `libmynos`: OCaml's
  `read_line` reads the keyboard through IPC. Tests type keys through QEMU's
  monitor. Closed mynos-a2j.3.
- **2026-11-16** — Files: `libmynos` file functions over memrofs, new
  memrofs protocol, `ocamlrun` runs `init.byte` from the RAM disk. Fixed two
  bugs of the kernel heap allocator that corrupted a page directory. Closed
  mynos-nxa.
- **2026-11-16** — Spawn: native call 30 starts a process from an ELF image
  with `argv`/`envp`, `waitpid`/`wait4` collect exit statuses,
  `mynos_spawn` in `libmynos`, `Mynos.spawn`/`Mynos.wait` in OCaml;
  `ocamlrun` passes its arguments on. Fixed a third kernel heap bug and an
  unchecked channel id. Opened mynos-pg6 (processes leak their memory).
  Closed mynos-a2j.2.
- **2026-11-16** — The shell: MyNOS boots into the OCaml 5.5 toplevel, with
  commands to list and print files and run programs. RAM disks larger than
  4 MB, longer file names, `readdir` over memrofs. Rewrote the free list of
  the linear space map (closes mynos-dha) and kept the idle thread out of
  the round robin (startup from 32 s to 1 s). Closed mynos-a2j.4 and the
  epic mynos-a2j.
- **2026-11-16** — Processes free their memory when they end: deferred
  reaping from another context, kernel aliases dropped at creation, pids
  and thread stacks reused. Found and fixed three IPC leaks (connection
  requests, channel ids, registry thread stacks). Twenty programs in a
  row now leave the free memory unchanged (`tests/spawn`). Closed
  mynos-pg6.
