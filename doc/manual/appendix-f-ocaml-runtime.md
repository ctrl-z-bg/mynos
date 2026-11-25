# Appendix F. The OCaml Runtime on MyNOS

Most of MyNOS's user space is OCaml: `init`, the shells, two of the
three file services, the disk driver, the graphical session, the agent. It runs as
**bytecode**, executed by `ocamlrun`, OCaml's bytecode interpreter, which
on MyNOS is an ordinary process like any other. This appendix explains how
that runtime is built, how it chooses what to run, how it gains the
primitives that reach MyNOS, how OCaml's domains and threads sit on the
kernel's threads, what the `Mynos` library offers, and how OCaml programs
are compiled inside MyNOS itself. The code is in `mynos-runtime/` and
`mynos-lib/ocaml/`.

## F.1 One runtime, unchanged

MyNOS runs the bytecode runtime of **OCaml 5.5.2**, as it comes from
upstream: not one line of OCaml's sources is in the repository, or
patched. What MyNOS adds is around it: a `main()` of a few lines, a
regenerated primitive table, and the C stubs of the primitives it adds.
Moving to a new OCaml release is meant to be a version bump.

This is possible because of appendix D: the runtime is a C program for
Linux, built with musl, and the kernel answers its system calls. The dev
container (`tools/containers/dev/Containerfile`, Debian 13 for i386)
builds OCaml twice from the same verified source archive:

```
  ocaml-5.5.2.tar.gz ──┬─► ./configure --disable-native-compiler
  (sha256 checked)     │       /opt/ocaml-5.5.2: the compiler, for the build
  │                    │       host (glibc); bytecode only
  │                    │
  │                    └─► ./configure --host=i686-pc-linux-gnu CC=musl-gcc
  │                            LDFLAGS=-static --disable-shared ...
  │                        make runtime/ocamlrun
  │                            /opt/ocaml-runtime-musl: libcamlrun.a, the
  │                            primitive list and prims.c, the headers as
  │                            configured for musl, and the C sources of
  │                            otherlibs/unix and otherlibs/systhreads
  ▼
  mynos-runtime/Makefile:  main.o + mynos_stubs.o + gfx_stubs.o + prims.o
                           + unix/*.o + threads/st_stubs.o
                           + libcamlrun.a + -lmynos + musl  ──►  ocamlrun
```

The result is a static executable linked at `0x40000000` like every
MyNOS program, about 1.9 MB; the copy on the RAM disk, stripped by
`system/Makefile`, is about 650 KB. It links `libmynos` before musl, so
its `open`, `read` and `stat` are those of appendix D.4: the runtime reads
bytecode from the file services without knowing it.

> **THE MyNOS FACTOR — The language runtime is a guest.** Elsewhere the
> runtime of a system's main language is part of the system and changes
> with it. In MyNOS the OCaml runtime is an unmodified upstream build,
> running on a Linux interface the kernel imitates. The kernel was fixed
> to fit the runtime, never the other way round; and each new runtime
> was, in passing, the most thorough test the kernel ever had.

## F.2 Which bytecode runs

`mynos-runtime/main.c` decides what `ocamlrun` executes, and hands the
choice to the upstream `caml_main`:

| How `ocamlrun` was started | What it runs |
|---|---|
| `ocamlrun prog.byte args…` | `prog.byte`, with `args` in `Sys.argv`, as on Unix |
| no arguments, and `init.byte` exists | `init.byte`, from the RAM disk: the normal boot |
| no arguments, no `init.byte` | `mynos_bytecode`: GRUB's module 1, through the kernel |

At boot `ocamlrun` is a GRUB module with no arguments (appendix A.2).
memrofs, another module, starts at the same time; `libmynos` gives it
about a second to appear in the registry, then `stat("init.byte")` finds
`init` on the RAM disk, and `init` starts everything else. With memrofs
but no `init.byte`, the name `mynos_bytecode` is not found there, and
`libmynos` passes that one `open` to the kernel, which serves module 1
as its one file (appendix D.3). Without memrofs every `open` reaches the
kernel, and finds module 1 whatever the name. That is how MyNOS booted
in 2002;
the name `mynos_bytecode` comes from the 2002 `main.c`, which replaced
the command line with `{ "test", "mynos_bytecode" }` whatever it was.

After boot, programs are started by name. `sh` looks a command up in
`PATH` (`/disk/bin:/`), also as `NAME.byte`, and if the file is not an
ELF image runs `ocamlrun FILE args…`; a bare name such as `ocamlrun` is
taken from the root of the RAM disk (`mynos-lib/src/spawn.c`). The kernel
marks a process whose `argv[0]` is `ocamlrun` as an OCaml program, for
`ps` and the System window.

A bytecode file made by `ocamlc` begins with a `#!` line that names the
build machine's runtime (`#!/opt/ocaml-5.5.2/bin/ocamlrun-a105`). MyNOS never reads it: `ocamlrun` is given the file, and finds its
sections from the trailer at the end.

## F.3 The primitive table

OCaml code reaches C through **primitives**: functions declared
`external` in OCaml and written in C (`caml_mynos_send`,
`caml_unix_open`, …). The runtime has a table of all the primitives it
contains, generated at build time; MyNOS has to add its own without
touching OCaml's sources. `mynos-runtime/gen_prims.sh` does it:

1. it takes upstream's list (`/opt/ocaml-runtime-musl/primitives`) as it
   is;
2. it collects every `CAMLprim value NAME(` from MyNOS's stubs and from
   the unix and systhreads sources, sorts them, removes those already in
   upstream's list, and **appends** them;
3. it writes `primitives`, the full list, and `prims.c`, the table, made
   of upstream's declarations and trailer with the new names in between.
   The generated `prims.o` replaces upstream's.

| Primitives | Number |
|---|---|
| upstream runtime | 479 |
| `Mynos` (`mynos_stubs.c`) | 57 |
| `Gfx` (`gfx_stubs.c`) | 15 |
| unix and systhreads | 147 |
| Str and Num | 37 |
| **in all** | **735** |

**Why programs are compiled with `-use-prims`.** When `ocamlc` links a
program it checks that every primitive the program uses exists in the
runtime that will run it. By default it knows the standard runtime's
list, which has no `caml_mynos_send`, and refuses:

```
Error: Error while linking p.cmo:
       The external function caml_mynos_getpid is not available
```

`-use-prims mynos-runtime/primitives` gives it MyNOS's list instead.
Every Makefile that compiles OCaml in the tree sets
`OCAMLC = ocamlc -use-prims …/mynos-runtime/primitives`. The bytecode then
carries, in its `PRIM` section, the names of all the primitives of that
list, and the runtime resolves each name in its own table when it loads
the program. Primitives are therefore matched by **name**; appending
MyNOS's after upstream's keeps the standard ones in their usual places,
which is the safe choice, but not what makes it work. A program and the
runtime must agree on the list: rebuild both after adding a primitive.

## F.4 The Mynos primitives

`mynos-runtime/mynos_stubs.c` holds the primitives of module `Mynos`
(F.8): thin wrappers over `libmynos`, the C library of the native calls.
Three conventions run through it:

- **Errors** (negative `MYNOS_ERR_*` codes) raise `Mynos.Error (function,
  code)`. The exception is found with `caml_named_value("Mynos.Error")`,
  which `mynos.ml` registers when it is loaded.
- **Data leaves the OCaml heap** before it is sent: `send` copies the
  string into a `malloc` buffer, because the kernel may map the sender's
  pages into the receiver (appendix C), and the garbage collector may
  move or reuse OCaml memory meanwhile. Strings passed as names are
  copied with `caml_stat_strdup` for the same reason.
- **A call that can wait releases the runtime lock.** Before it calls
  the kernel, the stub calls `caml_enter_blocking_section()`, and
  `caml_leave_blocking_section()` when the call returns.

The third convention is the one that matters most. In OCaml 5 every
domain has a runtime lock, held by whichever of its threads runs OCaml
code. A thread that waits in the kernel while holding it stops two things:
the other threads of its domain, which cannot run OCaml code without the
lock, and the other domains, which at their next garbage collection wait
for every domain to take part. So every stub that can wait gives the lock
up while it waits:

| Releases the lock (can wait) | Keeps it (returns at once) |
|---|---|
| `send`, `recv` | `free_channel`, `channel_peer` |
| `connect`, `listen` | `alloc_port`, `free_port`, `change_port_owner` |
| `sem_p` | `sem_create`, `sem_try_p`, `sem_v`, `sem_free` |
| `sleep_us` | `getpid`, `uptime`, `time`, `stats` |
| `registry_register`, `registry_lookup`, `registry_list` | `log`, `environment` |
| `spawn` (reads the program file), `wait` | `process_info`, `processes`, `kill`, `faults`, `procstat` |
| `pager_wait` (the pager's next fault) | `pager_*` (the other pager calls), `version`, `klog_*` |
| `console_mode`, `console_foreground` (requests to the console service) | `inb`, `outb`, `inw`, `outw`, `insw`, `outsw` |
| | `driver_register`, `enable_irq`, `trace_*` |

The registry and console stubs wait because they are IPC exchanges with
another process; `spawn` because it reads a whole program from a file
service; `pager_wait` because the pager sleeps there until a page is
asked for.

The driver primitives (`inb`, `outb`, `insw`, …) are `in` and `out`
instructions executed in user space. They work only in a process with the `io`
privilege, which runs with IOPL 3 (appendix A.7); `ata`, the disk driver
written in OCaml, uses them.

## F.5 The Gfx primitives

`mynos-runtime/gfx_stubs.c` holds the 15 primitives of module `Gfx`:
filling, lines, copies, masks and text on buffers of 32-bit pixels. They
are in C because loops over pixels are too slow in bytecode. A buffer is
an OCaml record whose pixels are a `Bigarray`, allocated page-aligned with
`posix_memalign`, so that a window can share it with the display server
(`caml_gfx_send_shared` sends it with `MYNOS_IPC_SHARED`, releasing the
lock while it does). Text is drawn in the Terminus 8×16 font, read from
`/terminus16.psf` and `/terminus16-bold.psf` on the RAM disk at the first
use. The primitives of more than five arguments come in two forms, as
the bytecode interpreter requires (`caml_gfx_fill` and
`caml_gfx_fill_byte`).

## F.6 Unix and threads, built in

On Linux, OCaml's `unix` and `threads` libraries come with C stubs in
shared libraries (`dllunixbyt.so`, `dllthreads.so`) that `ocamlrun` loads
at start. MyNOS's runtime is static and loads no shared library. So
`mynos-runtime/Makefile` compiles the stubs themselves, from the sources
the container keeps (the list of files is otherlibs/unix's own), links
them into `ocamlrun`, and `gen_prims.sh` adds their primitives to the
table. `threads.cma` needs `unix.cma`, so all of Unix is there.

Programs use the compiler's own `unix.cma` and `threads.cma`, with one
flag more:

```
ocamlc -use-prims …/primitives -I +unix -I +threads -noautolink \
       mynos.cma unix.cma threads.cma -o prog.byte prog.ml
```

Without `-noautolink` the bytecode lists `dllunixbyt` and `dllthreads`
among the libraries to load at start, and the static runtime cannot load
them; with it, the primitives are simply found in the table.

That `Unix` links does not mean that all of it works. A `Unix` function
works when musl's function and the kernel's calls behind it exist:
`Unix.gettimeofday`, `Unix.sleepf`, files through `libmynos`. Those whose
system calls MyNOS lacks (`execve`, `pipe`, `dup`) fail with
`Unix_error (ENOSYS, …)`. Sockets work: `Unix.socket`, `connect`,
`getaddrinfo` and the rest reach `libmynos`'s (14.2), over the network
service; module `Net` speaks to it directly, with TLS.

Two more libraries come the same way:

- **`Str`**, regular expressions. It is part of the distribution: its
  stub, `otherlibs/str/strstubs.c`, is kept by the container too. It is
  used with `-I +str -noautolink str.cma`.
- **`Num`**, numbers of any size: `Num`, `Big_int` and `Ratio`. It left
  the distribution in 2017, so its sources (version 1.6) are in
  `third_party/num`. Its stubs are compiled with the portable C digits,
  not its i386 assembly. That directory's Makefile builds `nums.cma`
  against MyNOS's primitives, and programs use it with
  `-I …/third_party/num nums.cma`. That `nums.cma` names no shared
  library, so it needs no `-noautolink`.

## F.7 Domains, threads and effects

OCaml 5 offers three kinds of concurrency. All three run on MyNOS, and
the kernel had to do something for only one of them.

```
  OCaml                     musl                 MyNOS kernel
  ─────                     ────                 ────────────
  Domain.spawn ──────────►  pthread_create  ──►  clone: a Linux thread
  Thread.create ─────────►  pthread_create  ──►  clone: a Linux thread
  Mutex, Condition,     ──► pthread mutexes ──►  futex wait / wake
    Domain.join                and conds
  Effect.perform        ──  (nothing: the runtime switches stacks itself)
```

**Domains** are the unit of parallelism: each has its own minor heap and
its own runtime lock. `Domain.spawn` is `pthread_create`, which in musl
is the Linux `clone`, and every lock, condition and `join` behind them
is a `futex` (appendix D.7). The runtime also starts a second thread of
its own for each domain, its "backup thread": before `clone` existed,
`Domain.spawn` failed at exactly that point, with `failed to create
domain backup thread`. `tests/domains` spawns domains and joins
their results, shares an atomic counter, runs a producer and a consumer
with `Mutex` and `Condition`, and runs a full major collection with
three domains allocating.

**Threads** (`Thread`, with `Mutex`, `Condition`, `Event`) are systhreads:
several threads inside one domain, taking turns with its runtime lock. A
"tick" thread of the runtime wakes every 50 ms (with `nanosleep`) and asks
the running thread to give the lock up, so that they alternate. A thread
also gives the lock up whenever it waits in a call that releases it
(F.4): `tests/threads` checks that the others run while one waits in a
MyNOS sleep or an IPC receive.

**Processors.** On x86-64 domains run in parallel on four processors;
on the i386 they take turns on one, and their speed adds up to that of
one domain. On one processor, domains that allocate much are slow: a
minor collection stops every domain, and the runtime waits for them
spinning, which there lasts until the next preemption (mynos-c6a).

**Effect handlers** need nothing from the kernel. The runtime implements
them by switching between stacks it allocates itself. `tests/effects`
runs two cooperative tasks, `ping` and `pong`, that alternate through a
`Yield` effect, in user space only. This was the main reason, in the 2026
decision (F.10), to choose 5.x over 4.14: services that wait on IPC can
be written in direct style over a small scheduler, without threads.

## F.8 The Mynos library

`mynos-lib/ocaml/` is the OCaml library of MyNOS, `mynos.cma`, with an
interface (`.mli`) for each module. Its modules, in link order:

| Module | What it is |
|---|---|
| `Mynos` | the native calls: ports, channels, semaphores, sleeping, the registry, starting and waiting for programs, processes, port I/O and IRQs for drivers, console modes |
| `Wire` | the wire format of typed IPC: codecs that write and check values (zigzag LEB128 integers, length-prefixed strings, variants by case number) |
| `Ipc` | typed IPC: a protocol is a GADT of requests indexed by their reply's type; `Ipc.Make` gives a typed `call` and a `serve` loop |
| `Block` | `block/1`: sectors of a block device, such as the `ata` driver |
| `Fs` | `fs/1`: the file services (memrofs, tmpfs, fatfs), spoken directly |
| `Console` | `console/1`: the console services, text console and terminal windows |
| `Registry` | `registry/1`: the name registry, described and spoken typed |
| `Net` | `net/1`: the network service: configuration, names, ping, TCP, UDP and TLS sockets |
| `Json` | JSON values, read and written |
| `Http` | HTTP/1.1 and HTTPS clients over `Net` |
| `Llm` | `llm/1`: language models through the `llm` service |
| `Tools` | a typed service's requests as a language model's tools, called with JSON |
| `Tracer` | the event recorder: start, stop, save, show recordings |
| `Agent` | a task in natural language carried out by a model with tools |
| `Voice` | MyNOS's voice: the system answers questions about itself (21.7) |
| `Gfx` | drawing on 32-bit pixel buffers (F.5) |
| `Display` | windows, damage and events, with the display service |
| `Clipboard` | `clipboard/1`: the text copied last, for every program |
| `Gui` | a small immediate-mode toolkit on `Display` and `Gfx` |
| `Textarea` | a text editor's area for `Gui`: Text and Studio use it |
| `Power` | `power/1`: shutting down or restarting, a request to `init` |
| `Sound` | `sound/1`: sound through `soundd`, WAV files (E.15) |
| `Pager` | `pager/1`: files mapped into memory, memory that may go to the swap (B.14) |

Programs outside the library's directory compile with
`-I mynos-lib/ocaml mynos.cma` (and `-use-prims`, F.3). Inside MyNOS
the `.cmi` files and `mynos.cma` are at the root of the RAM disk.

## F.9 Compiling inside MyNOS

MyNOS compiles OCaml programs by itself: the compiler is just another
bytecode program. `system/Makefile` puts on the RAM disk, all in its root
(memrofs is flat):

- `ocamlc.byte`, the bytecode compiler of the build machine (about
  3.6 MB), unchanged;
- the standard library: every `.cmi`, `stdlib.cma`, `std_exit.cmo`, and
  `runtime-launch-info`;
- `unix.cma`, `threads.cma`, `str.cma`, `nums.cma`, `graphics.cma` and
  their interfaces;
- `mynos.cma`, the `.cmi` of its modules, and `primitives`.

Typing `ocamlc` at `sh` finds `/ocamlc.byte` through `PATH` and runs it on
`ocamlrun`. Two things made it work. The compiler looks for the standard
library in `Config.standard_library`, a path of the build machine, unless
`OCAMLLIB` says otherwise: `sh`, the terminal windows, the display
server (for the programs of the graphical session), the toplevel and the
agent all start programs with `OCAMLLIB=/`. And the linker writes the executable to a temporary file
and renames it, so the file services had to learn `rename` (fs/1). A
program with threads, compiled and run inside MyNOS (from
`tools/run-tests.sh`):

```
$ ocamlc -use-prims /primitives mynos.cma unix.cma threads.cma \
    -noautolink -o /disk/th.byte /disk/th.ml && /disk/th.byte
```

The OCaml toplevel (`ocaml` at `sh`, `shell.byte`) compiles the same way,
with its `compile` command; the agent type-checks the programs a model
writes with `ocamlc.byte` before it runs them.

## F.10 History

**2002: OCaml 3.06.** The idea of MyNOS was user programs in OCaml,
whose safety would come from the language as well as from the hardware.
In October 2002 the bytecode interpreter of OCaml 3.06 was imported into
`mynos-byterun/` and ported, with changes marked `#ifdef MYNOS` in four
files (`main.c`, `startup.c`, `dynlink.c`, `floats.c`), and built with
dietlibc. dietlibc's maths library was incomplete, and the port carried fake
`frexp` and `modf`, so floats were wrong (mynos-pg9). That runtime ran
MyNOS's OCaml programs until 2026.

**2026: the decision** (`doc/decisions/ocaml-runtime.md`, mynos-4er).
Stay on 3.06, or move to 4.14 or 5.x? Instead of reading release notes,
both modern runtimes were built for MyNOS and run on its kernel. With
dietlibc neither one even configured. With musl both built unchanged, and
after a handful of kernel fixes (the system call entry did not preserve
registers, modules above 4 MB were neither reserved nor mapped, fresh
pages were not zeroed, the one file seeked only from its end) both ran, floats
included. 5.5.2 was chosen: it needed the same from the kernel as 4.14,
plus three signal calls to accept, and it brought effect handlers and,
once the kernel had `clone`, domains. The decision also set the rule of
F.1: the upstream runtime unchanged, and nothing of the 2002 port carried
forward.

Getting there taught more about the kernel than about OCaml. The effects
test went silent, and the cause turned out to be the RAM-size probe
written in 2002, which left the pattern `0x12345678` in the last four
bytes of every megabyte: with the larger 5.5 runtime, the bytecode module
crossed 4 MB and lost four bytes (`doc/JOURNAL.md`, 2026-11-16).

The steps since: musl and OCaml 5.5 (2026-11-16, mynos-3rz); domains on
`clone` (mynos-l9h); real files instead of the single module-1 file
(mynos-nxa); the compiler inside MyNOS; systhreads and unix
(2026-11-18, mynos-09i). The period toolchain was retired on 2026-11-18;
the last commit it builds is tagged `legacy-last`.

## F.11 Known limits

- One processor (mynos-awn): domains and threads take turns.
- Signals are never delivered (appendix D.8): handlers installed with
  `Sys.signal` do not run.
- Much of `Unix` fails with `ENOSYS` (F.6): no pipes, no `dup`.
- The primitive list is part of the program: bytecode linked against one
  `primitives` file needs a runtime with all of its names.
- `Mynos.registered` returns at most 128 names, `Mynos.processes` at
  most 256 processes.
