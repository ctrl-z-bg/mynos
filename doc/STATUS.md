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
found along the way, bug by bug, is in `doc/JOURNAL.md` (shared with
`main`), `doc/JOURNAL-next.md` (the work of this branch, `next`: the
ports, SMP, the Raspberry Pis) and `doc/JOURNAL-apps.md` (the
applications, from `main`).

Last updated: 2026-11-28

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
| `mynos-core/` | The microkernel: boot, memory, processes, threads, scheduler, IPC, syscalls; the architecture's own code in `kernel/arch/i386` (doc/decisions/arch.md) |
| `mynos-lib/` | User-space library wrapping the native MyNOS syscalls (`include/mynos.h`), and the OCaml library `Mynos` (`ocaml/`) |
| `services/` | User-space servers: `registry`, `console`, `keyboard`, `serial`, `fs/memrofs`; in OCaml: `tmpfs`, `ata` (disk driver), `fatfs` |
| `mynos-runtime/` | The OCaml 5.5 bytecode runtime for MyNOS: upstream runtime, unchanged, plus a MyNOS `main()` (dev toolchain) |
| `init/` | `init`, in OCaml: starts the services and the shell listed in `init.rc` |
| `shell/` | The shell: the OCaml toplevel (`shell.byte`) and module `Shell` (commands) |
| `system/` | The system RAM disk: `init`, `init.rc`, services, the shell, interfaces, programs |
| `editor/` | `edit`, the text editor, in OCaml on Notty |
| `sh/` | `sh`, a bash-like command shell, in OCaml |
| `pkg/` | `pkg`, the package manager, and the graphical session's Packages window (`doc/decisions/packages.md`) |
| `packages/` | The packages' descriptions (`NAME/spec`), built by `tools/pkg-build.sh` and published in ctrl-z-bg/mynos-packages |
| `graphics/` | OCaml's `Graphics` library (the `graphics` package's interface) in OCaml on `Display` and `Gfx`, and its test |
| `third_party/` | kilo (C editor), Notty and uutf (OCaml terminal UI), Num (OCaml big numbers), 2048-ml (a game for `Graphics`, the package `2048`), lwIP (TCP/IP), mbedTLS (TLS), Mozilla's certificate authorities, with their licenses and MyNOS changes |
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
  pthreads (`lthreads.c`); OCaml 5's domains run on them. On the i386
  all threads share one CPU; on x86-64 they run on up to eight (four by
  default), under one big kernel lock (doc/decisions/smp.md). Processes are created from
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
  (`httpd/httpd.ml`, OCaml) serves `/disk/web` over HTTP with 8 worker domains
  (idle connections time out after 10 s), and
  `tools/run-demo.sh` forwards the host's port 8080 to it. It receives
  files too (mynos-god): `PUT` (`curl -T`) and an Upload form in each
  listing (multipart, saved as it arrives, a hidden file renamed when
  whole), from the host QEMU runs on (10.0.2.2 on QEMU's user network)
  or anyone with `httpd -w`; Host and Origin must name the server.
  Writing to `/disk` goes at about 800 KB/s under KVM (mynos-ipg: KVM
  exits for each word of `rep outsw`; reading is 12 MB/s).
- **Sound** (2026-11-22, `doc/decisions/sound.md`, mynos-7jn): the
  kernel keeps a DMA area at boot (64 KB below 16 MB on a 64 KB boundary,
  in the gap between its page directory and its image, else above 4 MB;
  call 29 `dmaArea` maps it for a driver). `soundd` (C, a driver) plays a
  Sound Blaster 16 by 16-bit auto-init DMA from it, IRQ 5, and mixes up to
  8 streams and 4 tones (22050 Hz, 16-bit stereo, halves of 46 ms; pauses
  in silence): protocol sound/1, module `Sound` (WAV files converted),
  `play` (files, tones, volume). QEMU: `SOUND=BACKEND` (run-demo.sh and
  run-mynos.sh choose the host's), `SOUND=wav:FILE` for the tests; v86
  plays it in the browser. Tested in the seventh boot (the recording's
  frequencies) and on v86 from Node.
- **Packages** (2026-11-20, `doc/decisions/packages.md`, mynos-vcd):
  `pkg` (`pkg/pkg.ml`, on the RAM disk) lists, installs, removes the
  packages of the repository ctrl-z-bg/mynos-packages (`index.json`,
  ustar archives, from raw.githubusercontent.com; `MYNOS_PKG_URL` names
  another). An archive's size and BLAKE2b-256 are checked; its bytecode
  is installed in `/disk/bin` when its magic number and primitives are
  this runtime's, otherwise its sources are compiled by `ocamlc` inside
  MyNOS (`-s` forces it). The packages are described in `packages/` and
  built by `tools/pkg-build.sh` (into `tmp/packages` by
  `tools/build-all.sh`). A package may need others (installed first), be
  data only, or be several commands of one program (scripts `#!PROGRAM`,
  which `sh` runs); `pkg search`, `pkg upgrade`. Packages: `2048`,
  `windtree`, `utils` (grep, wc, head, tail, sort, uniq, find, du,
  hexdump, tree), `calc` (exact numbers, on Num), and games in a window:
  `mines`, `blocks`, `snake`, `sudoku`, `life`, `solitaire`; `view` (PNG,
  BMP, Netpbm) and `paint` (saves PNG, with a small deflate of their
  own); `zmachine`, an interpreter of Infocom's and Inform's stories
  (versions 1 to 5, 7, 8: Czech's and Praxix's tests pass); `wiki`
  (Wikipedia, in a window or the terminal), `feeds` (RSS and Atom),
  `manual` (the manual's chapters, `man NAME`, a window to read them),
  `scheme` (OCS, R5RS, `third_party/ocs`), `camlboy` (CAMLBOY, a Game
  Boy emulator in OCaml, `third_party/camlboy`: 60 frames a second under
  KVM) with `tobutobugirl`, `zork1`, `zork2`, `zork3` (Infocom's story
  files, MIT since 2025, `third_party/zork`), `minotaur` (an original text adventure
  inside MyNOS). A package may give the agent
  a tool (`tool.json`: `wikipedia`, `calculate`) (mynos-vws).
  Tested in the seventh boot against the host's copy (`tools/net-peer.py
  files`). The graphical session's Packages window
  (`pkg/packages_window.ml`, in the MyNOS menu) lists them and runs `pkg`
  for Install, Remove, Update; `/disk/pkg/url` names another repository
  for both. The menu's Applications (`pkg/apps_window.ml`) lists the
  installed packages that open a window, and starts them (mynos-r33).
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
  `Gfx.with_clip`; the mouse wheel), or with OCaml's `Graphics`
  (`graphics/graphics.cma`, mynos-0rn: programs written for it compile
  unchanged; 2048-ml, `third_party/2048-ml`, is the package `2048`). `gui` starts a
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
runtime, mynos-09i). So are `Str`'s stubs (mynos-rld) and those of `Num`
(`third_party/num`, version 1.6, mynos-yux); `str.cma` and `nums.cma`
are on the RAM disk for `ocamlc` inside MyNOS.
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
| — | `mynos-lib/src/socket.c`, `fileio.c` | BSD sockets: IPv4 only; no half close; no TLS (`net/1`'s `Connect_tls` is not a socket call); a non-blocking `connect` waits. `poll` with the console and sockets together asks each in turn every 20 ms. |
| — | `services/net/netd.c` | TLS: clients only (no `Listen_tls`); no revocation checks (CRL, OCSP); Mozilla's list is parsed at the first TLS connection (about 1.5 s in QEMU), later handshakes take 0.2-0.4 s; the clear bytes travel between netd and the program over IPC. |
| — | `services/ata/ata.ml` | The disk is polled (PIO: the driver copies every word anyway, and QEMU completes commands at once); IRQ 14 is free for it. |
| — | `sh/sh.ml`, `mynos-lib/src/fileio.c` | Pipes run their commands one after the other (through a file), not concurrently. |
| — | `gui/terminal.ml`, `mynos-lib/src/fileio.c` | Terminal windows get what programs `write`, C stdio included. One size, 80 x 25. |
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
- **2026-11-19** — C stdio over libmynos (mynos-d6k,
  `mynos-lib/src/stdio.c`): musl's five internal I/O functions
  (`__stdio_read`, `__stdio_write`, `__stdout_write`, `__stdio_seek`,
  `__stdio_close`) and `fopen` replaced at link time (`mynos.mk` names
  them with `-u`), on libmynos's `read`, `write`, `ioctl`, `lseek`,
  `close`, `open`. `fopen` reaches the file services, `fgets(stdin)`
  reads the console or a redirection, `printf` follows redirections and
  terminal windows. Test `tests/stdio`, run from `sh` in the seventh boot
  (a typed line, a piped one).
- **2026-11-19** — One recording at a time (mynos-kwe): the recorder
  belongs to the process that started it, which alone stops, reads and
  frees it until it ends (`MYNOS_ERR_BUSY`/`DENY` for others;
  `Tracer.Busy`, `Tracer.free`). `trace` and the agent free the kernel's
  buffer when done (768 KB stayed allocated); `trace` reports a busy
  recorder, the agent works without recording, the Tour shows the
  message. Any process may still record (identity-and-permissions.md,
  section 9). Test in `tests/abi`.
- **2026-11-19** — The manual's Parts II and III (mynos-1t9,
  `doc/manual/05-...` to `24-...`): user's guide (installation, the
  console, files, programming inside, networking, the graphical session,
  watching the system, language models, command reference) and
  programmer's guide (C and OCaml programs, processes, IPC, typed IPC,
  files and console, networking, graphics, language models, the
  recorder, drivers, reference pages), written against the code, their
  commands and examples run in MyNOS. The complete examples are in
  `doc/manual/examples/`, compiled by `tools/build-examples.sh` (in
  `build-all.sh`). Fixed on the way: `mv` to the same name in other
  letters emptied and removed the file (sh fell back to copy-and-remove
  on any error; fatfs refused the new spelling: mynos-qaw); a C
  program's redirected stdout lost all but its first line (libmynos
  closed the file before musl flushed); `isatty` follows redirections;
  a window whose session has ended closes quietly (`Gui.run`). Filed:
  mynos-n16 (httpd serves llm.env), mynos-5dd, mynos-dby, mynos-smw,
  mynos-wvv.
- **2026-11-19** — The manual's Part I (mynos-1t9): welcome, why MyNOS
  (the 2002 page quoted, and what each of its points became), the
  historical context (2000-2004), the timeline (2002-2004 from the CVS
  history and the SourceForge news, the ZX Spectrum test of 2003, the
  restart of 2026). The whole working text is written. And the minor
  issues filed by the manual's review, fixed: httpd serves no hidden or
  `.env` files (mynos-n16); the Services window asks every registered
  service; a program reaches its own address (lwIP loopback); netd
  rereads `/disk/ca.pem` when it changes; `mremap` answers ENOMEM
  quietly; sh offers only programs as commands, `ls -a`, a bounded
  history file, a clear `mkdir` error on `/tmp`; Ctrl-C on a program
  waiting for input no longer swallows the next line, and works from the
  serial terminal in raw mode; `edit` takes Ctrl-C as a key
  (`Mynos.console_mode ~isig`); llmd logs to the log; kilo clears the
  screen; `ata` started from sh says it is a driver; `driverRegister`
  no longer fills the 2002 service table; ata waits before the cache
  flush and checks it; Http finds a body's end once; Gui keeps its ticks'
  pace and redraws after a click; `Tracer.stop_and_save`;
  `Mynos.spawn ~env:[||]` gives an empty environment; a closed port is
  "connection refused"; module command lines of 255 characters, a longer
  one said; memrofs's self-test quiet without AUTOEXEC.BAT; the welcome
  screenshot redone (mynos-wvv, mynos-5dd, mynos-smw, mynos-dby).
- **2026-11-19** — One primitive each for `spawn` and `console_mode`
  (the owner's choice): `caml_mynos_spawn` takes the environment as an
  option (None: ours), `caml_mynos_console_mode` takes `isig` (-1
  unchanged); `caml_mynos_spawn_env` and `caml_mynos_console_signals`,
  added the same day to keep old bytecode working, are gone. Bytecode
  compiled before this (outside the build) must be compiled again.
  `tools/build-examples.sh` runs last in `build-all.sh`, after the OCaml
  library.
- **2026-11-19** — The Tour's sixth lesson, *A service that dies*
  (`gui/tour.txt`): `kill fatfs; ls /disk`, with notes on the registry's
  `List`, the kernel ending `fatfs`, `init` starting a new one, its reads
  through `ata`, its `Register`, `sh`'s lookups until it is back, and the
  directory from the new one. Each note checked against a recording made
  in MyNOS.
- **2026-11-19** — A bootable ISO (mynos-sc9, first part):
  `tools/make-iso.sh` makes `tmp/mynos.iso` (not kept by git) with GRUB
  for PC BIOS; the dev container gains `grub-pc-bin` and `xorriso` (a
  last layer). Booting under GRUB found two bugs of 2002, hidden by
  QEMU's multiboot loader: `clear_page_table` (`start.asm`) cleared only
  the last byte of each entry (QEMU gives zeroed memory, GRUB does not:
  its leftovers became present page tables); and `_init_gdt` loaded the
  GDT without reloading the segment registers (QEMU's selectors match
  MyNOS's by chance, GRUB 2's do not: the first `iret` faulted). The
  ISO boots to `sh` in 3 s, with the disk, the network and the
  graphical session.
- **2026-11-19** — `make-iso.sh` also makes a clean disk,
  `tmp/mynos-disk.img`, every time with `system/Makefile`'s recipe
  (`DISK=...`): an empty FAT32 and a README, never the developer's
  `system/disk.img` (which holds `llm.env`). Booted with the ISO: `/disk`
  holds only `README.TXT`, and llmd says no model is configured.
- **2026-11-19** — `edit` takes UTF-8 (mynos-wv4): lines stay UTF-8
  strings, the cursor, the columns, Backspace and Delete count
  characters, Notty's `Uchar` keys are inserted (they were dropped), and
  what is shown keeps accented letters (bytes that are not UTF-8 become
  `?`). Test in the seventh boot: accented letters typed on the serial
  terminal, one erased, the file saved and read back.
- **2026-11-19** — The log inside MyNOS (mynos-lfv): the kernel keeps
  its messages and the services' (`printk`, call 31) in a 64 KB ring,
  read with native call 35 (`mynos_klog`, `Mynos.log_position`,
  `Mynos.log_read`); the `log [-f]` program and the Log window (the
  MyNOS menu's tenth item). Versions (mynos-nec, the owner's choice):
  the build's year and month and the commit, `2026.11-71dc1d2`, from
  `tools/version.sh`, written by `build-all.sh` to `VERSION` (not kept
  by git); the kernel prints `Welcome to MyNOS - v...` first and answers
  `uname` (Linux 122); `Mynos.version`, `sh`'s `version`, the welcome
  window, GRUB's menu entry. The README shows the 2003 logo.
- **2026-11-19** — Releases (mynos-sc9): `tools/make-release.sh` makes
  `tmp/release/mynos-VERSION.tar.gz` (and a `.sha256`): the ISO, a clean
  disk, `run-mynos.sh` (only QEMU needed: the disk copied on the first
  run and kept, `--serial`, `--no-net`, `--http`, `--mem`,
  `--reset-disk`, `llm.env` copied in when mcopy is there), a README,
  `llm.env.example` and the licences. README: "Try it"; manual 5.2.
- **2026-11-19** — Manual 5.1: what a release needs (QEMU only; mtools
  and python3 optional) apart from what building needs.
- **2026-11-19** — `sh`'s Tab quotes (mynos-f7k): the word is found as
  the lexer reads it (a space inside quotes does not end it), completed
  on its value, and written back between double quotes when it has a
  space or a character the shell reads, or was begun in quotes; a
  directory's quote stays open. Test in the seventh boot.
- **2026-11-19** — MyNOS in the browser (mynos-2a2): the release's ISO
  and disk boot unchanged on v86 (no network). `tools/make-web.sh` makes
  the static site (images in 1 MB zstd chunks, ~10 MB);
  `tools/publish-release.sh` publishes the GitHub release and the site
  on GitHub Pages (`gh-pages`). README and manual 5.2 link the page.
- **2026-11-19** — First release published: v2026.11-89918d5 on GitHub
  (archive and checksum), and MyNOS in the browser at
  https://ctrl-z-bg.github.io/mynos/ (GitHub Pages, branch gh-pages).
  publish-release.sh: GitHub enables Pages by itself on the first push
  of gh-pages, so a 409 there is not an error.
- **2026-11-19** — Manual, chapter 3 checked against sources (an outside
  review): MINIX 1's drivers were kernel tasks, Singularity's contracts
  are stronger than MyNOS's request/reply, SPIN added, Mach/L4 and seL4
  stated precisely, Inferno softened; "finished" defined once (2.3);
  SourceForge registration 2001-09-05 in chapter 4; appendix J: Liedtke
  1993, SPIN, JNode, Syme.
- **2026-11-19** — Manual 3.2: the Lisp machines, an operating system
  whose master was a functional language, MyNOS's inspiration (the 2002
  page cites them); appendix J: the MIT progress report and manual.
- **2026-11-19** — Manual 5.4: the first boot's transcript starts with
  the kernel's greeting and version.
- **2026-11-19** — Manual 5.4: the four boot modules named (ocamlrun,
  registry, memrofsd, ramdisk.dsk).
- **2026-11-19** — Manual, second outside review of chapter 3: the Lisp
  machines (language safety apart from process isolation, hardware by
  generation, the 2002 analogy quoted exactly), seL4's machine-checked
  proof, Singularity in appendix J. Chapter 4: the SourceForge news
  before November 2002 (2002-01-08, 10-03, 10-11, 10-22: the OCaml VM as
  a process), semaphores on 11-26.
- **2026-11-19** — Manual figures: 12 new screenshots (the menu, tabs,
  the Terminal, Services, Files; Recordings, the Tour's replay, a
  service that dies and comes back; the agent's confirmation and result;
  Life). `tools/screenshots.sh` makes all 15 on a clean disk (no longer
  system/disk.img), the agent's only with llm.env. Agent window: tabs
  drawn as a glyph (mynos-1cz).
- **2026-11-20** — OCaml's libraries measured inside MyNOS (a probe of
  about 80 functions): the standard library, files, threads, domains and
  Dynlink work; `Unix` without pipes, `dup`, `select`, sockets or
  `create_process`. Added `Str` (its stubs kept by the dev container)
  and `Num` (`third_party/num`) to the runtime and the RAM disk. Fixed
  `Sys.time` (the kernel counts each process's CPU ticks: `getrusage`,
  `times`, the CPU-time clocks), `getuid` and friends (0), and `O_EXCL`
  (fs/1's `o_excl`, in tmpfs and fatfs). New boot in `run-tests.sh`:
  `tests/libs`. Closed mynos-rld, mynos-yux, mynos-0xy, mynos-469,
  mynos-0r1.
- **2026-11-20** — OCaml's `Graphics` on MyNOS (`graphics/`): the
  `graphics` package's interface written again in OCaml on `Display`
  and `Gfx`, drawing in a backing store shown in batches (every 20 ms
  while drawing, and at every read of the input). `display/1`'s
  `next_event` with a negative timeout does not wait (`Display.poll`).
  `graphics.cma` on the RAM disk; its test in the graphical session's
  boot; 2048-ml compiled unchanged and played. Manual 20.6. Closed
  mynos-0rn.
- **2026-11-20** — Compiling inside MyNOS links the libraries a program
  names: the toplevel's `compile` and the agent's `run_ocaml` and
  `build_ocaml` add `unix.cma`, `threads.cma`, `str.cma`, `nums.cma`,
  `graphics.cma` when the source mentions their modules
  (`Agent.ocamlc_libraries`). Found by the agent, which wrote a
  Graphics program and had to call `ocamlc` by hand. Checked in the
  seventh boot.
- **2026-11-20** — 2048-ml (Philip Xu, BSD) in `third_party/2048-ml`,
  built against `graphics.cma` and put on the RAM disk (`/2048.byte`,
  156 files). The agent's tree in the wind is the manual's second
  Graphics example (`examples/20/tree.ml`, 20.6). `tools/clean-all.sh`
  now cleans `graphics`, `third_party/num` and `third_party/2048-ml`.
- **2026-11-20** — Packages: `pkg` (mynos-vcd, `doc/decisions/packages.md`)
  and the repository ctrl-z-bg/mynos-packages, with `2048` and `tree` (renamed `windtree` the same day: `tree`
  is Unix's command for directory trees).
  Hybrid packages: bytecode, installed when this runtime can run it
  (magic number, primitives), and sources, compiled inside MyNOS
  otherwise. 2048 left the RAM disk (its Makefile too: the package is
  built by `tools/pkg-build.sh`). Seventh boot: 2048 installed as
  bytecode, the tree compiled from its sources, 2048 removed. Manual
  9.8, 13 (PKG), H.9.
- **2026-11-20** — The package `tree` renamed `windtree`; `pkg list -i`
  lists the installed packages only, from `/disk` (no network), with
  the index's newer version if the cached index has one.
- **2026-11-20** — Manual 4 (timeline): Tommaso Schiavinotto's and
  Alessandro Tommasi's work cited for what it was, from the git history
  and SourceForge's news: multiboot, the ELF loader and the semaphores
  (Tommaso); `fork`, `lmemtrack`'s copy and forced areas, the ZX
  Spectrum (Alessandro); the first commit, the IPC of 2004, the ZX
  Spectrum (Cesare). Each is named three times. The row on a Makefile
  target is gone.
- **2026-11-20** — The Packages window (`packages.byte`, the MyNOS menu's
  Packages): the index's packages, the installed ones marked, Install,
  Upgrade, Run, Remove, Update index; each runs `pkg` as a process,
  its output shown as it comes. `pkg`'s reading of the index and of the
  installed packages moved to module `Pkgdb`, shared by both.
  `/disk/pkg/url` names the repository for every program. Tested in the
  graphical session (lane d): the window reads the index from the
  host's copy. It reads the installed packages at its start and after
  each job only: read at every frame, they were open when `pkg remove`
  came, and fatfs does not remove an open file (JOURNAL, "A window that
  read too often"). Manual 10.3, 10.14 (new), 13 (PACKAGES).
- **2026-11-21** — Small fixes before the printed manual: a tab drawn as
  a diamond (`Gfx.text` and `Gfx.cells` expand tabs, the agent window
  wraps them; mynos-1cz); `connect` and `connect_tls` fail with
  "timeout" after 20 s, the TLS handshake included (netd; mynos-8t3);
  `fstat` on the console is a character device, not the program's
  bytecode module (libmynos; mynos-1ev); after `netd` comes back,
  `httpd` listens again instead of asking a dead socket for ever;
  `displayd` without the Bochs VGA and `fatfs` without a disk end with 0,
  so `init` does not start them five times; a `tmpfs` read after a seek
  past the end is empty (mynos-f2d); `trace -o FILE -s N`, the System
  window's serial ports (mynos-uoq). Manual 19.4, appendix E.
- **2026-11-21** — Manual figures 12-1 and 12-2 taken again: the agent
  window's lines no longer show a tab as a diamond. The other figures
  differ only in clock and timing; all are to be taken again at the
  release, for the version they show.
- **2026-11-21** — Applications as packages (mynos-vws, from
  `tmp/ocaml-apps-ideas.md`). `pkg`: dependencies (installed first), data
  packages, a package's commands as scripts of one line that run its
  program, the window to run from Packages (`run`), its documentation
  (`doc`), `pkg search`, `pkg upgrade`; the Packages window shows the
  commands and what a package needs, and Run only for windows. `sh` runs
  a file whose first line is `#!PROGRAM ARGS` (OCaml's bytecode, which
  starts with one too, excepted). New packages: `utils`, `calc`, `mines`,
  `blocks`, `snake`, `sudoku`, `life` (the manual's, with patterns and
  RLE files), `solitaire`. Seventh boot: `utils` and `calc` installed, a
  pipe through `sort`, `head` and `grep`, `calc`, a `#!/sh.byte` script.
- **2026-11-21** — More packages (mynos-vws): `zmachine`, a Z-machine
  interpreter in OCaml (`Zvm`: runs until it needs a line, a key or a
  file name; a window in the graphical session, the terminal outside
  it); Czech's 406 tests and all of Praxix's pass, Zork I to III play.
  `view` (PNG with an inflater of its own, interlaced and with palettes
  too, BMP, PPM/PGM/PBM) and `paint` (pencil, brush, shapes, fill;
  saves PNG, compressed by a small deflate). A package of data can have
  commands: scripts that run the window it names (`#!zmachine STORY`). A
  package's sources may be another's (`paint` uses `view`'s). Seventh
  boot: `zmachine` installed, Czech run (`tests/zmachine`).
- **2026-11-21** — Packages `wiki` (Wikipedia's API, in a thread so the
  window keeps answering), `feeds` (RSS and Atom, a small XML reader of
  their own; `/disk/feeds.txt`), `manual` (the chapters of
  `doc/manual`; `man pkg`, `man Gui`, `man -k`, `man 13`, a screenful at
  a time on the console; a window with the chapters and a search),
  `scheme` (OCS 1.0.3, changed for OCaml 5: Scheme strings as `bytes`,
  ports on channels, `(exit)`; `third_party/ocs/MYNOS.md`). The agent
  reads the tools of the installed packages (`/disk/pkg/*/tool.json`):
  tried with a model, it used `calculate` and `wikipedia` unasked.
  `Gui.scroll_to`. Lua-ML was looked at and left out: it is Lua 2.5
  (1996), not the Lua of today. Seventh boot: a Scheme file run, `man
  pkg`.
- **2026-11-21** — `displayd`'s timer checked the windows' deadlines
  every 100 ms, so no window got more than 10 ticks a second (`snake`,
  `blocks` and every animation were capped there); it now checks every
  10 ms for 2 s after a window asks for a shorter one. Packages `camlboy`
  (CAMLBOY by linoscope, MIT, its library unchanged; a window of MyNOS's,
  frames run by the clock, keys held for a moment after each press since
  windows get no key release), `tobutobugirl` (Tangram Games' Game Boy
  game, MIT and CC BY 4.0), `minotaur` (a text adventure of ours: a
  message crossing the registry, fatfs, ata and its interrupt, past the
  Minotaur who keeps the ports). CAMLBOY's benchmark inside MyNOS: 357
  frames a second under KVM, 18 without. Seventh boot: `minotaur`.
- **2026-11-21** — Each package has its documentation (`DOC`), which
  `pkg-build.sh` also writes to `OUTDIR/docs/NAME.md` for the packages'
  repository, whose page lists them all; `package.json` repeats
  `program` and `sources` for the `pkg` of 2026-11-20. Manual: 9.8 (a
  package's commands and needs, `pkg search`, `pkg upgrade`, the manual
  as a package, the repository's page for what comes after the book),
  10.14, 12 (the packages' tools), 13 (PKG), H.9 (the spec's other
  fields): a paragraph or a row each.
- **2026-11-21** — Packages `zork1`, `zork2`, `zork3` (mynos-vws): the
  story files Microsoft published under the MIT licence in 2025
  (`third_party/zork`, unchanged), packages of data that need
  `zmachine`. Installed from the host's copy and played in QEMU (the
  first moves of each). Published to ctrl-z-bg/mynos-packages, with the
  `zmachine` page that names them.
- **2026-11-21** — `httpd` receives files from the host (mynos-god):
  `curl -T FILE http://localhost:8080/PATH`, or the Upload form at the
  end of each listing; allowed to 10.0.2.2 on QEMU's user network, to
  anyone with `-w`; Host and Origin checked. Tested in the seventh boot
  (PUT, a form of two files, llm.env and a foreign Origin refused, the
  files read back by MyNOS). The menu's Applications (mynos-r33). KVM in
  the start scripts: `run-demo.sh` sets `KVM=1` when `/dev/kvm` can be
  used (`run-qemu.sh` adds `-accel kvm`; the tests do not set it), and
  the release's `run-mynos.sh` uses it unless `--no-kvm`. The manual
  (1.4) says where the up-to-date manual and the packages' documentation
  are (mynos-imk). The package `manual` renders quotes (">", the MyNOS
  FACTOR boxes and chapter 2's page of 2002) as boxes with a bar,
  ~~struck~~ text, rules ("---"), and leaves pictures out; they came out
  as raw marks.
- **2026-11-21** — Key releases (mynos-ap3): consoled's raw mode with
  `CONSOLE_RELEASES` (bit 8) follows each key with its release (kitty's
  form, `ESC [ code ; 1:3 u`); displayd asks for it, splits the input
  into one event per key and sends `Key_up`; `Gui` has `released` and
  `held` (cleared when the focus goes). camlboy presses and releases the
  Game Boy's buttons as keys are held: Right held and a jump no longer
  stops Mario. Test: `tests/keys` in the graphical session (two keys held
  at once, then released). All packages rebuilt (their bytecode holds
  `Display`).
- **2026-11-21** — Disk writes 6 times faster under KVM (mynos-ipg): a
  copy of 1 MB inside MyNOS from 7.6 s to 1.24 s, of 3 MB from 23 s to
  4.5 s. `fatfs` writes the clusters that follow each other in one
  request and keeps a file's chain as an array (it was walked, and
  appended to one cluster at a time, at every write); `ata` writes 16
  sectors a block (`WRITE MULTIPLE`) and flushes the drive's cache half a
  second after the last write, by a domain, instead of after every
  write (each flush is a sync of the image on the host); `Block.Flush`
  (block/1 case 3), which `init` calls before the power goes. What is
  left is KVM's: `rep outsw` costs a trip to QEMU per word (64 writes of
  32 sectors: 1.3 s under KVM, 0.09 s without; reads are fast in both).
  32-bit PIO or DMA would be next: not done.
- **2026-11-22** — The Packages window's Remove failed now and then
  ("package.json: Permission denied"): the window read the selected
  package's `package.json` at every frame (for Run), and fatfs does not
  remove an open file. It reads it with the installed list, at the start
  and after each job; `pkg` tries a file it cannot remove again for a
  second (the Applications window may be reading it).
- **2026-11-22** — Sound (mynos-7jn, `doc/decisions/sound.md`): the
  kernel's DMA area (call 29), `soundd` (SB16 driver and mixer, sound/1),
  module `Sound`, `play`; `SOUND` in run-qemu.sh, chosen by run-demo.sh
  and run-mynos.sh (`--no-sound`); the web page wakes the browser's
  audio. Measured first with a prototype: QEMU's recording and v86's
  samples (the browser's speaker adapter played from Node) both at 440 Hz.
  Test: seventh boot, a WAV file and a tone recorded by QEMU and checked
  by frequency. Manual: appendices A, B, E (new E.15, the next renumbered),
  chapters 5, 13 (PLAY), 24, H.
- **2026-11-22** — The System window shows the sound card: a Sound
  device (IRQ 5) wired to `soundd`, which it now places among the drivers.
- **2026-11-22** — Resizable windows (mynos-1e9): displayd draws a grip
  at a resizable window's bottom right corner (an outline while dragged)
  and maximizes it on a double click on its title; display/1 gets the
  event `resize` and the requests `resize` (new shared pixels) and
  `resizable` (a minimum size). `Gui.run ~resizable`, `Gui.width`,
  `Gui.height`. The Terminal resizes its grid (lines that no longer fit
  go to the scrollback) and tells the programs inside through console/1's
  new `size` (libmynos's `TIOCGWINSZ`, `Console.size`: sh's line editing,
  edit through notty, man's pager). Resizable: Terminal, Files, Packages,
  Applications, Log, Agent, Tour, and the packages manual, wiki, feeds,
  view. System, Recordings, Services and the games stay fixed. Test: the
  graphical session drags tests/keys's grip and maximizes it.
- **2026-11-22** — The manual's timeline (4.4) has 21 and 22 November:
  the packages, httpd's uploads, KVM, key releases, faster disk writes,
  sound, resizable windows.
- **2026-11-22** — Reinstalling paint just after a publish failed: "its
  BLAKE2b hash is not the index's". raw.githubusercontent.com served the
  index from its cache (5 minutes, the previous build's) and the archive
  fresh. Archives now carry the start of their hash in their name
  (`NAME-VERSION-HASH.tar`, tools/pkg-build.sh), and
  `tools/pkg-publish.sh` publishes into a clone keeping the previous
  index's archives: a cached index finds its own. pkg is unchanged.
- **2026-11-22** — Text and its text box (mynos-y87.1, .2,
  `doc/decisions/studio.md`): module `Textarea` in mynos.cma (lines,
  selection by mouse and Shift, undo/redo, clipboard, find, colours with
  OCaml's built in, marks, ranges read and replaced); `text` on the RAM
  disk, the MyNOS menu's Text, Files' Edit. consoled sends Shift with the
  arrows, Home and End as xterm does (`ESC [ 1 ; 2 A`), released with the
  modifier. Test: the graphical session types in Text and saves.
  Next: MyNOS Studio, a package (the epic mynos-y87).
- **2026-11-22** — Kernel: Exit with a window program started from a
  Terminal hung the system (the kernel spun in `__lock`): a thread woken
  by a `V`, which hands it the semaphore's lock, and killed before it ran
  kept that lock for ever. Threads now remember a handed lock
  (`semHeld`), freed by `endProcess`. The kernel's Makefiles track header
  dependencies (`-MMD -MP`). Found by MyNOS Studio's test.
- **2026-11-22** — MyNOS Studio, the package `studio` (mynos-y87.3-.7,
  `doc/decisions/studio.md`): tabs on Textarea; Build with the ocamlc
  inside MyNOS (errors marked and listed), Run with Studio as the
  program's console (studiorun<pid>); Watch under the event recorder
  (whom the program talked to, nested calls, the slowest); New service
  (a typed service from a template), Run as service, Restart; completion
  from the running services' descriptions; Studio is a service, ide/1
  (studio<pid>), and its agent pane is MyNOS's agent given it: a replace
  shows as lines removed and added and waits for Allow. Tested by hand
  with a real model (read, replace, build); the graphical session's test
  installs it and runs its first program.
- **2026-11-22** — The clipboard, a service (mynos-vlr): `clipboard`
  (`services/clipboard`, started by init, protocol clipboard/1, module
  `Clipboard`); Textarea and Gui's fields copy and paste through it, a
  Terminal pastes on a right click, utils' `clip` from sh. Windows ask
  before closing with unsaved changes (mynos-ia2: `Gui.run ~unsaved`;
  Text, Paint, Studio). utils 1.1: `df` (mynos-0nc), on fs/1's new
  `space` (memrofs, tmpfs, fatfs). Tests: the seventh boot's df and clip.
  Studio 1.1 keeps its files in `/disk/studio/`; Paint 1.1.
- **2026-11-22** — Studio 1.2: completion from any module's interface too
  (`Gui.`, `List.`, `Graphics.`: `ocamlc -i` on `include M`, once a
  module, in a domain), beside the running services' requests.
- **2026-11-22** — Package documentation with pictures (mynos-9q1):
  `packages/NAME/images`, published as `docs/NAME/` in mynos-packages;
  `tools/pkg-shots.sh NAME` makes them from `packages/NAME/shots.sh`
  (a clean disk, the package from `tmp/packages`). Studio's README has
  seven, the agent's among them. Studio: a completion list that said
  "reading" for ever is asked again when an interface has been read.
- **2026-11-22** — Selecting text with the mouse: the Terminal (cells,
  lines numbered across the scrollback; mynos-b3k) and every Gui window
  (mynos-anc: what `label`, `paragraph` and the new `Gui.text` draw is
  registered each frame; a drag or a double click selects, copied on
  release). Log, agent, Services, Recordings, Tour, Files, System,
  Studio's panes, manual, wiki, feeds, zmachine draw with `Gui.text`.
  Test: lane d's double click and right click in a Terminal.
- **2026-11-22** — Manual: Smalltalk among the systems of chapter 3.2
  (the liveliness MyNOS gained: messages, self-description, the
  Services window as an inspector), a note in 17.6, appendix J.
- **2026-11-22** — Ask MyNOS (mynos-gi1): module `Voice` (the agent as
  the system, in the first person, with tools that observe it: state,
  log, services, a request, a few seconds of the recorder, the manual);
  `Agent.create ?system ?record ?extra`; the agent window started as
  `ask.byte` is "Ask MyNOS" (menu, after Text: Exit moved to y=369) and
  serves `mynos` (mynos/1). Tried with a real model. The volume in the
  top bar (mynos-asq): displayd asks soundd (sound/1 volume), a slider,
  the wheel. Recording from a microphone: not with QEMU's SB16 (no ADC);
  it needs another card's driver (see the evaluation in the work log of
  this day).
- **2026-11-22** — Bigger screens (mynos-wjd): `gui WxH` (kept in
  `/disk/.display`; `once`), display/1 `start_at` (13); displayd maps
  all the video memory (BGA register 10) and checks a size against it;
  the picture's offset past the text-mode memory rounded up to whole
  rows. 1280x800 and 1920x1080 tried in QEMU.
- **2026-11-22** — GAV in OCaml (mynos-0ns), package `gav`: GPL Arcade
  Volleyball's physics, players and computer players ported from the
  C++ (github.com/ctrl-z-bg/gav), its classic pictures in
  `third_party/gav`; 1 or 2 players a side, keyboard or computer; steps
  of 20 ms; tones through the sound service; `GAV_DEBUG=1` logs the
  ball. Test: the seventh boot installs it (its pictures read).
- **2026-11-22** — camlboy 1.1 has sound (mynos-7k4): measured first,
  60 frames a second under KVM with room to spare (CAMLBOY's benchmark:
  357); `third_party/camlboy/src/apu.ml`, MyNOS's (the DMG's four
  channels, the frame sequencer, the output's high-pass filter), routed
  by small changes to CAMLBOY's bus; samples sent by a thread (a domain
  slowed it to 54: JOURNAL); off by itself below 50 frames a second; M
  mutes. The music checked offline: the spectrogram of Tobu Tobu Girl's
  first 25 s shows notes (G1, G2, G3, D2, C5...). GAV 1.1: its tones
  from a thread too.
- **2026-11-22** — A web browser, phase 1 (mynos-asr), package
  `browser`: a tolerant HTML tokenizer (entities, Latin-1 and
  Windows-1252 converted), a layout as lines of styled spans (headings,
  lists, quotes, tables as rows, pre, links), http/https/file/about,
  redirections, history, fetches in a thread; `browser --dump URL`.
  Tried on text.npr.org and Wikipedia over HTTPS. Not yet: pictures,
  forms that send, cookies, CSS.
- **2026-11-22** — The package gav renamed gavml (GavML: GAV in OCaml for
  MyNOS); its pictures stay in `third_party/gav`.
- **2026-11-22** — gavml 1.1: its players' choice in the game's look (black,
  the field's border, its font); `GAVML_DEBUG=1` logs frames and their cost.
  Measured: 50 frames a second with or without KVM, sound on file, none or
  PipeWire (each frame about 3 ms without KVM).
- **2026-11-22** — soundd pauses the card after 20 s of silence (was
  0.5 s: GavML froze at each beep under QEMU with PipeWire, as reported;
  JOURNAL). gavml 1.2: M, or a button, turns its sounds off.
  displayd asks soundd for the volume without its lock (the pointer and
  the windows never wait for soundd).
- **2026-11-22** — With sound, run-demo.sh and run-mynos.sh open QEMU's SDL
  window, not GTK's: GTK's froze (QEMU's main loop spinning) while the
  SB16 played (JOURNAL). soundd pauses after 20 s of silence.
- **2026-11-22** — `gui sizes`: the usual screen sizes the video memory
  holds (display/1 `sizes`, 14).
- **2026-11-22** — gavml 1.3, GAV phase 2 (mynos-7j5): the network game,
  GAV's UDP protocol (port 7145; register 5 bytes, keys 2, snapshots 32,
  big-endian), so with GavML or GAV for Linux: a place may be "network",
  Join a game plays at another's. Receiving in threads. `UDP=PORT`
  (run-qemu.sh, run-demo.sh) and `run-mynos.sh --udp PORT` forward a UDP
  port. Tried with two MyNOS under QEMU, one joining through the host.
- **2026-11-22** — browser 1.1, phase 2 begun (mynos-vtq): pictures, PNG
  and JPEG (`jpeg.ml`, baseline: Huffman, IDCT, any chroma sampling,
  restart markers; checked against PIL: 52 dB at 4:4:4, the chroma's
  nearest-sample upsampling below that), fetched by a thread after the
  page, laid out at their size on lines of their own, narrowed to the
  page, clickable in links; icons stay text. Gui's fields: Ctrl-U.
- **2026-11-22** — browser 1.2, phase 2 done (mynos-vtq): forms (text,
  password, checkbox, radio, select, textarea, buttons; GET and POST,
  urlencoded; the values kept outside the layout, so a new layout keeps
  them) and cookies (in memory, by domain, sent with pages and pictures).
  Tried: a search on lite.duckduckgo.com (POST).
- **2026-11-22** — browser 1.2, phase 3 (mynos-28y): simple tables as
  grids (columns from their words' widths, narrowed to fit, cells laid
  out at their width); a little CSS (hidden attribute, display:none and
  visibility:hidden in styles and in simple rules of `<style>` blocks;
  readable text colours). Test: a form's fields and a grid in --dump.
- **2026-11-23** — Docs: the manual's table of run-demo.sh's variables (5.5)
  and appendix H list `UDP` and `QEMU_DISPLAY`; GUI's entry in chapter 13
  has `gui WxH [once]` and `gui sizes`; the release README has `--udp`.
- **2026-11-23** — Docs: the timeline's 22 November in full, and a line for
  the 23rd; the README describes the graphical session of now and the
  packages; the book built again at 160x235 mm, the printer's format.
- **2026-11-23** — Phase 0 of the external pager (mynos-0ho, for
  mynos-vzp): the kernel counts the page faults it resolves, by process and
  kind (system call 36, `Mynos.faults`, `ps -f`); `tests/bench/bench`
  measures a fault, a system call, a thread switch, an IPC round trip
  between processes (4 bytes, a page) and a 4 KB file read. Under KVM: a
  fault 2.9 µs, an IPC round trip 5.5 µs, a 4 KB read from fatfs or tmpfs
  about 60 µs; without KVM about 5 to 10 times more. Faults cost two thirds
  more than they should: pages zeroed and copied a byte at a time
  (mynos-4d6).
- **2026-11-23** — Page faults three times faster (mynos-4d6): the
  kernel's kmemcpy and kmemset copy and fill four bytes at a time (rep
  movsl, rep stosl); a fault 0.92 µs under KVM (was 2.85), a copy on write
  1.18 µs (was 3.0).
- **2026-11-23** — The external pager, phases 1 to 3 of mynos-vzp
  (doc/decisions/pager.md, appendix B.14): the page fault handler keeps
  EAX on the stack, not at address 0, and may wait; entries not present
  with bit 9 belong to the pager, with a token; native call 37 (register,
  region, next, supply), told like a driver of its IRQ; fork keeps those
  entries, system calls and messages refuse them, the pager's end ends who
  waits. `pagerd` (OCaml, pager/1, module Pager) maps files read-only,
  each page read when first touched; `mapcat` (-c compares, -t times, -s
  stats). Tests: eleven pager checks in tests/abi, mapcat in the seventh
  boot.
- **2026-11-23** — 2 GB of memory by default (run-demo.sh, run-mynos.sh;
  was 256 MB). Tried with 512 MB to 4 GB: MyNOS uses up to 3583 MB (32-bit,
  no PAE, the RAM in one piece multiboot reports; from -m 3584 QEMU puts
  what is above 3 GB past 4 GB, and MyNOS sees 3 GB), and three processes filled
  700 MB each and read them back with 3 GB. About 80 MB in use after a
  boot; QEMU takes from the host only what is touched. The browser
  version (v86) keeps 256 MB.
- **2026-11-23** — A lost wakeup in wait4 fixed: two threads of a
  process waiting for two different children; a child's end woke only one
  thread (a V on the process's childSem), and if it was the other's, the
  right one slept on. Studio froze so: its agent waited for a program that
  asked Studio's service for a build, whose thread waited for ocamlc. Now
  each waiting thread waits on its own private semaphore, and a child's
  end wakes them all. A check in tests/abi.
- **2026-11-23** — Gui's one-line fields have a cursor (the agent's
  question, Find, names): a click places it, Left, Right, Home, End,
  Ctrl-A, Ctrl-E move it, Backspace and Delete erase around it; until now
  only the end could be erased. A new package, `sysmonitor`: CPU and
  memory with two minutes of graphs, the file systems, the processes
  (CPU, memory, threads, faults a second, services), ending one; the
  kernel gives a process's statistics (native 38: CPU ticks, faults,
  resident pages, threads) and counts the idle process's ticks (slot 0),
  which were not counted.
- **2026-11-23** — browser 1.3: `@media` blocks of `<style>` evaluated for
  the window's width (their rules were applied always: Google's cookie
  notice hid its own buttons, a rule for narrow screens), other @ blocks
  skipped; an element's own `display` beats a hiding rule. Packages built
  before the field cursor keep the old Gui (they link it): browser rebuilt
  with it. Google's search itself needs JavaScript.
- **2026-11-23** — Packages tried before publishing: `PKG=local
  tools/run-demo.sh` serves tmp/packages from the host (port 47120) and
  writes /disk/pkg/url and /disk/pkg/autoupgrade; `pkg boot` (init.rc)
  upgrades then at boot; `pkg upgrade` reinstalls a package whose archive
  changed with the same version (`installed` keeps its hash). Without
  PKG=local the two files go. Tried on a clean disk: install, a rebuilt
  package upgraded at boot, back to GitHub. browser 1.4: DuckDuckGo lite
  on the start page.
- **2026-11-23** — run-demo.sh PKG=local waited for ever on a disk with
  /pkg (mtools' mmd asked what to do with the folder, on the terminal):
  mtools read no terminal now. pkg boot writes to the system's log, not
  the console (its lines hid sh's prompt). pkg-build keeps a package's
  previous archive when only its "mynos" field changed (every commit made
  every package new, and PKG=local reinstalled them all). browser 1.5:
  the form fields edit at a cursor (a click, Left, Right, Home, End,
  Delete).
- **2026-11-23** — browser 1.6, CSS "level A" (packages/browser/css.ml):
  the page as a tree (the ends HTML leaves out added), its <style> blocks
  and style sheets (fetched in parallel; the page shows first and takes
  its style after), @media, selectors with combinators, the cascade with
  an index by id, class and tag, var(); display, visibility and the
  "visually hidden", colour, weight, decoration, text-align, white-space,
  text-transform, list-style, margins as blank lines. Measured first:
  Markup.ml and Lambda Soup parse 13 times slower than the browser's own
  tokenizer (tmp/soup-bench). Wikipedia under KVM: 938 rules, the cascade
  150 ms (1 s before an index of the rules and of each element's classes).
  Not published yet: tried with PKG=local first.

- **2026-11-23** — The external pager, phases 4 and 5 of mynos-vzp: the
  kernel gives the pager three more operations (native 37: query, evict,
  copy; the Accessed and Dirty bits). `pagerd` keeps a budget of resident
  pages (2048, `Pager.set_budget`), takes pages back by the clock, keeps
  memory (`Pager.alloc`) and private mappings' changes in `/disk/swap`,
  writes shared mappings' changes back to their files (`sync`, `unmap`,
  eviction). C's `mmap`, `msync`, `munmap` of a file go through it
  (libmynos remembers each open file's path). The kernel's own memory
  still has no swap, by choice. Tests: five more pager checks in
  tests/abi, `mapcat -a/-w/-p` in the seventh boot, C's mmap in stdio.
- **2026-11-23** — malloc 18 times faster for C programs (mynos-a0w):
  libmynos's wrapper of malloc, free and realloc (safe_alloc.c, 2002, for
  dietlibc) took a kernel semaphore at every call, two system calls. Now
  it takes it only in a process that made native threads
  (mynos_threadCreate), which musl does not know of; the others call
  musl's allocator straight, which locks by itself after pthread_create.
  2 million malloc/free: 1.61 s, now 0.09 s (Linux 0.08 s). NetSurf work
  resumed (mynos-1g0).
- **2026-11-23** — The timer at 1000 Hz (mynos-zeu; it was 100 Hz): a
  sleep of 1 ms lasted 20, now 2; the clocks have 1 ms resolution. The
  scheduler keeps its 10 ms quantum (a round every 10 ticks, or sooner
  to wake a sleeper or leave the idle thread); `times`, native 38 and
  the recorder still report ticks of 10 ms. NetSurf loads a saved
  Wikipedia page in 0.68 s (4.28 s at 100 Hz; Linux 0.23 s). Without
  KVM the faster timer costs about 5% of computing; the suite's lanes
  last the same (e 662 s, d 469 s at 1000 Hz; 665 and 470 at 100 Hz):
  the whole run is about 11 minutes, not the 4.5 noted before.
- **2026-11-23** — NetSurf ported (ports/netsurf, doc/decisions/netsurf.md,
  mynos-1g0): its sources downloaded (version and SHA-256 fixed),
  patched, built in a container of its own (tools/containers/netsurf).
  Two pieces of MyNOS's: a libnsfb surface, a window of displayd
  (display/1), and an HTTP fetcher over netd's sockets (net/1, TLS by
  netd); ten patches in all. In MyNOS: links, the keyboard, the address bar, JavaScript, and
  Wikipedia's article on OCaml over HTTPS in about 10 s, without images.
  How it reaches users is not decided yet.
- **2026-11-23** — NetSurf shows images (ports/netsurf, mynos-1g0): PNG,
  JPEG (libpng, IJG libjpeg) and SVG (libsvgtiny over expat), built with
  musl like the rest; the program loads 3.75 MB of its 4 MB. SVG needed
  three fixes: the framebuffer front end drew no paths, libsvgtiny
  misread relative `q` and `t`, and a clip outside the window failed the
  next plot. Wikipedia's article on OCaml: its logo, the OCaml logo, the
  icons, in about 5 s.
- **2026-11-23** — netd resolves many names at once: lwIP's DNS tables
  (4 by default) refused the fifth request for a name being resolved, and
  NetSurf lost seven of a page's images. NetSurf keeps its connections
  open (4 per server): on Wikipedia's article on OCaml, 8 TLS handshakes
  instead of 26, no fetch failed, 5.1 and 5.4 s (was 8.0); with 2 per
  server 3.9 to 7.2 s. What is left is mostly stalls of about 1.5 s that
  come from the NE2000 under QEMU (mynos-bix, open).
- **2026-11-24** — netd allows 32 TLS connections (two altcp pcbs each:
  the default stopped at 16, "out of memory"); NetSurf keeps at most 12
  open, closing idle ones. Tried on seven sites: Hacker News, DuckDuckGo
  lite fine; ocaml.org, Repubblica, BBC readable with faults; GitHub
  broken. Most faults are NetSurf 3.11's (libcss has no var(), no
  gradients, no grid layout); the port's own: one bitmap monospace font,
  no WebP (BBC's images), network stalls (mynos-bix). QEMU's ne2000
  checked: a frame that finds the ring full is dropped, not held.
- **2026-11-24** — NetSurf draws text with FreeType and the DejaVu fonts
  (ports/netsurf: FreeType 2.13.3 with the TrueType modules only, eight
  DejaVu faces in /disk/ns/fonts), not its bitmap monospaced font: Hacker
  News, Wikipedia and ocaml.org look as they should, but for NetSurf's
  own limits. The program loads 3.92 MB of its 4 MB.
- **2026-11-24** — NetSurf's address bar: a click selects all of it,
  typing replaces it (Ctrl-A, Delete too); words are a web search,
  DuckDuckGo's lite page by default, also on the welcome page. Google's
  results need JavaScript beyond NetSurf's (a blank page): not fixable
  here. Repubblica's faults (captions over photos, cut columns) are
  NetSurf's: its style sheets use grid layout, gradients and var().
- **2026-11-24** — Correction: Google search works in NetSurf, over plain
  HTTP (the results come in the page; over HTTPS, through JavaScript
  NetSurf cannot run). The address bar and the welcome page search Google
  over HTTP by default (the user's choice; unencrypted), DuckDuckGo next.
- **2026-11-24** — Kernel: `cld` at every entry. Since 2026-11-23 the
  kernel's copies are `rep movsl`, which follow the direction flag, and a
  program interrupted with DF set made them run backwards: the timer's
  switch wrote a TLS descriptor over the user data segment's, and the
  system faulted in the kernel (NetSurf on Slashdot, one time in four).
  Found with a hardware watchpoint through QEMU's gdb server. A check in
  tests/abi.
- **2026-11-24** — Before the book's freeze: `mynos_threadSelf` and
  `mynos_threadCreate` give the system-wide thread id, gettid's (they
  gave a per-process count; mynos-8t3). `fork` copies only the calling
  thread (it copied every thread, ran one, and counted all), returns
  `-ENOMEM` and frees the child's pages when memory runs out (it leaked
  them and returned -1); `fstat64` answers only for the bytecode's
  descriptor, `pause` gives `-EINTR`; log lines name the pid, not the
  slot. Gfx's clip is per domain; `Mynos.wait` tells a missing child
  from a failure; `Mynos.console_mode` raises without a console
  (mynos-1ev). Checks in tests/abi.
- **2026-11-24** — BSD sockets for C programs in libmynos
  (`mynos-lib/src/socket.c`, mynos-t9l): IPv4 TCP and UDP over `net/1`,
  `getaddrinfo`, `read`/`write`/`close` on a socket through a hook in
  `fileio.c` (programs without sockets do not link them). OCaml's `Unix`
  sockets work too: `ocamlrun` links them. Blocking only (mynos-x8i).
  tests/net/sockets.c and a `Unix` check in the network test.
- **2026-11-24** — `poll`, `select`, `ppoll`, `pselect` in libmynos
  (mynos-x8i), and non-blocking sockets (`O_NONBLOCK` through `fcntl` or
  `ioctl(FIONBIO)`, `SOCK_NONBLOCK`, `MSG_DONTWAIT`: `EAGAIN`). Two
  requests added to existing protocols: net/1 `poll` (case 14: pairs of
  socket and events, answered as soon as one is ready) and console/1
  `ready` (case 6), served by consoled, the Terminal window and Studio's
  runner. `select` with no descriptors now sleeps. Checks in
  tests/net/sockets.c and tests/stdio (stdin typed and piped).
- **2026-11-24** — NetSurf reaches users as `ports/netsurf` only (the
  owner's decision for the book's version): no package, nothing in the
  system image; `pkg` unchanged (doc/decisions/netsurf.md). Published
  to mynos-packages: browser 1.6 (CSS) and Studio 1.4 rebuilt (its
  runner answers console/1 `ready`); the other packages stay as they
  were, since they run unchanged on this system.
- **2026-11-24** — The old website's archive (doc/website) has all
  fourteen SourceForge news items: the four older ones (2002), never
  captured by the Wayback Machine, taken from SourceForge, which still
  publishes them; the home page's "Site news archive" points to
  `news.html`.
- **2026-11-24** — doc/old-notes: twelve notes kept in the original
  project (excerpts of alt.os.development and other discussions,
  2002-2004: software task switch, threads, signals, microkernel IPC,
  drivers in user space, ATA, INVLPG), e-mail addresses removed, with a
  README that sets them beside MyNOS's history.
- **2026-11-24** — The book reviewed against the code, chapter by
  chapter, before its freeze: some ninety statements made true again
  (the boot's processes and pids, init.rc, 2 GB, the ata driver's
  walkthrough, display/1 and console/1 tables, the reference pages'
  synopses, the recorder's event kinds, the build and the tests); the
  timeline has 24 November; the preface points at section 20.6. Still
  299 pages. The recorder named console/1's requests wrongly since
  2026-11-22 (a Write shown as Size): fixed, with net/1 Poll and
  console/1 Ready named.
- **2026-11-24** — `top` in the package `utils` (1.2): the processes,
  the busiest first (CPU %, memory, threads, page faults a second), the
  processor's load and the memory in use, from native call 38 as
  sysmonitor; on the console it redraws every second until `q`, `-b -n
  N` prints N tables. Set aside on 2026-11-21 because the kernel kept no
  CPU time or memory per process; it does since 2026-11-23. Tried in
  MyNOS. Published to mynos-packages with manual 1.2, the chapters as
  the printed book has them.
- **2026-11-24** — Up and Down in a terminal window's line mode: the
  OCaml toplevel (and any program that reads lines) gets back its last
  lines there too, as on the console. The window keeps the last 64 and
  shares them with consoled through `/disk/.history`. The graphical
  test checks it (`cat`, a line, Up, Enter).
- **2026-11-24** — Line mode edits the whole line, in consoled and in
  terminal windows: Left and Right, Home and End (Ctrl-A, Ctrl-E),
  Delete, and typing or Backspace in the middle of the line. On the
  console, from the keyboard and from the serial port's escape
  sequences. The OCaml toplevel and `cat` get it; `sh` keeps its own.
  The console and graphical tests check it.
- **2026-11-24** — `httpd` serves `/disk/web`, not the whole of `/disk`,
  and writes uploads (`PUT`, the form) there: it makes the directory at
  its first start. `httpd /disk 8081 &` still serves the whole disk.
  Hidden and `.env` files stay refused in any directory. The manual's
  chapter 9 lost its warning about what is on `/disk`.
- **2026-11-24** — Version 2 begins, on branch `next` (from `main` at
  a56a094; `main` stays version 1, the book's, and is merged into `next`
  while the book changes). Its first step, `arch-split` (mynos-btq.1):
  the i386's code in `mynos-core/kernel/arch/i386` (start.asm, GDT, IDT,
  TSS, the task switch, port I/O, PIC, PIT, the delay calibration, the
  entries into the kernel, kmemcpy/kmemset), behind `arch.h` for what
  generic code asks of the processor; generic code has no inline
  assembly left. Still i386-shaped in generic code, for the x86-64 step:
  the TSS as the thread, two-level page tables, the Linux ABI's
  handlers (doc/decisions/arch.md). Full suite unchanged, 174 checks.
- **2026-11-24** — virtio, first part (mynos-btq.2, doc/decisions/virtio.md;
  the owner chose C and virtio 1.x over PCI): the kernel's `dmaAlloc`
  (call 39, contiguous RAM for a device, freed with its driver) and
  shared, level-triggered PCI interrupt lines (`MYNOS_IRQ_PCI`, masked
  at each interrupt until the driver unmasks them); `libmynos`'s virtio
  transport (`mynos-lib/src/virtio.c`); `vblkd`, a virtio disk as
  `vblk0` (block/1), which `fatfs` mounts when there is no `ata0`. A new
  boot of the suite (lane c) writes a file on a virtio disk and the host
  reads it: 176 checks.
- **2026-11-24** — virtio, second part (mynos-btq.2): `netd` drives a
  virtio network card (`services/net/vnet.c`: a receive queue, a
  transmit queue, the PCI line shared with the disk's) when it finds
  one, else the NE2000. `VIRTIO=1` for `run-qemu.sh` and `run-demo.sh`
  attaches the disk and the card as virtio devices. The suite's virtio
  boot also reaches `httpd` from the host through the virtio card: 178
  checks.
- **2026-11-24** — virtio, third part (mynos-btq.2, done): a virtio
  keyboard in `consoled`, a virtio tablet or mouse and a virtio GPU in
  `displayd`; both services start without the PC's keyboard controller.
  `dmaAlloc` gives up to 16 MB. The suite's virtio boot has no PC
  device left that it uses (`-machine pc,i8042=off -vga none`): the
  keys typed, the disk, the network and the graphical session (a click
  through QMP) are all virtio's. A bug found on the way: dmaAlloc chose
  its physical pages before the page tables of its mapping were made,
  and one of those could be inside the piece (JOURNAL).
- **2026-11-25** — x86-64 (mynos-btq.3, branch `x86-64`;
  doc/decisions/x86-64.md): MyNOS boots on x86-64 to the shell. The
  kernel in `arch/x86_64` (long mode, four-level page tables through a
  direct map, the kernel's gigabyte shared, ELF64 processes, fork, the
  native calls by `int 0x90` and Linux's x86-64 calls by `syscall`), the
  whole user space rebuilt by the `dev-x86_64` container
  (`tools/build-x86_64.sh`, in `build/x86_64/tree`): `init`, every
  service, `sh`, the OCaml toplevel with 63-bit integers. Generic code
  made 64-bit clean where it was 32-bit without saying so (multiboot,
  `size_t`, the RAM disk's directory, `libmynos`'s casts and raw calls).
  The i386 build and its suite unchanged (181 checks).
- **2026-11-25** — x86-64: the disk (FAT on IDE), the network (NE2000:
  ping, HTTPS, `httpd`) and the graphical session tried by hand; the
  text of the session was missing (`Gfx.text`'s `max_int` default
  narrowed to an `int`: JOURNAL).
- **2026-11-25** — x86-64: the suite runs at 64 bits (`ARCH=x86_64
  tools/run-tests.sh` in `build/x86_64/tree`; `run-qemu.sh` picks QEMU,
  processor and kernel by `ARCH`). 94 of its checks pass; the rest wait
  on the keyboard-driven session's timing and on a slow `ask` in the
  network test (beads). `tests/fpu/fpu` and `tests/stdio/stdio`, i386
  binaries committed by mistake, left git (JOURNAL). `abi` and `stress`
  make their raw Linux calls in either ABI; x86-64's `times` and
  `getrusage` give the CPU time; `brk` and `readlink` answered quietly.
- **2026-11-25** — The book's sources join the repository in `doc/book`
  (they were kept outside it, in `tmp/`): `build.sh` typesets
  `doc/manual` with them; the PDF stays out of git. `doc/README.md` says
  what `doc/` holds (mynos-1cf). The licences' texts next to what uses
  them: `third_party/fonts/OFL.TXT` (Terminus), `third_party/
  ca-certificates/MPL-2.0.txt` (Mozilla's authorities).
- **2026-11-25** — Version 1.0 (the version the printed book describes).
  `tools/version.sh` takes the version from git: `1.0` at the commit
  tagged `v1.0`; after it the commits since, the branch when it is not
  `main`, and the commit (`1.0+14-x86-64-591c1f4`); `-dirty` for a
  build with changes not committed. The boot's banner adds the
  processor (`Welcome to MyNOS 1.0 (i386)`). `make-release.sh` checks
  `VERSION` against `version.sh` and ships the OFL and MPL texts.
  `tests/fpu/fpu` and `tests/stdio/stdio`, binaries committed by
  mistake, leave git (found on the x86-64 branch).
- **2026-11-25** — The suite in about 8 minutes, not 11 (mynos-f18):
  each section timed, and printed at the end by lane; the keyboard-driven
  boot waits for the toplevel's prompt and for marks that sh echoes, not
  fixed times, and is four boots at once (lanes e, f, g, h: the shell and
  the editors; the agent, services, httpd and stdio; packages; Ctrl-C,
  fatfs, the disk's reads and the serial terminal), each with its own
  disk, log, sockets and host ports. Lane d (the graphical session, 480 s)
  now sets the time.
- **2026-11-25** — x86-64: the whole suite passes at 64 bits (181
  checks, in the same 8 minutes as the i386). The cause of most of its
  failures: futex's timeout pointer typed `uint32_t`, cut on x86-64, so
  every timed wait returned at once and `netd` spun (JOURNAL). The
  virtio graphical check clicks again until the Clock shows (it missed
  the welcome window on a loaded machine).
- **2026-11-25** — Both architectures' suites at once, each in a test
  container with a network of its own (`tools/run-tests-all.sh`,
  `tools/containers/test`); the graphical session in two boots (lanes d
  and i: its windows are made in the same order, so displayd places
  them where the clicks expect). i386 and x86_64, 181 checks each, in
  335 s together (mynos-f18; they took 11 minutes for the i386 alone).
- **2026-11-25** — `Mynos.machine ()` (uname's machine: `i386`,
  `x86_64`): `ask`, the agent and the System window say the processor
  they run on, not always "i386". x86-64 done (mynos-btq.3): branch
  `x86-64` merged into `next`, both architectures' suites green.
- **2026-11-25** — The kernel gives programs a real auxiliary vector
  (AT_PHDR, AT_PHENT, AT_PHNUM, AT_PAGESZ, AT_ENTRY, AT_RANDOM) on both
  architectures: it was empty, musl found no PT_TLS, and a new thread's
  `__thread` variables lay on its stack's top. On x86-64 the Terminal
  showed no program output (Gfx's clip, read as on, from the terminal's
  service domain). JOURNAL; `tests/abi` checks it. Both suites green.
- **2026-11-25** — SMP on x86-64 (mynos-btq.5, branch `smp`,
  doc/decisions/smp.md): the other processors found in the MADT and
  started, a big kernel lock, a scheduler that knows processors, LAPIC
  timers, IPIs for wake-ups and TLB shootdowns; four processors by
  default (`SMP=N`), the i386 stays at one. `tests/smp` added. Domains
  doing computation run 3.6 times faster on four. Six concurrency bugs
  found and fixed (JOURNAL). Both suites green but for the sound check,
  flaky under the host's load (mynos-cea); domains that allocate are
  13 times slower on one processor (mynos-c6a).
- **2026-11-25** — AArch64 begun (mynos-btq.6, branch `aarch64`,
  doc/decisions/aarch64.md): a `dev-aarch64` container (cross gcc, musl
  and OCaml's runtime for AArch64, QEMU), `arch/aarch64` (EL1 boot, MMU,
  GICv2, the generic timer, exceptions, calls, context switch). On QEMU
  `virt` the kernel boots, runs musl programs in EL0, and `ocamlrun`
  prints "Hello from OCaml on MyNOS!" with registry and memrofs. The
  generic memory code writes page table entries through `pte_set` (a
  store on x86), and its flags are 64-bit. Built by
  `tools/build-aarch64.sh`; modules passed as one archive
  (`tools/mkmodules.py`).
- **2026-11-25** — AArch64: the whole system builds (but four C tests
  with x86 assembly) and boots on QEMU `virt` to `sh`, typed on a virtio
  keyboard; the OCaml toplevel runs (`Sys.word_size` 64). PCI devices get
  their memory windows from MyNOS (no firmware), DMA addresses are the
  real ones. The PC's services (ata, the Sound Blaster, the Bochs display)
  end, finding nothing. Fixed on the way, for every architecture:
  `initIPC` ran after the boot's processes, which could have opened a
  port already (JOURNAL).
- **2026-11-25** — mynos-c6a: a thread woken by `FUTEX_WAKE` runs at
  once, before its waker, unless another processor idles (Linux's
  wake-up preemption, in short): OCaml domains that allocate, on one
  processor, 6.6 times faster (6.93 s to 1.05 s; doc/decisions/smp.md).
  `sched_getaffinity` on the three architectures: `nproc` (new in `sh`),
  musl's `sysconf` and OCaml's `Domain.recommended_domain_count` count
  the processors; `tests/smp` checks it. The other processors now start
  before the first process (the first programs saw one). sysmonitor 1.1
  (not published): the load of all the processors together, their
  number. AArch64: `ARCH=aarch64` for `run-qemu.sh` and `run-demo.sh`
  (QEMU from the host or the `dev-aarch64` container), the console on
  the UART (COM2's registers answered by the PL011, a native call for
  drivers' port I/O, 102), virtio disk and network card running (FAT32,
  DHCP, httpd); the four C tests in x86 assembly ported (`abi`, `fpu`,
  `stress` passing there, `bench` running: the generic timer's counter
  readable from EL0); the accessed and dirty bits the external pager
  reads kept by faults on AArch64 (ARMv8.0 has none for software); the
  PC's drivers (ata, keyboardd, seriald) end cleanly when their hardware
  is absent. `build-aarch64.sh` builds everything by default. JOURNAL.
- **2026-11-25** — MyNOS 1.0.1: the kernel gives programs a real
  auxiliary vector (it was empty: a new thread's `__thread` variables
  lay on its stack's top). Found on the version 2 line (JOURNAL);
  `tests/abi` checks it.
- **2026-11-26** — The test suite on AArch64 (`tools/run-tests-all.sh
  aarch64`; the test container has QEMU's AArch64 emulator): the PC's
  options and checks of PC hardware replaced or left out, `storage` and
  `fat` through `vblkd` where there is no IDE; a virtio GPU and tablet
  on `virt` (the graphical session runs, `run-demo.sh` shows it in a
  window with the host's QEMU); init's ACPI power off and PCI reset are
  PSCI on AArch64, the CMOS clock a PC's (BCD). Fixed for every
  architecture: the boot made its processes with interrupts on, and the
  timer could switch to one of them in the middle of a `kmalloc` (the
  kernel's heap corrupted, JOURNAL).
- **2026-11-26** — x86-64 under KVM had no graphics since SMP: drivers
  read PCI's configuration space at once through the same two ports.
  The kernel does it now (native call 103). JOURNAL.
- **2026-11-26** — SMP on AArch64 (mynos-btq.6): four processors on QEMU
  `virt` by default, started by PSCI before the first process, software
  interrupts as IPIs, no TLB shootdown needed; `tests/smp` passes on 2
  and 4. A secondary processor's stack read through the boot's tables
  (JOURNAL). The graphical session's crash on several processors was
  `copy_user` resuming a fault at its loop's start (a byte skipped);
  fixed with a timed receiver's double wake-up (every architecture), PCI
  windows assigned once by the kernel at boot, `clrex` on the way out
  (JOURNAL).
- **2026-11-26** — displayd composes from its own copy of each window,
  taken when the program says a frame is done (`damage`), never from the
  pixels the program is drawing in (GavML flickered on several
  processors). On
  AArch64, programs start slower only because the processor is emulated
  (GavML: 2.7 s; x86-64 emulated 3.0 s, under KVM 0.7 s).
- **2026-11-26** — sysmonitor 1.1 (package): the load of all the
  processors together, and their number, from the version 2 line, where
  x86-64 has four (`Domain.recommended_domain_count`; on MyNOS 1.0, one).
  Published.
- **2026-11-26** — The kernel: a receiver waiting with a timeout could be
  woken twice (its timer, then a sender or the channel's close), and its
  next wait returned at once. Found on the version 2 line with several
  processors (JOURNAL). On `main`, not released yet.
- **2026-11-27** — The Raspberry Pis' base begun (mynos-btq.7.1, .7.2;
  doc/decisions/aarch64.md, choice 11): a second AArch64 kernel,
  `kernel8.img` (`MYNOS_RASPI`), boots on QEMU `raspi3b`
  (`MACHINE=raspi3b tools/run-qemu.sh`) to the shell on the UART, with
  four processors (spin tables, local mailboxes as IPIs), the BCM2836 and
  BCM2835 interrupt controllers, the watchdog to restart and power off,
  the console drawn on the mailbox's framebuffer, and `gui` on it
  (displayd's third screen, native call 104). The PCI drivers end
  cleanly: `mapPhysical` maps only the platform's devices. No SD card,
  network, keyboard or mouse yet (btq.7.3, btq.10). JOURNAL.
- **2026-11-27** — The Raspberry Pi's SD card (mynos-btq.7.3): `sdhcid`
  drives the SDHCI controller (the block service `sd0`), and fatfs takes
  the first FAT partition of a partition table (a real card's).
  `tools/make-sd-raspi.sh` makes a card image for a real Pi 3 or Zero 2 W
  (the firmware at a fixed version, checked; `config.txt`, the kernel,
  the archive; one FAT32 partition, also `/disk`); `MACHINE=raspi3b`'s
  `DISK` is its SD card. The suite's lane j (AArch64) boots QEMU
  `raspi3b`: the UART, the SD card, the console and the graphical
  session on the framebuffer, the power off (mynos-btq.7.4). A rare
  crash of the stress test on `virt` under the suites' load is mynos-4dz.
- **2026-11-27** — Ctrl-Alt-End ends the graphical session (consoled sends
  it as xterm does, `ESC [ 1 ; 7 F`; displayd ends the session): the Pi
  has no mouse yet. displayd keeps an escape sequence a read ended in the
  middle of (a serial terminal's bytes) for the next read. Lane j uses it.
- **2026-11-27** — The Raspberry Pi 4 and 400's base (mynos-btq.8): the
  same `kernel8.img` tells a Pi 4 from a Pi 3 by its processor and uses
  its peripherals' addresses and its GIC-400; `sdhcid` drives the Pi 4's
  EMMC2; the device tree's memory is read in its root's cells. On QEMU
  `raspi4b` (`MACHINE=raspi4b`): the shell, four processors, the
  framebuffer and `gui`, the SD card, the power off; the suite's lane j
  boots it too. The SD card image has the Pi 4's and 400's firmware.
  USB (PCIe, xHCI) and Ethernet (GENET) are next, on the board (QEMU's
  model has none).
- **2026-11-27** — The Pi 4's PCIe (mynos-btq.8.1, not yet tried on a
  board): the kernel brings up the BCM2711's root complex when the
  firmware's device tree has it (`pcie4.c`: the link, the windows, the
  VL805 on bus 1 given its memory, the firmware told to load its
  firmware), and only then lets a driver map the bridge and the window;
  libmynos's PCI functions reach bus 0 and 1 through the bridge. QEMU's
  `raspi4b` has no PCIe: nothing is touched there.
- **2026-11-27** — The USB (mynos-btq.8.2, .8.3): `usbd` drives an xHCI
  (reset, rings, ports, enumeration, control transfers) and HID's boot
  keyboards and mice on the root ports (no hubs yet); their keys go to
  consoled's new `keys` service, their reports to displayd's new
  `pointer` service. Working on QEMU's `qemu-xhci` (`USB=1`; the suite's
  lane j types on a USB keyboard and clicks with a USB mouse). On a Pi 4
  or 400 it is the VL805 behind the kernel's PCIe: not yet tried there
  (the rings and contexts are kept out of the caches by hand: the
  BCM2711's PCIe is not coherent).
- **2026-11-27** — The stress test's rare crash on four processors
  (mynos-4dz) was the test's: a round's threads reused stacks whose
  previous threads were still returning. Fixed; lane j starts later and
  three checks wait for what they look for: the three suites at once
  are green twice in a row.
- **2026-11-27** — The journal split: `doc/JOURNAL.md` is again as it was
  where `next` left `main` (merges from `main` add to it without
  conflicts); the 25 entries of `next`'s own work moved, as they were, to
  `doc/JOURNAL-next.md`.
- **2026-11-27** — Retro emulators begun (branch `retro`, mynos-0bj,
  doc/decisions/retro-emulators.md): `packages/retro` (a Z80 in OCaml:
  FUSE's 1356 tests, zexdoc and zexall all passed; its disassembler; the
  protocol emu/1 and its service), the package `zxspectrum` (a 48K: the
  ULA, keyboard, beeper, `.tap` loaded at once, `.sna`, `.z80`; a window
  at 50 frames a second under KVM, `--headless`, `--bench`) and `glazx`
  (a game, MIT). The suite drives the Spectrum through emu/1 (lane c,
  `tests/emu`). Published (mynos-packages 20d0caf: zxspectrum 1.0,
  glazx 1.0).
- **2026-11-27** — The applications' journal: `doc/JOURNAL-apps.md`,
  for the packages and their shared libraries (the Spectrum's entries
  moved there); `doc/JOURNAL.md` keeps the kernel, the services, the
  system's libraries and the toolchain. The book (`doc/book`) is frozen
  until the next version.
- **2026-11-27** — camlboy 1.2 serves emu/1 (`camlboy<pid>`): registers,
  memory, screenshots, breakpoints on the PC, frames, buttons; the
  suite's lane c drives it after the Spectrum (`tests/emu`).
- **2026-11-27** — The manual's chapter 25, "Emulators as services:
  emu/1" (`doc/manual/25-emulators.md`, its example
  `examples/25/hello_zx.ml`, built by `tools/build-examples.sh` and run
  in MyNOS), and appendix E.18. After the printed edition: the book is
  frozen.
- **2026-11-27** — USB 2 hubs in usbd (mynos-btq.8.5): on a Pi 4 and
  400 every USB 2 device, the 400's keyboard too, is behind the VL805's
  own hub. Route strings, ports powered and reset, the TT for a low- or
  full-speed device behind a high-speed hub; on QEMU the keyboard now
  sits behind a `usb-hub` (`USB=1`, lane j). The SD card image
  (`tools/make-sd-raspi.sh`) is ready for the first try on a Pi 400
  (btq.8.1-3, .8.5).
- **2026-11-27** — First try on a Pi 400: MyNOS boots on HDMI with four
  processors and the PCIe's link up (the VL805 found on bus 1:
  btq.8.1 works on the board). The USB did not start: usbd mapped the
  VL805 at its PCI address instead of the processor's (libmynos's
  `pci_cpu_address` now); `VERBOSE=1 tools/make-sd-raspi.sh` keeps the
  services' messages on the screen.
- **2026-11-27** — `tools/make-sd-raspi.sh DIR`: a MyNOS card's
  partition, mounted, brought up to date in seconds (kernel8.img,
  mynos.mod, config.txt) instead of a 2 GB `dd` at every try.
- **2026-11-27** — The USB works on a Pi 400 (btq.8.1-3, .8.5 closed):
  its own keyboard and a USB mouse, in the shell and the graphical
  session, through the kernel's PCIe, the VL805 and its hub. A halted
  interrupt endpoint is now reset and read again (the mouse stopped at
  its first failed transfer). Next: the network, GENET (btq.8.4), then
  the Wi-Fi (btq.9).
- **2026-11-27** — GENET, the Pi 4's and 400's Ethernet (mynos-btq.8.4),
  written, not yet tried on the board: `services/net/genet.c`, netd's
  third card. The kernel lets a driver map it only if the device tree
  has it (QEMU's `raspi4b` has none); a new native call, 105
  (`mynos_piFirmware`), hands a driver's property request to the
  firmware's mailbox (the board's MAC address; the Wi-Fi's power next).
- **2026-11-27** — GENET works on a Pi 400 (btq.8.4 closed): a cable
  to the LAN, an address from its router's DHCP, ping 1-2 ms, MyNOS's
  httpd reachable from the LAN. The time from the network is its own
  bead now. Next: the Wi-Fi (btq.9, priority raised: the user wants it).
- **2026-11-27** — The Wi-Fi begun (mynos-btq.9, doc/decisions/wifi.md):
  `wifid` (`services/wifi/`) powers the Pi 400's CYW43456 (the
  firmware's GPIO expander), brings up its SDIO on the Arasan SDHCI,
  reads its cores, loads its firmware and NVRAM, starts it and asks its
  version and MAC address; first try on the board pending.
  `make-sd-raspi.sh` puts the chip's firmware (Synaptics's licence: not
  in MyNOS's repository) in the card's `/wifi`. Native call 106
  (`mynos_piDevices`): what the device tree has, so that wifid and
  sdhcid share the Arasan controller rightly (QEMU's `raspi4b` has its
  SD card there). A USB mouse's wheel works (btq.8.7: report protocol,
  its report descriptor parsed).
- **2026-11-27** — The Wi-Fi's first try on the Pi 400 (btq.9): the
  CYW43456 found on SDIO (7 cores), its firmware loaded and started
  (7.45.96.252), its MAC address read, at the first try. Next written:
  the CLM loaded, a scan logged, a WPA2 network joined from
  `/disk/wifi.env` (SSID=, PASSPHRASE=, COUNTRY=), its events logged;
  wifid stays up.
- **2026-11-27** — The Pi 400 joins the LAN's Wi-Fi network (associated,
  link up) but its firmware has no WPA2 supplicant: the 4-way handshake
  is now wifid's (`services/wifi/wpa.c`, its cryptography checked
  against the standards' vectors), and SDPCM's credit is respected (the
  firmware dropped commands beyond it). Second try pending.
- **2026-11-27** — Second Wi-Fi try: the host's WPA2 4-way handshake
  completes with the LAN's router (message 3's MIC right), but some
  commands' answers are still lost (the scan, the pairwise key). Frames
  are now read whether the chip signals them or not, read failures are
  logged; "connected" only once both keys are installed. llmd reads its
  `/disk/llm.env` on the Pi.
- **2026-11-27** — The Pi 400 connected to the LAN's Wi-Fi, WPA2 (the
  lost answers were SDPCM superframes: turned off). Step 4 written: wifid
  serves its frames (`wifi`, `wifirx`), netd uses the Wi-Fi when the
  cable has no link (`services/net/wifinet.c`); untried on the board.
  `mynos_piDevices` returns 0 on a PC (it returned the kernel's error).
- **2026-11-27** — Data over the Pi 400's Wi-Fi: with no cable, netd's
  card is the Wi-Fi; DHCP from the router (192.168.178.58), ping 2-6 ms
  over WPA2. httpd had given up meanwhile (netd's service came after 5 s
  of waiting for the cable's link): on a Pi with a Wi-Fi netd now
  registers its service first.
- **2026-11-27** — The Pi 400's Wi-Fi carries TCP: HTTP to and from the
  Pi over WPA2 (a 256 KB file sent and read back, the log read
  remotely); the AP still deauthenticates now and then (reason 3), the
  firmware joins again by itself (link events now timed). USB devices
  behind a hub may be unplugged and plugged again (the mouse had
  reconnected by itself and was never configured again).
- **2026-11-27** — `bench` on the Pi 400: 81 (1000 is QEMU with KVM on
  the reference PC), the processor at a twentieth of the PC's: the
  firmware leaves the ARM at its lowest clock until asked. The kernel
  now asks for the maximum at boot (`ARM clock: ... MHz`). The Wi-Fi's
  AP deauthenticates about 150 s after joining (reason 3); the firmware
  joins again in 3 s (btq.9.3).
- **2026-11-28** — The Pi 400's clock measured (cycles against the
  timer, logged at boot): 1.8 GHz from the start, though the firmware
  says 600 MHz; the bench's twentieth of the PC is not the clock, nor
  the caches, nor the interpreter's build (doc/JOURNAL-next.md).
