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

Last updated: 2026-11-18

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
| `services/` | User-space servers: `registry`, `console`, `keyboard`, `serial`, `fs/memrofs`; in OCaml: `tmpfs`, `ata` (disk driver), `fatfs` |
| `mynos-runtime/` | The OCaml 5.5 bytecode runtime for MyNOS: upstream runtime, unchanged, plus a MyNOS `main()` (dev toolchain) |
| `init/` | `init`, in OCaml: starts the services and the shell listed in `init.rc` |
| `shell/` | The shell: the OCaml toplevel (`shell.byte`) and module `Shell` (commands) |
| `system/` | The system RAM disk: `init`, `init.rc`, services, the shell, interfaces, programs |
| `editor/` | `edit`, the text editor, in OCaml on Notty |
| `sh/` | `sh`, a bash-like command shell, in OCaml |
| `third_party/` | kilo (C editor), Notty and uutf (OCaml terminal UI), lwIP (TCP/IP), mbedTLS (TLS), Mozilla's certificate authorities, with their licenses and MyNOS changes |
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
  (`lmemtrack.c`). The kernel allocator is `kmalloc`/`kfree` (`dynalloc.c`):
  size classes from 32 bytes to 2 KB, whole pages above, a header with a
  magic number on every block, blocks given zeroed; `HEAP_CHECK` adds
  poisoning of freed blocks and a count of blocks in use by caller.
  Pointers from processes are checked by `__mem_userArea` (user pages of
  the caller, never the kernel's) before the kernel reads or writes them.
  The RAM disk is mapped read-only from `0x40400000` in every process, by
  page tables shared between processes (up to 64 MB).
  `externalmem.c` lets the kernel manipulate another process's virtual memory.
  Fork uses copy-on-write.
- **Processes and threads:** a single hardware TSS. Context switching is done in
  software (`softtaskswitch.c`). The scheduler (`sched.c`) is a round robin
  run on the PIT at 100 Hz and whenever a thread blocks; the idle thread
  (process 0, `hlt`) runs only when nothing else is ready. Threads are
  supported (`threads.c`): MyNOS's native ones (`mynos_threadCreate`,
  sharing their creator's TLS) and, since 2026, Linux threads through
  `clone`, each with its own TLS, with `futex` behind the C library's
  pthreads (`lthreads.c`); OCaml 5's domains run on them. All threads share
  one CPU (SMP: mynos-awn). Processes are created from
  an ELF image (`createProcess` in `process.c`): at boot from the GRUB
  modules, and since 2026 by a process through the native `spawn` call,
  with real `argv`/`envp` on the Linux initial stack. A parent collects a
  child's exit status with `waitpid`/`wait4`. A process that ends gives
  everything back: its IPC objects and semaphores at once, its memory
  (pages, page tables, kernel stacks, `tss`) from the next context switch
  (`reapZombies`: it cannot free the stack it runs on), its descriptor and
  pid when the parent has collected the status. Slots are reused, pids
  never (a pid carries a generation). Exited
  threads leave their `tss` and kernel stack to the next thread.
- **Synchronization:** kernel semaphores (`sem.c`). Every thread has a private
  semaphore.
- **IPC** (`kernel/ipc/`): **ports** are used to establish connections, and
  bidirectional **channels** carry messages; each end of a channel has its
  own id (the listener's even, the connector's the next one), so two threads
  of one process can talk over a channel. Short messages (≤ 8 bytes) are
  copied; longer ones are mapped into the receiver page by page,
  copy-on-write (`MYNOS_IPC_SHARED`: shared, at any size). Port 0 is
  reserved for the registry.
- **Typed IPC** (`mynos-lib/ocaml/wire.ml`, `ipc.ml`;
  `doc/decisions/typed-ipc.md`): above the bytes, a service's protocol is an
  OCaml GADT of requests indexed by the type of their reply, and
  `Ipc.Make (Protocol)` gives a `call` whose result has the request's type
  and a `serve` loop. Values travel in a small format of our own (`Wire`:
  zigzag LEB128 ints, length-prefixed strings, variants as case numbers),
  checked when read: a malformed request gets an error reply, never a
  crash. Services are then callable from the toplevel
  (`Block.call d (Block.Read (0, 1))`). Every service speaks it: block/1,
  net/1, llm/1, display/1, fs/1 (the file services), registry/1 and
  console/1 (the last two, C structs since 2002, moved on 2026-11-18). C
  services and libmynos speak it through `mynos_wire.h`; a service that
  keeps a request waiting (a console read) decodes it with `Ipc`'s
  `decode` and answers later with `reply`.
- **Drivers in user space:** a process calls `mynos_driverRegister(name, irq, …)`
  for any IRQ but 0 (the timer) and 2 (the cascade), and gets a semaphore.
  On every interrupt of that line the kernel acknowledges the PICs, signals
  it (`V`), and if the CPU was idle switches to the driver at once. A line
  nobody registered for is masked; a driver's lines are freed when it ends
  (`kernel/irq.c`).
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
    yet), `kill`/`tkill`/`tgkill` on oneself, `waitpid`/`wait4`, threads
    (`clone`, `exit` of a thread, `futex`, `gettid`, `sched_yield`), and
    the clock and sleep calls
    (`kernel/time.c`: PIT ticks plus the CMOS clock read at boot). Unknown
    calls return `-ENOSYS`.

#### services

All services are linked statically against `libmynos` and placed at
`0x40000000`, with musl (`mynos.mk`).

- `registry`: maps names to ports, like a name server (`mynos_registry.h`).
  It serves one request at a time (2026; it used to start a thread per
  request).
- `keyboard`, `serial`: drivers using `mynos_driverRegister` and port I/O.
- `console`: the console service (2026). Owns the keyboard, edits the line
  being typed (Backspace; Up/Down or Ctrl-P/Ctrl-N recall the last 64
  lines, kept in `/disk/.history` when there is a disk, so they survive a
  reboot) and gives lines to programs reading their standard input,
  through `read` in `mynos-lib/src/fileio.c` (`doc/decisions/terminal.md`).
  It replaces `keyboard` in the demo when built.
- `fs/memrofs`: a read-only in-memory filesystem. GRUB loads it as a module
  starting with the `.RAMDISK` magic. The image is built on the host with
  `fs/memrofs/tool/createDisk.c`. Protocol (2026):
  `mynos-lib/include/mynos_fs.h`, the file service protocol. Programs reach
  it through `open`, `read`, `lseek`, `stat`, `opendir`, ... of
  `mynos-lib/src/fileio.c`. The namespace is flat (names up to 63
  characters); `/`, `.` and the empty path name its only directory.
- `ata` (2026): **a disk driver written in OCaml** (`services/ata/ata.ml`):
  the first ATA disk, PIO with LBA28, polling, through the I/O ports; it
  serves sectors as the block service `ata0`, over typed IPC (protocol
  `Block.Protocol`, "block/1"; the client is module `Block` of the `Mynos`
  library).
- `fatfs` (2026): **the FAT filesystem of the disk, in OCaml**
  (`services/fatfs/fatfs.ml`), mounted at `/disk`: FAT16 and FAT32 as made
  by `mkfs.fat`, directories, 8.3 and VFAT long names, read and written,
  on top of the `ata` block service. The whole FAT is kept in memory and
  written to every copy after each change. The demo's disk is
  `system/disk.img` (FAT32, 64 MB, made once and kept).
- `netd` (2026): **the network** (`services/net/`): the lwIP 2.2.1 TCP/IP
  stack (`third_party/lwip`, BSD licence) and an NE2000 driver
  (`ne2k.c`, I/O ports, IRQ 9 for received frames) in one C process, so that a
  frame is a function call. DHCP (else QEMU's 10.0.2.15), ARP, IPv4, ICMP,
  TCP, DNS. Programs use it over typed IPC, protocol "net/1": module `Net`
  (`Config`, `Ping`, `Resolve`, `Connect`, `Listen`, `Accept`, `Send`,
  `Recv`, `Close`, `Set_timeout`, `Connect_tls`, and UDP: `Udp_bind`,
  `Send_to`, `Recv_from`), the first protocol with a C service, through
  `mynos_wire.h`. **TLS** (1.2 and 1.3): mbedTLS 3.6 LTS
  (`third_party/mbedtls`, used under GPL-2.0-or-later) under lwIP's
  `altcp` layer (its port adapted to 3.6); the server's certificate is
  checked against Mozilla's authorities (`/cacert.pem` on the RAM disk,
  from curl's `cacert.pem`) and the user's (`/disk/ca.pem`), and against
  the host name. Modules `Http` (HTTP/1.1 clients, `http://` and
  `https://`, chunked answers) and `Json`; the `fetch` program, a small
  curl (`fetch -i -H ... -d ... URL`). One lwIP thread; a second one receives the requests;
  requests that wait (`Recv`, `Accept`...) keep their channel open until
  lwIP's callback replies. `sh` has `ifconfig`, `ping`, `host`; `httpd`
  (`httpd/httpd.ml`, OCaml) serves `/disk` over HTTP with 8 worker domains
  (idle connections time out after 10 s), and
  `tools/run-demo.sh` forwards the host's port 8080 to it.
- **Language models** (2026, `doc/decisions/llm.md`, mynos-wsd): `llmd`
  (`services/llm/llmd.ml`, OCaml, no privilege) serves "llm/1" (module
  `Llm`: `Profiles`, `Chat` with tools; `Llm.ask`) with 4 worker domains.
  Optional: its configuration is `/disk/llm.env`, a `.env` file of
  profiles (`llm.env.example`; `tools/run-demo.sh` copies the host's
  `llm.env` into the disk), read at every request; without it, calls fail
  with "no model configured". Two adapters: `anthropic` (Claude's Messages
  API) and `openai` (Chat Completions: OpenAI, vLLM, Ollama...). Tool
  calls and results are translated; a provider's own blocks (Claude's
  thinking) travel back as `Opaque`. The `llm` command (`llm -l`, `llm -p
  PROFILE -v QUESTION`). `ask REQUEST` in `sh`: the model proposes a
  command line (tool `propose_command`), `sh` runs it once the user says
  yes. Protocols describe themselves: `Wire` codecs carry shapes,
  protocols list their requests (`Ipc.request_doc`), every `Ipc.Make`
  service and netd answer `"describe"`; module `Tools` turns a description
  into model tools (JSON Schema) and calls any typed service from JSON.
  `agent TASK`: the model works with tools (commands, files, the typed
  services' requests), what changes things confirmed first, the recorder
  on (`/tmp/agent.trc`).
  Tests: `tools/net-peer.py llm`, a fake provider that checks both
  APIs' requests.
- **The graphical interface** (2026, `doc/decisions/gui.md`, mynos-9lr):
  `displayd` (C, `services/display`, a `driver`) sets QEMU's VGA to
  1024x768x32 (Bochs extension), maps its frame buffer (`mapPhysical`,
  native call 28, `io` only) and composes windows whose pixels are their
  programs' buffers, shared over IPC; PS/2 mouse and vmmouse (absolute);
  keys from the console in raw mode; protocol "display/1", described.
  Programs draw with `Gfx` (C primitives in the runtime, Terminus 8x16
  font in `third_party/fonts`), build windows with `Display` and `Gui`
  (immediate mode: labels, buttons, text fields, lists, scroll boxes;
  `Gfx.with_clip`; the mouse wheel). `gui` starts a
  session (welcome, clock, the service explorer, which makes a form for
  any request of any typed service from its description, and terminal
  windows: `sh` in a VT100 emulator, its console a service of the window,
  `MYNOS_CONSOLE`; and the agent window: the agent's conversation, its
  confirmations as buttons, on the module `Agent` it shares with the
  `agent` command; the recordings window: a recording as a timeline of
  calls per process, the marks, the calls, a call's details; the System
  window: the architecture live, from the hardware up, a recording
  replayed on it as arrows through the kernel); the MyNOS
  menu's Exit returns to the text console,
  intact.
- **The event recorder** (2026, `doc/decisions/tracer.md`): while a
  recording is on, the kernel (`kernel/trace.c`) writes an event for every
  spawn, exit, IPC connection, message (with its first 56 bytes) and
  channel freed into a ring buffer, read with native call 32. Module
  `Tracer` decodes it: typed messages (`block/1 Read (2061, 1)`), the C
  protocols (`fs OPEN "a.txt"`, `registry LOOKUP "fatfs"`), calls
  rebuilt from channels and nested, and the Chrome trace event format for
  Perfetto. The `trace` program: `trace COMMAND`, `trace -s SECONDS`,
  `trace show|calls|json FILE`. Programs mark their phases in it
  (`Tracer.mark`; the agent marks its steps). The live processes (native
  call 33) and the registry's names (registry/1 `list`) are listed too: `ps`.
- **Identity and permissions** (2026,
  `doc/decisions/identity-and-permissions.md`): pids, channel and port ids
  carry a generation (`slot + size * generation`), so an id names one
  object for its whole life; `channelPeer` tells a service who calls,
  `processInfo` whether a process still runs. One privilege, `io` (port
  I/O through IOPL 3, IRQs): boot modules have it, `init` gives it to the
  `driver` lines of `init.rc` (consoled, ata, netd, displayd), a child gets at most
  its parent's; `sh` and what it starts have none (an `outb` ends the
  program). Semaphores are their process's own, IRQ lines their driver's;
  well-known ports (0-15) are taken by privileged processes only. Tables:
  4096 channels (was 100 for the whole system), 4096 semaphores; a full
  table is said once on the console. `copy_to_user`/`copy_from_user`:
  a fault on a user address inside them makes the call fail instead of
  ending the process (used where a call writes after blocking).
- **Random numbers** (2026, `kernel/random.c`): `getrandom` serves bytes
  for cryptography: the time-stamp counter at every timer tick and
  interrupt, and RDRAND/RDSEED at boot when the processor has them
  (`tools/run-qemu.sh` gives QEMU's processor both), mixed with SHA-256's
  compression function; output blocks from the pool and a counter, the
  pool replaced after each request.
- `tmpfs` (2026): **the first MyNOS service written in OCaml**
  (`services/tmpfs/tmpfs.ml`), a writable filesystem in memory. It speaks
  fs/1, like the other file services; `fileio.c` sends `/tmp/NAME` to it
  as `NAME` (one flat directory, lost at shutdown). Started by init.

#### shell

The shell is the OCaml 5.5 toplevel itself (`shell/main.ml` calls
`Topmain.main`), linked with the `Mynos` library and module `Shell`
(`help`, `ls`, `cd`, `pwd`, `cat`, `write`, `rm`, `edit`, `run`,
`compile`, `free`), which is opened at startup. **MyNOS is self-hosting
for OCaml programs**: `edit "/disk/a.ml"` (a full-screen editor in OCaml,
`editor/`, on the Notty library with a MyNOS backend), `compile`, `run`;
the files stay on `/disk`.

#### sh

`sh` (`sh/sh.ml`) is a small bash-like command shell, the login shell
(`ocaml` in it starts the toplevel). It edits its own line in raw mode, as
bash with readline: Tab completes commands and file names (a second Tab
lists them), Up and Down recall its history (`/disk/.sh_history`), and
the usual keys edit (arrows, Home, End, Delete, Ctrl-A/E/K/U/W/L/C/D). Its
language: quotes, variables (expanded when each command runs), `;`, `&&`,
`||`, `<`, `>`, `>>`, `|`, `*`/`?`, built-in file commands, programs
found in `PATH` (`/disk/bin:/`, also as `NAME.byte`), scripts (`sh FILE`,
`source`). MyNOS programs inherit no file descriptors, so a program's
redirections travel in its environment (`MYNOS_STDIN`, `MYNOS_STDOUT`),
which `libmynos` applies to fds 0-2; a pipe runs its commands one after
the other through a file in `/tmp`. **Programs can be compiled inside MyNOS**: `ocamlc`
runs from the RAM disk (`OCAMLLIB=/`), and `compile "/disk/a.ml"` makes
`/disk/a.byte`, which may use `Mynos`. Typed lines come from the console service. Files written under
`/tmp` can be run with `#use`.

#### init and the system RAM disk

`init` (`init/init.ml`, OCaml) is the first program: `ocamlrun` runs
`init.byte` from the RAM disk. It reads `init.rc` and starts each line's
program: `driver` (with the `io` privilege: consoled, ata, netd,
displayd) or `start` (tmpfs, fatfs, llmd, httpd) for services, `respawn` for
the login shell, `sh`, which it restarts when it ends (`exit`). Its messages go to the kernel log. The
system RAM disk (`system/ramdisk.dsk`) holds init and `init.rc`, a stripped
`ocamlrun`, `consoled`, the shell with the standard library's and
`Mynos`'s `.cmi` files, and a few programs; only the registry and memrofs,
which serves the disk, stay GRUB modules. `tools/run-demo.sh` boots it.

#### mynos-runtime (OCaml 5.5)

The upstream OCaml 5.5.2 bytecode runtime, **unchanged**: the dev container
builds it with musl (`/opt/ocaml-runtime-musl`), and `mynos-runtime/Makefile`
links it with a short `main()` that picks the bytecode file to open
(`mynos-runtime/main.c`): `ocamlrun prog.byte args…` as on Unix, otherwise
`init.byte` from the RAM disk, otherwise GRUB module 1. Programs start other
programs with `Mynos.spawn "ocamlrun" [| "ocamlrun"; "prog.byte"; … |]`
and `Mynos.wait`. Bytecode is compiled with `ocamlc` 5.5.2.
Effect handlers and domains work (`tests/effects`, `tests/domains`, and
`Domain.spawn` in the shell), and so do OCaml's threads (`Thread`,
`Mutex`, `Condition`, `Event`: the systhreads and unix stubs are in the
runtime, mynos-09i).
Decision and evidence: `doc/decisions/ocaml-runtime.md`.

### Boot flow

1. GRUB loads `kernel.elf` plus a list of modules.
2. The kernel initializes memory, the PIC, the IDT, the PIT, semaphores and the
   services registry.
3. Every module that is an ELF file is started as a process: the services and
   `ocamlrun`. A module's command line (`module /path args` in GRUB, `-initrd
   "path args"` in QEMU) is its `argv`.
4. `ocamlrun` runs `init.byte` from the RAM disk if there is one (through
   memrofs): with `system/ramdisk.dsk`, that is init, which starts the
   console service and the shell. Otherwise, as
   originally, **module 1 is treated as the OCaml bytecode to execute**:
   the kernel serves it as the single file it knows.
5. After that, the kernel runs the idle loop.

---

## Current state

### Build and run

`tools/build-all.sh` then `tools/run-demo.sh`: **MyNOS boots into `sh`**,
a command shell in OCaml, in about a second; `ocaml` opens the OCaml
toplevel, where phrases typed on the keyboard are compiled and run.
Programs can be edited, compiled and run inside MyNOS, and kept on the
disk; `gui` starts the graphical session. The original system, as it ran in
2004-2008, is tagged `revival-baseline` (with its period toolchain) and the
last commit that still builds with that toolchain `legacy-last`.

- **Toolchain.** Builds run in a container (`tools/containers/dev`): Debian
  trixie i386, gcc 14.2, binutils 2.44, nasm 2.16, **musl** 1.2.5 for user
  space, **OCaml 5.5.2** (compiler, and the runtime built with musl); the
  host (gcc 15, no multilib) is not used. Until 2026-11-18 a second one,
  the original project's (Debian lenny, gcc 4.3.2, dietlibc 0.31, OCaml
  3.06 in `mynos-byterun/`), built the same C code to compare: retired
  (mynos-g8l), its last commit tagged `legacy-last`. The way from one to
  the other went through dietlibc 0.34 with OCaml 3.06 (see the journal);
  that is where the Linux ABI work began.
- **Tests.** `tools/run-tests.sh` boots the whole system headless and checks
  the console output, which the kernel mirrors to COM2. `tests/abi` checks
  the system call fixes; `tests/stress` (C) stresses the
  kernel: 120 client processes sending messages from 1 byte to 64 KB, timers
  of 16 threads expiring together, semaphore ping-pong, invalid arguments,
  unknown calls and bad pointers, and checks that the memory comes back
  (`stress N` repeats it N times: 20 runs 2400 processes). OCaml tests
  cover effects,
  the `Mynos` library, files, the console, spawning programs
  (`tests/spawn`) and the shell, typing phrases through QEMU's monitor
  (`tools/type-keys.py`), the network, the language models, the console
  and the graphical session.
- **Terminal.** The kernel's screen driver is a small VT100-like terminal
  for programs' output: cursor moves, erasing, colours, an alternate
  screen. The console service has a raw input mode (keys one by one, the
  arrows and editing keys as escape sequences) that `libmynos` maps from
  termios (`tcgetattr`, `tcsetattr`), with the window size (80x25). kilo
  (`third_party/kilo`) runs on it. Since `doc/decisions/console.md`:
  output is UTF-8, shown in VGA's code page 437 (À È Ì Ò Ù and € on six
  redrawn glyphs, other characters as `?`); the last 500 lines scrolled
  off are kept (Shift + Page Up / Down); keyboard layouts `us` and `it`
  (AltGr, or Ctrl + Alt; `keymap it`, kept in `/disk/.keymap`); line
  editing by characters, not bytes; and the second serial port is a
  console too: `SERIAL=1 tools/run-demo.sh` makes the host's terminal
  one, with its copy and paste.
- **Screen and log.** Once user space starts, the screen belongs to the
  programs: kernel messages, and services' messages (`mynos_log`, native
  call 31, `Mynos.log` in OCaml), go only to the log on the second serial
  port, unless the kernel command line says `verbose` (`VERBOSE=1
  tools/run-qemu.sh`). Panics always show.
- **Booting.** `tools/run-qemu.sh` uses QEMU's multiboot loader, no GRUB.
  Modules are passed in order, with their arguments (`"path args"`); with
  no RAM disk, module 1 is the OCaml bytecode. `tools/run-demo.sh` passes
  the standard set, and so does `tools/run-qemu.sh` without modules
  (`KERNEL_ONLY=1` for the bare kernel). The kernel is built with `-g`,
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
  - Found by the kernel stress test (2026-11-17): a new process's tss had
    uninitialized fields (a garbage `justForked` sent the scheduler down
    the fork path); `KPANIC` spun with interrupts on, so other processes
    ran on a broken kernel; `changeOwner` and `allocPortP` indexed the port
    table unchecked, and semaphore calls the semaphore table with negative
    ids; a negative channel was a "kernel channel" stub that accepted
    anything; the kernel read and wrote through processes' pointers
    unchecked, even into itself; the native system call entry clobbered
    `ecx` and `edx`; semaphores whose slot was found after skipping used
    ones could never be freed, and libmynos's `malloc` made one per
    process that nobody freed; `lmemtrack` lost an element (and an area of
    the process's linear space) at every process creation.
  - The Linux syscall entry did not preserve registers; multiboot modules
    above 4 MB were neither reserved nor mapped; pages allocated on first use
    were not zeroed; the bytecode "file" had no real seek semantics. Found
    while running modern OCaml runtimes (`doc/JOURNAL.md`).
- **OCaml 5.5 and musl (dev toolchain).** User space is built with musl and
  the runtime is OCaml 5.5.2 (`mynos-runtime/`), as decided in
  `doc/decisions/ocaml-runtime.md`. `tools/run-tests.sh` also runs an effect
  handlers test.
  - `memrofs/tool/createDisk` is a host tool but was built like a MyNOS
    program; now built with plain gcc.
- **Changes for the modern toolchain:**
  - Programs are linked with `-Ttext-segment=0x40000000 -z
    noseparate-code --build-id=none` (`mynos.mk`; with the period
    toolchain it was `-N`): modern `ld` puts the ELF headers and a
    build-id note in an extra segment far below `0x40000000`, while the
    kernel loads one contiguous image from there. The
    kernel now also jumps to the ELF entry point instead of a fixed address.
  - dietlibc 0.34 needs three Linux ABI features the 2008 kernel lacked:
    `set_thread_area` (TLS, used for `errno`), `mmap2`, and a Linux-style
    initial stack (`argc`/`argv`/`envp`/`auxv`). They are implemented
    minimally (mynos-51c).
  - Small C fixes: a K&R parameter, missing `<unistd.h>`, `errno`
    declaration, a `return` without value.
  - Remaining warnings are expected: RWX segments (from `-N`).
- `mynos-core/boot/` (floppy bootloader) does not assemble with nasm 2.x
  (mynos-s96); the build uses `mynos-core/kernel` directly.

### Known shortcuts and bugs

| Issue | Where | Problem |
|---|---|---|
| mynos-awn | `mynos-core/kernel/` | One CPU: threads and domains run in turn, not in parallel. |
| mynos-37p | `mynos-core/kernel/` | The io privilege is all or nothing (no per-port I/O bitmap yet); copies to user memory go through `copy_to_user` only where a call blocks first (`recv`, `wait4`): elsewhere the entry check suffices, as the kernel is not preempted. |
| — | `mynos-core/kernel/threads.c` | Native MyNOS threads (`mynos_threadCreate`) share their creator's TLS: code that uses the C library should use pthreads. |
| — | `mynos-lib/src/fileio.c` | `/` (memrofs) is read-only and flat, `/tmp` (tmpfs) flat and in memory; `/disk` (fatfs) has directories. `rename` within one service; paths up to 63 characters inside a service. |
| — | `services/ata/ata.ml` | One disk (primary master), PIO with polling, LBA28 (128 GB). |
| mynos-t9l | `mynos-lib/` | C programs have no sockets API yet: only OCaml programs reach the network (module `Net`). |
| — | `services/net/netd.c` | TLS: clients only (no `Listen_tls`); no revocation checks (CRL, OCSP); Mozilla's list is parsed at the first TLS connection (about 1.5 s in QEMU), later handshakes take 0.2-0.4 s; the clear bytes travel between netd and the program over IPC. |
| — | `services/ata/ata.ml` | The disk is polled (PIO: the driver copies every word anyway, and QEMU completes commands at once); IRQ 14 is free for it. |
| — | `sh/sh.ml`, `mynos-lib/src/fileio.c` | Pipes run their commands one after the other (through a file), not concurrently; the stdio of C programs (musl's direct system calls) is not redirected. |
| — | `gui/terminal.ml`, `mynos-lib/src/fileio.c` | Terminal windows get what programs `write`; musl's stdio (C programs such as kilo) writes with direct system calls and still goes to the text screen. One size, 80 x 25. |
| — | `agent/`, `services/llm/` | The agent has no token budget (only `-n` model calls); answers are not streamed. |

### Not started

- Some drivers are in C (consoled, netd, displayd); `ata`, and the
  services `tmpfs`, `fatfs`, `llmd`, `httpd` and `init`, are in OCaml.
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
   Then processes that free their memory (mynos-pg6), init and the first
   OCaml service, threads and domains (mynos-l9h): done.
4. Storage (mynos-rf4, done): the ATA driver and the FAT filesystem, both
   in OCaml, `/disk` in the shell.
5. Typed IPC (mynos-tc3, done) and networking (mynos-4f6, done): lwIP
   and an NE2000 driver in netd, `Net` over "net/1", `httpd`; TLS
   (mynos-dhp, done): `https://` clients, `Http`, `Json`, `fetch`.
6. Language models (mynos-wsd, `doc/decisions/llm.md`): `llmd` and `llm/1`
   (done), `ask` in `sh` (done), protocols that describe themselves (done), an agent
   loop with the recorder on (done).
7. The GUI (mynos-9lr, `doc/decisions/gui.md`): the display server, windows
   the service explorer, terminal windows, the agent window and the
   recordings window, the System window (done). Then distinctive
   applications (mynos-3h1), several CPUs (mynos-awn).

The old SourceForge site is archived in `doc/website/` (mynos-db2).

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
- **2026-11-16** — Line history in the console service: Up/Down recall
  previous lines in the shell and in every program reading the console.
  `tools/type-keys.py` sends special keys (`{up}`).
- **2026-11-16** — Clean boot screen: after boot, kernel and service
  messages go to the serial log only (`verbose` keeps them on screen);
  native call 31 `log`. The 2004 VBE debug print is gone (closes
  mynos-tuy). Closed mynos-2g3.
- **2026-11-16** — `init` in OCaml: reads `init.rc` on the new system RAM
  disk (`system/`), starts consoled and the shell, restarts the shell after
  `#quit;;`. Boot modules get `argv` from their command line. `Mynos.log`,
  `Mynos.uptime`. Closed mynos-azz.
- **2026-11-16** — `tmpfs`, the first service in OCaml: a writable
  filesystem in memory at `/tmp`; the memrofs protocol becomes the file
  service protocol (`mynos_fs.h`) with `WRITE` and `UNLINK`; `write`,
  `unlink` in `libmynos`; shell commands `write`, `rm`, `ls ~dir`. Fixed an
  IPC bug from 2004: a message ending at a page boundary mapped one page
  too many into the receiver, leaked. Closed mynos-gcv.
- **2026-11-16** — `tools/run-qemu.sh` without modules boots the standard
  system instead of a bare kernel that runs nothing.
- **2026-11-16** — Linux threads: `clone`, thread `exit`, `futex` (wait,
  wake, requeue, timeouts), `gettid`, `sched_yield`; OCaml 5 domains work,
  in tests (`tests/domains`) and in the shell. Closed mynos-l9h; opened
  mynos-09i (`Thread` module) and mynos-awn (SMP).
- **2026-11-16** — Storage (mynos-rf4), decided: a standard filesystem,
  FAT, served by OCaml services. First step: port I/O and driver
  registration in `Mynos` (`inb`, `outb`, `inw`, `outw`, `insw`, `outsw`,
  `driver_register`, `enable_irq`). Closed mynos-rf4.1.
- **2026-11-16** — The ATA disk driver, in OCaml (`services/ata`): PIO,
  LBA28, polling, as the block service `ata0` (protocol
  `mynos_block.h`, client module `Block`). `tools/run-qemu.sh` takes a
  disk image (`DISK=`); the storage test writes to it and the host checks
  the image. Closed mynos-rf4.2.
- **2026-11-16** — `fatfs`, the FAT filesystem in OCaml, mounted at
  `/disk`; started by init with the ATA driver, on `system/disk.img`.
  Tests on FAT16 and FAT32 images, checked on the host with `fsck.fat` and
  mtools. Fixed two kernel bugs that hung the test one time in six: the
  ordered list insertion (equal keys) and the heap releasing a page still
  holding a block's pointers. Closed mynos-rf4.3.
- **2026-11-16** — The console's history is kept on the disk
  (`/disk/.history`): Up after a reboot recalls the previous session. A
  service not found is looked up again every 2 s (init starts services in
  parallel). Closed mynos-rf4.4 and the storage epic mynos-rf4.
- **2026-11-16** — Alternatives recorded in beads: self-hosting (epic
  mynos-0do), a bash-like shell (mynos-z8v), swap through an external
  pager (mynos-vzp), kernel robustness (mynos-0fw); networking decided:
  lwIP in C with a C NE2000 driver in the same service (mynos-4f6).
- **2026-11-16** — `ocamlc` inside MyNOS: the compiler on the RAM disk,
  `rename` (file service protocol, fatfs, tmpfs, libmynos; ocamlc writes
  through a temporary file), `getrandom` in the kernel, `compile` in the
  shell. A program written, compiled and run in MyNOS is in the tests.
  Closed mynos-0do.1.
- **2026-11-16** — A current directory, in `libmynos` (`chdir`, `getcwd`,
  relative paths), inherited by spawned programs through `PWD`; a child
  gets its parent's environment by default; bare program names are looked
  for at the root of the RAM disk. `cd` and `pwd` in the shell. Closed
  mynos-0do.2.
- **2026-11-16** — A terminal: VT100 sequences in the kernel's screen
  driver, raw input mode in consoled, termios and window size in
  libmynos. kilo, a small editor in C, works on it (tested: it saves a
  file on /disk). Part of mynos-0do.3.
- **2026-11-16** — `edit`, a full-screen text editor in OCaml, on Notty
  (`third_party/notty`, with a MyNOS backend replacing `Notty_unix`);
  `Mynos.console_mode`; the terminal learned `ESC E` (Notty's newline)
  and a cleared alternate screen. Edit, compile and run without the host.
  Closed mynos-0do.3 and the epic mynos-0do.
- **2026-11-16** — `sh`, a bash-like command shell in OCaml; redirections
  of a program's standard input and output through its environment,
  applied by libmynos; `Mynos.environment`. Closed mynos-z8v.
- **2026-11-16** — The original website (mynos.sourceforge.net, from the
  Wayback Machine) archived as static files in `doc/website/`, with the
  2002-2004 news posts and the 2002 and 2004 test packages. Closed
  mynos-db2.
- **2026-11-17** — `sh` is the login shell (the owner's choice): `ocaml`
  opens the toplevel, `#quit;;` comes back.
- **2026-11-17** — `sh` edits its line itself: Tab completion of commands
  and file names, its own history, readline-like keys. Fixed the dates
  fatfs wrote (the seconds since 1970 overflowed OCaml's 31-bit int).
  Closed mynos-rix.
- **2026-11-17** — Kernel robustness: a new heap allocator (size classes,
  checked headers, zeroed blocks), and a kernel stress test
  (`tests/stress`) that found and drove the fix of eleven kernel bugs:
  uninitialized tss fields, unchecked table indexes, pointers from
  processes used unchecked (now `__mem_userArea` on every system call that
  takes one), clobbered registers, two semaphore leaks and a linear space
  list leak; `KPANIC` now stops the machine. 2400 processes run with no
  memory lost. Follow-up: mynos-nn7. Closed mynos-0fw.
- **2026-11-17** — Re-read the 2002 presentation (`doc/website/why.html`):
  the architecture is faithful, but the user space had become a small
  Unix. Decided (`doc/decisions/typed-ipc.md`): typed IPC for OCaml
  programs and services, the Unix-like layer kept as the floor, `sh` kept
  next to the toplevel. Done: `Wire` (codecs and wire format), `Ipc.Make`,
  the block protocol converted (`ata.ml`, `Block`; `mynos_block.h`
  removed), callable from the toplevel; tests of the format, of every
  block request, and of malformed messages to the live driver. Closed
  mynos-tc3; next, the network (mynos-4f6) on it.
- **2026-11-17** — The network: netd (lwIP 2.2.1 and an NE2000 driver in
  C, one process), typed IPC "net/1" with the C side of the wire format
  (`mynos_wire.h`), module `Net`; DHCP, ping, DNS (to the internet through
  QEMU), TCP both ways. `sh` gets `ifconfig`, `ping`, `host`; `httpd` in
  OCaml serves `/disk`, at http://localhost:8080/ from the host in the
  demo. `tests/net` with a TCP server and a client on the host. Follow-up:
  mynos-t9l (C sockets), mynos-c9h (socket owners, UDP), mynos-8v4 (IRQs).
  Closed mynos-4f6.
- **2026-11-17** — httpd answered a browser after many seconds: it served
  one connection at a time, and browsers open connections in advance that
  send nothing. Now 8 worker domains, and `Set_timeout` in "net/1" (as
  `SO_RCVTIMEO`) so that idle connections end after 10 s. 50-70 ms a page
  with six idle connections open.
- **2026-11-17** — The event recorder (the owner's idea, mynos-cub): the
  kernel records spawns, exits, IPC connections, messages and frees;
  processes have names; module `Tracer` and the `trace` program show
  recordings as events, as nested calls with their durations, and as a
  Perfetto file (served by httpd). Tests: a registry exchange recorded,
  `sh -> fatfs -> ata0` nested in a recording made in sh, the JSON checked
  on the host. Next: mynos-6yr. Closed mynos-cub.
- **2026-11-17** — Interrupts for drivers in user space: handlers for IRQs
  1, 3-15, acknowledged by the kernel, the driver run at once when the CPU
  was idle, unclaimed lines masked, lines freed with their driver; the
  recorder records interrupts. netd waits for the NE2000's IRQ 9 instead
  of polling every 10 ms: a small page from httpd in 10.7 ms instead of
  42.6 (median of 20). Closed mynos-8v4.
- **2026-11-17** — TLS: mbedTLS 3.6 LTS in netd under lwIP's altcp (its
  port written for mbedTLS 2.x, adapted), `Connect_tls` in "net/1",
  certificates checked against Mozilla's authorities and the host name;
  the kernel's `getrandom` made fit for keys (`random.c`: interrupt
  timings, RDRAND/RDSEED, SHA-256). Modules `Http` and `Json`, program
  `fetch`. From MyNOS: example.com, google.com, api.anthropic.com answer;
  expired.badssl.com and wrong.host.badssl.com are refused with the
  reason. Tests: HTTPS servers on the host with a test authority, an
  unknown one and a wrong name. Closed mynos-dhp.
- **2026-11-17** — A 2003 race at boot: the kernel could give the
  registry's well-known port 0 to any program allocating a port before the
  registry started, which then ended; the stress test hung about 1 run in
  10 (3 in 10 with TLS's timings). Ports below 1 are now only taken by
  number.
- **2026-11-17** — Decision note (proposed):
  `doc/decisions/identity-and-permissions.md` for mynos-nn7 and mynos-c9h:
  process serials, `peer` and `alive` calls, one `io` privilege for
  drivers (IOPL, IRQs; `driver` lines in `init.rc`), semaphores owned,
  the caller in typed IPC, netd's sockets owned and closed with their
  process, UDP, safe user copies.
- **2026-11-17** — Note accepted with generational ids instead of a serial.
  Step 1, the kernel: generational pids, channels and ports; `channelPeer`
  (26), `processInfo` (27); the `io` privilege (IOPL 3 only for it, IRQs,
  `spawn` flags, `driver` in `init.rc`); semaphores and IRQ lines owned;
  `allocPort` no longer takes the owner's pid from the caller; 4096
  channels and semaphores. Stress test: an unprivileged child is refused
  an IRQ, the parent's semaphore, a well-known port and a privileged
  spawn, and ended by `inb`; `channelPeer` names it.
- **2026-11-17** — Step 2: typed IPC handlers get the caller
  (`Ipc.caller`: pid, io), from `channelPeer`; the registry takes the
  owner of a name from the channel (not from the request), keeps the name
  for it while it runs, and frees it when it ends (a restarted service
  can register again). Found: threads of one process cannot talk over IPC
  (channel ends are told apart by pid).
- **2026-11-17** — Step 3, netd: sockets belong to the process that made
  them (an accepted connection to the process that accepted it), known
  from the request's channel; another process gets "not your socket";
  once a second the sockets of processes that ended are closed, so a
  restarted server listens on its port again. UDP in "net/1" (cases
  11-13: `Udp_bind`, `Send_to`, `Recv_from`, 32 datagrams queued per
  socket). Tests: UDP to the host and back, a child process refused our
  socket, a dead child's listening port free again. Closed mynos-c9h.
- **2026-11-17** — Step 4: `copy_user` with a fix-up in the page fault
  handler (one known instruction; the handler gets the interrupted
  frame); `recv` and `wait4` write into the process with it after
  blocking; a full kernel table is said once. Stress test: a thread
  waits in `recv` while another unmaps the page where the kernel will
  write: an error, the process lives (with the previous kernel, the
  process was killed). Also: `recv` left a broken channel locked; `send`
  on a channel not ours dereferenced NULL. Closed mynos-nn7.
- **2026-11-17** — Channel ends have their own ids (mynos-9e1): `2 * (slot
  + 4096 * generation) + side`; the kernel knows the end from the id, no
  longer from the caller's pid, so threads and domains of one process call
  each other over IPC (test: a `Block` service served by a second domain
  of `mynos_test`, called from the first). The recorder still names the
  channel (the even id). Channel and port ids stay below 2^30, OCaml's
  `max_int` on i386. Closed mynos-9e1.
- **2026-11-17** — Language models, step 1 (mynos-wsd,
  `doc/decisions/llm.md`): `llmd` (OCaml) serves "llm/1" (module `Llm`)
  from profiles in `/disk/llm.env` (`llm.env.example`), through two
  adapters, Claude's Messages API and Chat Completions (OpenAI, vLLM,
  Ollama...), with tool calls; the `llm` command; `init.rc` starts it. The
  network test runs questions and a tool loop through both APIs against a
  fake provider (`tools/net-peer.py llm`); by hand, `llm` in MyNOS got its
  answer from Claude Opus 5.5 over HTTPS.
- **2026-11-17** — `ask` in `sh` (mynos-wsd.1): a request in natural
  language; the model (llmd) gets the shell's syntax, commands, directory
  and files, and proposes one command line through a tool; `sh` shows it
  and runs it only after a yes (a key, or a line from a redirected input).
  Network test: `sh -c "ask ..."` with yes and no, through both APIs. By
  hand, with Claude: "elenca i file in /disk con le loro dimensioni"
  became `ls -l /disk`, explained in Italian.
- **2026-11-17** — Protocols that describe themselves (mynos-wsd.2):
  `Wire` codecs carry their shape (`Wire.shape`, `Wire.field`, named
  variant cases); `Ipc.PROTOCOL` has `summary` and `requests` (block/1,
  net/1, llm/1 described); `Ipc.Make` services answer `"describe"`, netd
  too (`wire_put_shape`, a compact notation in C). Module `Tools`: a
  description becomes model tools (JSON Schema), called from JSON. Tests:
  shapes, JSON round trips, block/1's description (mynos-ocaml); netd's
  description equals `net.ml`'s, and `net_config`, `net_ping` and
  `llm_chat` called from JSON (network test).
- **2026-11-17** — The agent (mynos-wsd.3): `agent TASK` runs the model's
  tool loop with its own tools (`run_command`, `read_file`, `write_file`,
  `list_directory`) and the typed services' (`-s`, from descriptions);
  what changes things is confirmed first (y/n/a, `-y`); the recorder runs
  meanwhile (`/tmp/agent.trc`). llmd asks Claude to cache prompts, and
  counts cached tokens in `input_tokens`. `sh` now gives its own
  redirections to its programs (a `sh -c` whose output goes to a file sent
  its programs' output to the console, and their input read the console).
  Network test: three runs (confirmed, `-y`, refused) and the recording's
  nested calls. With Claude: a task in Italian (the IP address, the Date
  of https://example.com, into `/disk/note.txt`, read back) done with
  `net_config`, `fetch -i`, `write_file`, `read_file`.
- **2026-11-17** — The console (mynos-59g, `doc/decisions/console.md`):
  scrollback in the kernel's terminal (500 lines, Shift + Page Up / Down
  through `consoled`); UTF-8 output decoded to code page 437, six glyphs
  of VGA's font redrawn at boot as À È Ì Ò Ù €; keyboard layouts `us` and
  `it` with AltGr (`keymap`, `CONSOLE_KEYMAP`); UTF-8 line editing in
  `consoled` and `sh`; `consoled` reads COM2 (IRQ 3), so the host's
  terminal is a console with copy and paste (`SERIAL=1
  tools/run-demo.sh`). Found on the way: a burst of input (a paste) left
  `consoled`'s semaphore ahead of its queue, and the next reads returned
  an end of file (the shell exited). Also the agent's `run_ocaml` and
  `ocaml_signature` (mynos-vdj): OCaml type-checked by `ocamlc` inside
  MyNOS before it runs. Tests: the screen read from VGA's memory through
  QEMU's monitor (CP437 bytes, the scrollback's mark), the Italian layout,
  input and a paste over COM2, `run_ocaml` with a program that compiles
  and one that does not.
- **2026-11-17** — Fixed: without a second serial port (QEMU's window,
  `tools/run-demo.sh`) `consoled` looped forever emptying COM2 (a missing
  port reads 0xFF): the system crawled and the shell kept restarting.
  COM2 is used only if present, loops on it are bounded, and a test boots
  without it.
- **2026-11-17** — README: a "Using it" section (the console's keys and
  layouts, `SERIAL=1` for copy and paste with the host, language models:
  `llm.env`, `llm`, `ask`, `agent`); its status paragraph brought up to
  date.
- **2026-11-17** — The graphical interface, phases 1 and 2 (mynos-9lr,
  `doc/decisions/gui.md`): `mapPhysical` (28) in the kernel (device pages
  are not counted as RAM); `displayd` (C): BGA 1024x768x32 past the text
  memory, VGA registers saved and restored, PS/2 mouse and vmmouse, keys
  from the console, windows in shared memory composed with title bars, a
  menu and a clock, "display/1" described (variants in `wire_put_shape`);
  `Gfx` (C primitives in the runtime, Terminus 8x16), `Display`, `Gui`;
  programs `gui`, `welcome`, `clock`, `services` (forms from descriptions,
  calls through `Tools`). Tests: Gfx's pixels; a graphical boot driven
  through QEMU's monitor (screen dumps: the top bar, focus, a click
  opening a window, Exit back to text mode); `gui check` (displayd's
  description is `display.ml`'s).
- **2026-11-17** — The GUI, phase 3: terminal windows. `libmynos` sends a
  program's console (reads, modes, and the output of fds 1 and 2, with the
  new `CONSOLE_WRITE`) to the service `MYNOS_CONSOLE` names; `terminal`
  (OCaml) is such a service, runs `sh` in it, and draws its output
  through a VT100 emulator. `sh`, pipes and `edit` (full screen) run in a
  window. The graphical test opens one, runs a command in it, and reads
  its effect from the text console after Exit.
- **2026-11-18** — Scrolling (mynos-73m, `doc/decisions/gui.md`): clipping
  in `Gfx` (`with_clip`, nested), the mouse wheel in `displayd` (vmmouse,
  PS/2 IntelliMouse) as a `wheel` event of display/1, `Gui.scroll` (a box
  whose content's height is measured as it is drawn), a 1000-line
  scrollback with a scrollbar in `terminal`, scroll boxes in the service
  explorer. Our toolkit rather than microui, with microui's design. Tests:
  nested clips; the graphical test scrolls a terminal back with the wheel.
- **2026-11-18** — `shutdown` (and `shutdown -r`): init serves "power/1"
  (module `Power`, described): it ends the graphical session, then turns
  the machine off through ACPI (PM1a control: 0x604 in QEMU, 0xB004 in
  Bochs, 0x4004 in VirtualBox) or resets it through the keyboard
  controller. Any process may ask (one user); the power is init's, which
  has the io privilege. Also in the GUI's menu ("Shut down"). Tests: the
  graphical boot ends with `shutdown` (QEMU ends by itself), another with
  `shutdown -r` under `-no-reboot`.
- **2026-11-18** — Fixed: a kernel panic at the third boot after
  `shutdown -r` ("lmemtrack.c: Block not found", after "kernel heap: free
  list corrupted"). The physical memory manager marked itself ready
  before allocating its own arrays; the pages those allocations took went
  through `pmem_set` with the reference counts not there yet, read from
  low memory, which a reset leaves full of the BIOS's values: a page left
  unmarked was given twice. Also: the kernel zeroes its BSS at entry, and
  fresh frames (`__OS_askPages` with `alloc_now`) are zeroed. A test
  restarts three times and checks that each boot reaches the shell.
- **2026-11-18** — The logo in the GUI: the 2003 website's drawing as grey
  masks (`gui/make-logo.sh`, PGM), drawn as ink of one colour
  (`Gfx.load_mask`, `Gfx.draw_mask`, with an opacity and the clip): light on
  the welcome window's banner, faint in the desktop's corner (displayd).
  Tests: a mask's pixels (mynos-ocaml); the logo and the watermark found on
  the graphical test's screen.
- **2026-11-18** — The legacy toolchain retired (mynos-g8l): it had found
  nothing the dev one did not, cost half an hour per kernel or
  library change, and left the tree unusable for the demo meanwhile. Its
  last verified commit is tagged `legacy-last` (`git checkout legacy-last`,
  `tools/build-all.sh legacy`). Removed: `mynos-byterun/` (OCaml 3.06), the
  legacy container, the dietlibc branches, the 2008 demo of
  `tools/run-demo.sh`; the scripts take no toolchain argument. Closed
  mynos-pg9 (3.06's `frexp`).
- **2026-11-18** — The agent window, GUI phase 4 (mynos-dyv,
  `doc/decisions/gui.md`): the agent's loop moved into the library
  (`Agent`: events out, confirmations asked through a function, a session
  that keeps its conversation), used by `agent` (unchanged output) and
  by `agent_window` (the menu's Agent, the welcome window's button): the
  task typed at the bottom, the conversation in a scroll box, the agent
  in a domain of its own, confirmations as Allow / Deny / Allow all in
  place of the task's field. Test: the graphical boot now has the network
  and the fake provider; a task typed in the window, its confirmation
  seen, Allow clicked, the command's file read back in text mode
  (`SHOTS=DIR` keeps the screens). Trace viewer: mynos-0o5.
- **2026-11-18** — Foundations for the trace viewer and the System window
  (mynos-bm9, `doc/decisions/tracer.md`): marks in recordings (a program
  labels its phases; the agent marks each model call and tool), a list of
  the live processes from the kernel (native call 33: pid, parent,
  privileges, threads, name), the registry's names (request 4, with
  their owners), `ps` in `sh`. Tests: the agent's marks in `trace calls`,
  `ps` naming consoled's service.
- **2026-11-18** — The recordings window (mynos-0o5,
  `doc/decisions/gui.md`): a recording as a timeline (a lane per process,
  calls as boxes, marks as lines; wheel zoom, drag, a mark's step on a
  click), as the list of calls, and a call's details (times, the first
  bytes of both messages); Open a file or Record a command. Opened from
  the menu and from the agent window (Recording). `Tracer.call` keeps the
  messages' first bytes and sizes; `Gui.spawn ~args`. Test: the agent's
  recording opened from its window, a mark's step, a call selected.
- **2026-11-18** — The System window (mynos-81t, the owner's idea,
  `doc/decisions/gui.md`): MyNOS's architecture live, from the hardware
  up (the kernel and its parts, drivers wired to their devices, services,
  programs), the processes as boxes that appear and fade; a recording
  replayed on it as arrows from client through the kernel to server,
  interrupts from devices, marks. Background jobs in sh (mynos-rk1):
  `PROGRAM &`, `$!`, collected when they end; the agent knows them. Test
  service `tests/greeter` (greeter/1). Tests: the agent starts greeter
  with `&`, `ps` shows it with its name, a client gets its greeting; in
  the graphical session, the System window's layers, a replayed call's
  arrow, a ghost, a new process outlined.
- **2026-11-18** — `kill` (mynos-6hb): native call 34 ends another
  process as killed (signal 9), its IPC, semaphores and memory freed as at
  its exit (`endProcess`, generalised from `killProcess`: on one
  processor, every thread of another process is in some queue); not
  init, nor a process with a privilege the caller lacks. `kill PID` or
  `kill SERVICE` in `sh`, `Mynos.kill`. The GUI: the top bar has a tab for
  each window (a click brings it to the front); the close box closes on
  release, on it. The System window matches a recording's processes by
  pid and program (another boot's recording: ghosts), and puts the
  ghosts that served calls among the services. Tests: kill by name and by
  `$!`, init refused; a slip off the close box, a close, a tab; another
  boot's recording (`tests/greeter/old-boot.trc`).
- **2026-11-18** — A terminal closed with its close box left its sh
  running, reading a console that was gone (the owner saw the processes
  grow). Now a read from a console that has gone is the end of the input,
  and the terminal ends sh and its descendants when closed (a hang-up).
  Test: after the graphical session, `ps` shows one sh and no terminal.
- **2026-11-18** — The agent builds programs (`build_ocaml`): compiled
  into a file it names, with MyNOS's libraries (also `Gfx`, `Display`,
  `Gui`), its source kept beside it, not run; windows and services are
  then started with `&`. Its prompt now says how a window is drawn and
  how a terminal program places characters (VT100 sequences, the key
  mode). `run_ocaml` says it is not for programs that keep running. The
  fake provider takes a JSON object as a tool's input. Test: a program
  built by the agent, run from sh.
- **2026-11-18** — The System window says what each process is written
  in, OCaml (bytecode on `ocamlrun`) or C: the kernel marks the processes
  started as `ocamlrun` (`MYNOS_PROC_BYTECODE`, `Mynos.process.bytecode`).
- **2026-11-18** — `tools/run-tests.sh` runs its boots in five lanes at
  once (mynos-9vi): 4.5 minutes instead of 10-11. Each lane appends to
  its own part of the log and saves the results it found for the checks;
  the graphical session's fake model has its own port (47091). `LANES=d`
  runs a lane alone while working on it, `KEEP=1` keeps the logs and
  screens. The full run stays the check before a commit.
- **2026-11-18** — Choosing files (mynos-kcl): `Gui.file_picker`, a
  modal panel in immediate mode (places, the path in parts, entries, a
  filter), used by Recordings and System for their recordings; and Files
  (mynos-4ss), a file manager: places with the service that serves each,
  open by type (programs started, recordings in Recordings, texts and
  images viewed), new folder, rename, delete, copy, cut and paste
  between services. Test: in the graphical session, a file copied from
  /tmp to /disk, viewed, a folder made; checked from text mode.
- **2026-11-18** — Ctrl-C (console.md, section 4): sh tells its console
  the program it waits for, and Ctrl-C ends it (kill; `$?` 137, the screen
  restored), unless the program turned interrupts off (termios ISIG:
  editors, displayd). In consoled and in Terminal windows. A graphical
  program started outside the session says so and ends (displayd refuses
  the window). Tests: Ctrl-C on the text console and in a Terminal
  window; a window from text mode.
- **2026-11-18** — Screenshots in the README (the welcome window, the
  System window, the shell), taken by `tools/screenshots.sh` (QEMU
  headless, driven through its monitor; `tools/ppm2png.py` converts
  QEMU's screen dumps with the standard library only). The README says
  the project was taken up again in 2026 with the help of AI.
- **2026-11-18** — fatfs reads faster (the owner saw two `cat` of one
  file on /disk scale badly). Measured with the recorder: a 16 KB READ
  was 32 one-sector requests to ata (512-byte clusters on
  `system/disk.img`), 15-20 ms. Now consecutive sectors are asked in one
  request, sectors are cached (2 MB, write-through), an open file keeps
  its cluster chain: 2.85 ms the first time, 0.64 ms from the cache. fatfs
  and ata still serve one request at a time. Test: a 100 KB file read
  twice, the disk requests counted in the recordings (8, then 0).
- **2026-11-18** — The tour (mynos-5zp, `doc/decisions/gui.md`): lessons
  on how an OS works (`/tour.txt`: a file from the RAM disk, a directory
  from the disk, a program born, the network, a language model), each run
  under the recorder and replayed in the System window with its words at
  the steps it explains; the System window shows processes born and
  ending. In the menu and the welcome window. `run-tests.sh`: a section
  that fails no longer stops its lane (the results it found are kept).
  Test: the third lesson replayed, at the birth of hello.
- **2026-11-18** — Services that come back (mynos-16h,
  identity-and-permissions.md section 8): init restarts a service that
  crashes or is killed (5 times a minute at most); libmynos and Ipc
  clients look a service up again when its port is gone. Two kernel bugs
  found on the way: `kill` did not free the killed process's ports and
  channels (they check their owner against the current process), and a
  port whose owner died listening on it was never freed, so a client that
  connected waited for ever. Tests: fatfs killed, back, used by sh; an
  OCaml client of greeter finds it again.
- **2026-11-18** — Files over typed IPC (mynos-7a1, typed-ipc.md): fs/1
  (`Fs`, `mynos_fs.h`) replaces the file services' C structs. tmpfs and
  fatfs serve it typed, memrofs (C) through `mynos_wire.h`, libmynos is
  its client; a directory comes in one List reply; the client is the
  caller the kernel names. Recordings decode it like any protocol
  (`fs/1 Open ("init.rc", 0)`); the tour's notes and the tests follow.
  Tests: memrofs lists, refuses a write, describes fs/1 as `fs.ml` does.
- **2026-11-18** — OCaml's threads (mynos-09i, ocaml-runtime.md): the
  systhreads and unix C stubs, built with musl from sources the container
  keeps, are linked into `ocamlrun` with their primitives; programs link
  the compiler's `unix.cma` and `threads.cma` with `-noautolink` (no
  shared libraries); both are on the RAM disk for `ocamlc` inside MyNOS.
  The console stubs release the runtime lock while they wait. Tests:
  threads with Mutex, Condition, Event, Thread.delay, and MyNOS calls
  that wait while other threads run; a threaded program compiled inside
  MyNOS.
- **2026-11-18** — The last C protocols to typed IPC (mynos-nty,
  typed-ipc.md): registry/1 (C registry, libmynos client, module
  `Registry`; the registry is in its own table) and console/1 (consoled,
  terminal windows, libmynos, sh's `keymap`; module `Console`; the
  caller from `channelPeer`, no pid in the request). `Ipc.Make` gains
  `decode`/`reply` for services that answer later. The recorder decodes
  both; tour notes follow. Every MyNOS service now speaks typed IPC.
- **2026-11-18** — The manual's architecture appendices (mynos-1t9,
  `doc/manual/`): A to J, written against the code, every claim checked
  in it. Writing them found bugs, filed: the FPU state not saved
  (mynos-t6p), kernel writes ignoring read-only pages (mynos-bvz), a
  message mapped into the kernel's page table (mynos-py9), unchecked
  pointers in Linux calls (mynos-3po), munmap of the RAM disk
  (mynos-q5b), IPC waiters never woken (mynos-3bb, mynos-blv), page
  directory entry 255 (mynos-vm8), anyone may record (mynos-kwe) or
  write the disk and power off (mynos-dow), C stdio input (mynos-d6k),
  and minor findings (mynos-6qs, mynos-1ev, mynos-f2d, mynos-uoq).
  Stale lines here and in the decision docs corrected.
- **2026-11-18** — Each thread its own floating-point state (mynos-t6p):
  `switchTo` saves and restores the x87/MMX/SSE registers
  (`FXSAVE`/`FXRSTOR`, `FNSAVE`/`FRSTOR` without FXSR) in a 512-byte
  area of the `tss_t`; new threads start from a clean state recorded at
  boot, a forked child from its parent's; SSE is turned on (CR4 OSFXSR,
  OSXMMEXCPT: it was off, an SSE instruction ended the program); the
  kernel is compiled with `-mgeneral-regs-only`. Test `tests/fpu`: two
  threads keep x87 and SSE values and their rounding mode across
  preemptions (it fails on the old kernel).
- **2026-11-18** — The kernel's writes respect read-only pages
  (mynos-bvz): CR0.WP is set before the first task switch, so a system
  call writing into a copy-on-write page copies it first (a sent
  message's frame was changed under its receiver). Every kernel mapping
  is now writable on purpose (boot's identity map and page-table
  windows, kernel stacks, process info pages, the external window, the
  copy-on-write window); a kernel write to a read-only page is logged.
  And the pointers of `clock_nanosleep` (both) and `_llseek` are checked
  (mynos-3po; the other Linux calls with pointers were audited). Tests:
  `tests/abi` (pointers into the kernel refused; a kernel write keeps a
  sent message intact).
- **2026-11-18** — A message too large for the receiver's free linear
  space is refused (`MYNOS_ERR_FULL`, mynos-py9): `__OS_mapPagesTo`
  ignored `__lmt_allocArea`'s failure value and mapped the pages at page
  1, over the kernel's page table; the machine reset. Test in
  `tests/abi` (the linear space filled with `mmap`, a 128 MB send);
  without the fix the machine reboots in a loop.
- **2026-11-18** — Four kernel bugs from the appendices' review, each
  with a test in `tests/abi` that fails without the fix:
  `munmap` refuses the RAM disk's shared page tables (mynos-q5b; with
  CR0.WP it had become a kernel panic); page directory entry 255 is left
  empty (mynos-vm8: it pointed at physical page 0 with the user bit, and
  a program could map any frame for itself through the EAX the page
  fault handler saves at address 0); freeing a channel end wakes the
  thread waiting on the other side (mynos-3bb); `listenPort` skips a
  connector that ended while queued, and `freePort` wakes the queued
  ones (mynos-blv).

