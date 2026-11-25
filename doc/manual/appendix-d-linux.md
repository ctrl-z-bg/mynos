# Appendix D. Linux Compatibility

MyNOS has two system call interfaces. The first, `int 0x90`, is its own
(appendix A.8). The second, `int 0x80`, is a subset of Linux's for 32-bit
x86: the same numbers, the same registers, the same error convention.
This appendix explains why the kernel speaks a foreign interface, how a
call reaches its handler, which calls exist and what each one really does,
how a program starts (its initial stack), and how threads and their
thread-local storage are built. The code is in
`mynos-core/kernel/linux_syscalls.c` and `mynos-core/kernel/lthreads.c`,
with the user-space half in `mynos-lib/src/fileio.c`.

## D.1 Why Linux's interface

MyNOS has no C library of its own, and never had one. A C library is a
large piece of work (`printf`, `malloc`, strings, locales, `errno`,
threads, maths) that has nothing to do with what an operating system
wants to try out. In 2002 the team took a shortcut: a C library for Linux
calls the kernel only through a narrow, documented door, the system
calls. If the MyNOS kernel answers those calls as Linux would, a program
built for Linux with a static C library runs on MyNOS unchanged.

From 2002 to 2008 the C library was **dietlibc**, small and meant for
static linking: the services, `libmynos` and the OCaml 3.06 runtime were
built with `diet gcc` (the `legacy-2008` tag). In 2026 it was
replaced by **musl**, which builds the modern OCaml runtime unchanged
where dietlibc failed (appendix F, F.10). Both speak the same i386 Linux
ABI, so the kernel's design did not change; only the set of calls grew.

What "unchanged" means is precise. A program is unchanged in its
**source**; it must still be built as a static i386 executable linked at
`0x40000000`, where MyNOS loads programs, and its image must fit in 4 MB
(one page table: `spawnProcess` in `kernel/process.c` refuses anything
else). `mynos.mk` gives the compiler and the flags:

```
MYNOS_CC      = musl-gcc
MYNOS_LDFLAGS = -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code
                -Wl,--build-id=none
```

The kernel implements a call only when a real program needs it, and
reports the calls it does not know (D.5). The list of calls in D.3 is
therefore not a design: it is the record of what dietlibc, musl, the OCaml
runtime and the programs of MyNOS have asked for.

> **THE MyNOS FACTOR — A Linux program on a kernel that does not know
> what a file is.** A C program built with musl calls `open`, `read` and
> `printf` as it would on Linux, and runs. But on MyNOS `open` is not a
> system call: the library linked into the program turns it into a
> message to a file service, an ordinary process (D.4). The Linux
> interface is kept for what only a kernel can do: memory, threads,
> time, the end of a process.

## D.2 How a call is dispatched

A program loads the call's number into EAX and its arguments into EBX,
ECX, EDX, ESI, EDI and EBP, in that order, and executes `int 0x80`. musl
does not write the instruction inline: it calls through a pointer kept at
`%gs:0x10` in its thread descriptor, which on MyNOS leads to an
`int 0x80`.

The IDT entry for vector `0x80` is an interrupt gate callable from ring 3
(`kernel/arch/i386/idt.c`). Interrupts are off while the kernel handles the call; a
call that waits gives the processor away explicitly, through the
scheduler.

```
  user mode                     kernel mode (_linux_syscalls_trap_TRAP)
  ─────────                     ───────────────────────────────────────
  eax = number                  push ebp, edi, esi, edx, ecx, ebx
  ebx..ebp = arguments ──int──► compare eax with each known number
  int $0x80          0x80       call the handler: the six pushed words
                                  are its C arguments (ebx first)
  eax = result  ◄────iret────── pop ebx, ecx, edx, esi, edi, ebp
  (other registers unchanged)   (eax holds the handler's result)
```

Three details matter:

- **Every register but EAX is preserved**, as Linux guarantees. The
  entry code saves the six argument registers and restores them on the
  way out. This was not so before 2026: musl's `__set_thread_area` keeps
  a pointer in ECX across the call, which dietlibc never did, and the
  first musl program faulted writing to address `0x28`
  (`doc/JOURNAL.md`, 2026-11-16).
- **The pushes are the arguments.** Pushed in that order, the six
  registers are exactly the cdecl argument list of a C function
  `handler(ebx, ecx, edx, esi, edi, ebp)`, so each handler is an ordinary
  C function. For `mmap2` (192) the entry code also pushes ESP: the six
  words are then read as a `struct mmap_args` in place.
- **Errors are negative numbers**, `-errno`: `-22` for `EINVAL`, `-38`
  for `ENOSYS`. The C library turns any result between -4095 and -1 into
  `-1` and sets `errno`.

The dispatch is a chain of comparisons, one per known number (`exit`,
`clone` and `futex` first), not a table: the numbers are sparse, from 1
to 422, and few.

## D.3 The calls

The kernel answers the 55 call numbers below. Every other number gets
`-ENOSYS` (D.5).

**Processes.**

| No. | Call | On MyNOS |
|---|---|---|
| 1 | `exit` | ends the calling thread; with the process's last thread, the process (D.7) |
| 252 | `exit_group` | ends the process, with the status for its parent; a non-zero status is written to the log |
| 2 | `fork` | a copy of the process, its memory shared copy-on-write; the child has one thread, a copy of the caller (as POSIX says); `-ENOMEM`, with what it took freed, when memory runs out |
| 114 | `wait4` | waits for a child (`pid` > 0: that one; -1 or 0: any, as there are no process groups) and collects its status; option `WNOHANG` only; the resource usage is not filled; `-ECHILD` without children |
| 7 | `waitpid` | the same as `wait4` |
| 20 | `getpid` | the pid (appendix A.4) |
| 122 | `uname` | `MyNOS`, `mynos`, the version (`1.0`, appendix A.2), `#1`, `i386` |
| 64 | `getppid` | the parent's pid |
| 29 | `pause` | waits forever: no signal can end the wait (`-EINTR` if it ever returns) |
| 43 | `times` | the process's CPU time in ticks of 10 ms (Linux's `USER_HZ`, whatever the timer's rate), all of it as user time; the children's is not kept (0); returns the ticks since boot |
| 77 | `getrusage` | the same CPU time, as user time; `RUSAGE_CHILDREN` and the other fields (memory, faults, switches) get 0 |
| 24, 47, 49, 50, 199-202 | `getuid`, `getgid`, `geteuid`, `getegid` and their 32-bit forms | 0: MyNOS has no users (`doc/decisions/identity-and-permissions.md`) |

There is no `execve`: a program starts another with the native `spawn`
(call 30, appendix A.9), which `libmynos` wraps as `mynos_spawn`.

**Memory.**

| No. | Call | On MyNOS |
|---|---|---|
| 192 | `mmap2` | anonymous memory: fresh, zeroed pages, allocated on first use; the address hint, protection, flags, file and offset are ignored; `-ENOMEM` when there is no room. A file is mapped by libmynos, through the external pager (B.14), before the call is made |
| 90 | `mmap` | the same, with the arguments in a structure in the caller's memory (the old i386 form) |
| 91 | `munmap` | gives the pages back |
| 125 | `mprotect` | accepted, and nothing is done: pages are read-write |
| 163 | `mremap` | `-ENOMEM`: a mapping never grows or moves, so musl's `realloc` allocates anew and copies, as on Linux when a mapping cannot grow |

There is no `brk` (45): it fails with `-ENOSYS`, and musl's `malloc`
falls back to `mmap`. Zeroed pages are a requirement, not a courtesy:
musl's allocator checks that memory fresh from `mmap` is zero, and the
OCaml 4.14 runtime stopped on a `hlt` inside it until the kernel cleared
pages allocated on first use (`doc/JOURNAL.md`, 2026-11-16).

**Files and descriptors.** These calls exist, but they are not how
programs use files (D.4). They serve the console's output, and one
read-only file, GRUB's module 1, for a system booted without file
services.

| No. | Call | On MyNOS |
|---|---|---|
| 4 | `write` | whatever the descriptor, the bytes go to the screen, through the kernel's VT100 terminal, and to the log port |
| 146 | `writev` | `write` for each buffer (at most 1,024); musl's stdio writes through it |
| 3 | `read` | descriptors 0-2: end of file at once; any other: the module-1 file |
| 5 | `open` | whatever the path: the module-1 file, as descriptor 5, from its start |
| 6 | `close` | accepted |
| 19 | `lseek` | the module-1 file's position: `SEEK_SET`, `SEEK_CUR`, `SEEK_END` |
| 140 | `_llseek` | the same with a 64-bit offset, the result written back |
| 195 | `stat64` | whatever the path: the module-1 file (a regular file, `rwxr-xr-x`, its size) |
| 197 | `fstat64` | the same, for the descriptor `open` returned; `-EBADF` for any other |
| 54 | `ioctl` | `TIOCGWINSZ` on descriptors 0-2: 25 rows, 80 columns (musl's `isatty` asks it); anything else `-ENOTTY` |

**Time.** The clocks come from `kernel/time.c`: timer ticks at 1000 Hz,
plus, for `CLOCK_REALTIME`, the CMOS clock read once at boot. Their
resolution is therefore 1 ms. The CPU-time clocks
(`CLOCK_PROCESS_CPUTIME_ID`, `CLOCK_THREAD_CPUTIME_ID`) give the
process's CPU time: the timer ticks that found it running, kept in its
descriptor (`cpuTicks`); a thread's is its process's. Any other clock
counts from the boot.

| No. | Call | On MyNOS |
|---|---|---|
| 13 | `time` | seconds since 1970 |
| 78 | `gettimeofday` | the same, in seconds and microseconds; the time zone is ignored |
| 265, 403 | `clock_gettime`, `clock_gettime64` | the clock's time (32-bit or 64-bit `timespec`) |
| 162 | `nanosleep` | sleeps at least that long, rounded up to whole ticks; the remaining time is always 0 |
| 267, 407 | `clock_nanosleep`, `clock_nanosleep_time64` | the same, with `TIMER_ABSTIME` for an absolute time |

**Threads** (D.7).

| No. | Call | On MyNOS |
|---|---|---|
| 120 | `clone` | a new thread in the calling process; only with `CLONE_VM` and `CLONE_THREAD`, otherwise `-ENOSYS` |
| 240, 422 | `futex`, `futex_time64` | wait, wake, requeue |
| 243 | `set_thread_area` | the calling thread's TLS segment |
| 258 | `set_tid_address` | the word to clear and wake when the thread ends |
| 224 | `gettid` | the thread id |
| 158 | `sched_yield` | gives the processor to the next ready thread |

**Signals** (D.8).

| No. | Call | On MyNOS |
|---|---|---|
| 37 | `kill` | only to oneself: ends the process as the signal's default action would; signal 0 only checks; `-EPERM` for another process |
| 238, 270 | `tkill`, `tgkill` | the same, to one of one's own threads (the whole process ends) |
| 174, 175, 186 | `rt_sigaction`, `rt_sigprocmask`, `sigaltstack` | accepted and ignored |

**Randomness.**

| No. | Call | On MyNOS |
|---|---|---|
| 355 | `getrandom` | bytes from the kernel's pool (`kernel/random.c`: timing of interrupts mixed with the SHA-256 compression function); at most 256 per call, the flags ignored |

Pointers a call receives are checked before the kernel uses them
(`__mem_userArea`: the caller's own user pages), and a bad one gives
`-EFAULT`: otherwise the kernel could be made to write into itself.

## D.4 Files are not kernel calls

The table above is not where files live. A program opens
`/disk/notes.txt` through `libmynos`, the MyNOS C library linked into
every program, whose `mynos-lib/src/fileio.c` **replaces** the C
library's file functions at link time:

```
  open, read, write, lseek, close, stat, lstat, fstat, unlink, rename,
  mkdir, rmdir, opendir, readdir, rewinddir, closedir, getcwd, chdir, ioctl,
  poll, select, fcntl, mmap, munmap, msync      (sockets: socket.c, 14.2)
```

The replacement is done by the static linker, not by any trick at run
time. Each program's Makefile links `-lmynos`, and `musl-gcc` adds musl's
`-lc` after everything else; the linker takes each symbol from the first
archive that defines it, so `open` comes from `libmynos.a` and musl's
`open` is never pulled in. This works because musl keeps one function per
object file: nothing else drags its `open` along. (The link order is in
each Makefile, `LDFLAGS = -L…/mynos-lib/lib -lmynos $(MYNOS_LDFLAGS)`,
and in `mynos-runtime/Makefile` for `ocamlrun`; `mynos.mk` itself only
names the compiler and the flags.)

The replaced functions turn I/O into IPC (appendix C) and pass the rest
to the kernel:

```
  open("/disk/a.txt")            libmynos (fileio.c)                services
  ───────────────────            ───────────────────                ────────
  path made absolute    ──►  /tmp/NAME   → "tmpfs"  ── fs/1 ──►  tmpfs (OCaml)
  (against PWD)              /disk/PATH  → "fatfs"  ── fs/1 ──►  fatfs (OCaml)
                             anything else → "memrofs" ─ fs/1 ─►  memrofs (C)
                             no memrofs   → int 0x80, open (5): module 1
  descriptor 20 + slot  ◄──  the service's own descriptor kept in a table
```

- **Files** get descriptors from 20 up (`FD_BASE`), 64 at most
  (`FD_MAX`), sockets from 84; one of these not open gives `EBADF`.
  `libmynos` keeps, for each, the service and the service's
  own descriptor. A `read` loops until it has everything asked for, as a
  regular file on Linux does: the OCaml runtime reads whole bytecode
  sections in one call and calls a short read a truncated file.
- **Standard input** (descriptor 0) is read from the console service
  (`console`, or the one named by `MYNOS_CONSOLE` in a terminal window).
- **Standard output and error** go to the kernel's `write` (D.3), which
  puts them on the screen, unless `MYNOS_CONSOLE` names a terminal
  window's console service: then they go to it.
- **Redirections** (`MYNOS_STDIN`, `MYNOS_STDOUT`, `MYNOS_STDERR` in the
  environment, set by `sh`) make descriptors 0, 1 and 2 stand for files.
- **Terminal settings**: `ioctl` answers `TCGETS`, `TCSETS*` and
  `TIOCGWINSZ` on descriptors 0-2 itself, by talking to the console
  service; anything else goes to the kernel.

Services are found by name in the registry and the port is cached; a
service that ends (init restarts it, with a new port) is looked up again
at the next request.

**stdio** needs one more step. musl's `FILE` functions do their I/O
through five internal functions that call the kernel directly, not
through `read` and `write`: `__stdio_read` (with `readv`, 145),
`__stdio_write` (`writev`, 146), `__stdout_write` (`ioctl`, to choose
line buffering), `__stdio_seek` and `__stdio_close`; and `fopen` opens
with a raw `open` (5). `libmynos` replaces those five and `fopen`
(`mynos-lib/src/stdio.c`), on its own `read`, `write`, `ioctl`, `lseek`,
`close` and `open`. Nothing in a program calls them by name, so the
linker would not look for them in `libmynos`: `mynos.mk` names them with
`-u`, which makes them wanted before any archive is searched. They work
on musl's `struct _IO_FILE`, whose layout `stdio.c` copies from musl
1.2.5, the version the container builds with. So `fopen("/disk/a.txt")`
reaches fatfs, `fgets(stdin)` reads a line from the console or from a
shell's redirection (`tests/stdio` checks both, on the console), and
`printf` in a terminal window reaches the window, by the path `write`
takes. Until November 2026 none of this worked (mynos-d6k):
`fopen` opened the module-1 file, `fgets(stdin)` failed, `printf` went to
the text screen.

## D.5 Unknown calls

A call whose number is not in D.3 returns `-ENOSYS` (-38), as Linux does
for a call it does not have. C libraries and runtimes expect it, and fall
back: musl to `mmap` when `brk` fails, the OCaml runtime to doing without
`readlink` when it looks for its own executable.

The kernel also writes a line to the log, once for each number (numbers
up to 511 are remembered; larger ones are reported every time):

```
Linux syscall 45 not implemented (process 3): -ENOSYS
```

The log is the second serial port; the line reaches the screen only
while kernel messages are shown there (appendix A.2). In 2008 the same
event was a kernel panic, `syscall 243 is not yet implemented!`: one
program asking for something new stopped the machine. Made harmless and
visible, the message became a measuring instrument. When the modern OCaml
runtimes were first run on MyNOS, the list of reported numbers was the
list of work to do (`doc/decisions/ocaml-runtime.md`). `tests/abi`
checks the behaviour with call 400.

## D.6 The initial process stack

A Linux program does not start at `main`. It starts at `_start`, which
expects the stack to hold what the kernel prepared: the argument count,
the arguments, the environment and the auxiliary vector. musl reads all
of it before `main`. `buildInitialStack` in `kernel/process.c` writes it
in the top page of the new process's stack:

```
  top of the user stack  ┌──────────────────────────────────┐
                         │ "argv[0]" "argv[1]" … "envp[0]" … │ the strings, copied
                         │                                  │ from the top down
                         │ (free: the size is rounded to 16)│
                         │ 0  0           auxv: AT_NULL     │
                         │ 0                                │
                         │ &envp[n-1] … &envp[0]            │
                         │ 0                                │
                         │ &argv[argc-1] … &argv[0]         │
  ESP at _start  ──────► │ argc                             │
                         └──────────────────────────────────┘
```

- **Where the arguments come from.** For a GRUB module, its command line
  (`module /registry args` in GRUB, `-initrd "path args"` in QEMU), and
  no environment. For a process started with `spawn`, the vectors its
  parent gave; `libmynos` passes the parent's environment by default,
  with `PWD` set to the parent's current directory. Without arguments the
  kernel uses `argv = { "mynos" }`.
- **It must fit in one page.** Vectors and strings together are limited
  to 4,096 bytes; a `spawn` that asks for more fails. Before that, the
  kernel checks the vectors a parent passes: fewer than 1,024 entries,
  each string shorter than 4,096 bytes.
- **The auxiliary vector is empty**: only its terminator, `AT_NULL`.
  musl copes; without `AT_SYSINFO`, for instance, it makes its calls
  with `int 0x80`.
- **The user stack** is 256 pages (1 MB), below the kernel stack and the
  process information at the top of the address space. Only the top page,
  which holds this structure, is allocated at once; the others are
  allocated when first touched.

The first thread starts at the ELF entry point with ESP (and EBP)
pointing at `argc`, in user mode, with the plain data segment in every
segment register. Its first calls are musl's: `set_thread_area`, then
`set_tid_address`.

Before 2026 every process started with an empty stack: `argc = 0`,
`argv[0] = NULL`. dietlibc 0.34 read `argv[0]` for the program's name and
faulted at address 0, which is how the initial stack came to be written.

## D.7 Threads and thread-local storage

A C library's threads (`pthread_create`, mutexes, condition variables)
are built on three Linux calls: `clone` makes a thread, `futex` lets it
wait, `set_thread_area` gives it its own thread-local storage. OCaml's
domains and threads are built on the C library's (appendix F, F.7). All
three are in `kernel/lthreads.c` (2026); they make **Linux threads**,
which use the same `tss_t` as MyNOS's native threads (appendix A.4).

**clone** (120) accepts only a new thread in the same address space:
`CLONE_VM` and `CLONE_THREAD` must both be set (a new process is
`fork`'s job). It honours `CLONE_SETTLS`, `CLONE_PARENT_SETTID`,
`CLONE_CHILD_SETTID` and `CLONE_CHILD_CLEARTID`, and ignores the rest.
The new thread must come back from the system call as if it had made it:
EAX = 0, the stack it was given, every other register as the caller's.
musl's `__clone` relies on it, keeping the function to call in EBP. So
the kernel builds the new thread's kernel stack the way
`startClonedThread` will unwind it:

```
  the new thread's kernel stack            startClonedThread
  ┌─────────────────────────────────┐ high
  │ ss, esp = the new stack         │  iret: to user mode, at the
  │ eflags, cs, eip                 │  instruction after the caller's int
  ├─────────────────────────────────┤
  │ eax = 0, ecx, edx, ebx, (esp),  │  popal: the caller's registers,
  │ ebp, esi, edi                   │  except eax
  ├─────────────────────────────────┤
  │ ds, es, fs, gs (gs: its TLS)    │  four popw
  └─────────────────────────────────┘ low  ◄── where the thread starts
```

The caller's return address and flags are read from its own system call
frame, just above the six registers the entry code pushed. The parent
gets the new thread's id.

**Thread ids.** A process's first thread has the process's pid as its
thread id. The others get ids from 1,000,000,000 up, so that a thread id
is never a pid, and below 2^30 (`0x3fffffff`), because the C library
keeps a mutex's owner as `tid & 0x3fffffff`, using the higher bits as
flags; the counter wraps there.

**Thread-local storage.** On i386, musl finds the current thread's data
(its `errno`, its stack canary at `%gs:0x14`, its system call pointer at
`%gs:0x10`) through the GS segment register. MyNOS keeps **one GDT slot,
entry 5**, for it:

- `set_thread_area` (243) accepts entry -1 ("choose one") or 5, stores
  the base, the limit and the page granularity in the calling thread's
  `tss_t`, answers 5, and loads the slot at once. The program then loads
  GS with selector `0x2B` (entry 5, ring 3).
- At every context switch the kernel rewrites entry 5 from the incoming
  thread's values (`tls_load`), before its segment registers are
  reloaded. A thread without TLS of its own gets a flat 4 GB data
  segment there.
- `clone` with `CLONE_SETTLS` gives the new thread its own values from
  the `user_desc` passed; without it, a new thread inherits its creator's.

One slot rewritten at every switch is enough because only one thread runs
at a time. A forked
child taught the kernel a lesson about it: it resumes inside
`_linux_syscall_fork`, not through the context switch's pops, so its GS
still held the previous thread's descriptor, and musl's first system call
in the child jumped through `%gs:0x10` to address 0. The child now
reloads GS itself.

**futex** (240, and 422 with a 64-bit time) is the waiting room behind
every lock and condition variable: "sleep if this word still holds this
value", and "wake N sleepers on this word".

| Operation | What MyNOS does |
|---|---|
| `FUTEX_WAIT` | if the word still holds the value, wait, with an optional relative timeout; `-EAGAIN` if it changed, `-ETIMEDOUT` |
| `FUTEX_WAIT_BITSET` | the same, with an absolute time (`CLOCK_MONOTONIC`, or `CLOCK_REALTIME` with that flag); the bit set is ignored |
| `FUTEX_WAKE`, `FUTEX_WAKE_BITSET` | wake up to N waiters on the word; the number woken |
| `FUTEX_REQUEUE` | wake N, move up to M others to a second word |
| `FUTEX_CMP_REQUEUE` | the same, if the word still holds a given value (the two requeues serve musl's condition variables) |
| anything else | `-ENOSYS` |

Waiters are kept in a table of 256 entries, keyed by process and address
(`FUTEX_PRIVATE_FLAG` makes no difference: a futex never crosses
processes). A waiter sleeps on its private semaphore (appendix A.6),
with a timer if it has a timeout, which is rounded up to whole
milliseconds. One subtlety took a bug to find: a waiter whose timer has
already woken it must not be woken again by a `FUTEX_WAKE` before it
runs, or its private semaphore is left at 1 and its next blocking call
returns at once. A wake therefore signals a timed waiter only if it can
still take it off the timer queue.

**The end of a thread.** `exit` (1) ends the calling thread. If its
`clear_child_tid` word is set (by `CLONE_CHILD_CLEARTID` or
`set_tid_address`), the kernel writes 0 there and wakes every futex
waiter on it: that is how `pthread_join` learns that the thread ended.
If it was the last thread, the whole process ends. `exit_group` (252)
ends the process at once; musl's `exit` uses it.

**One processor.** Threads take turns on the single CPU, under the
round robin of appendix A.5; they do not run in parallel (mynos-awn).

## D.8 Signals without delivery

MyNOS does not deliver signals. No handler set with `sigaction` ever
runs, and the process mask means nothing. But runtimes set them up as
they start (the OCaml 5 runtime calls all three), so `rt_sigaction`,
`rt_sigprocmask` and `sigaltstack` succeed and change nothing.

The one signal that works is the one a process sends itself to die.
`abort()` and `raise()` in musl send a signal to the calling thread with
`tkill`; the kernel then ends the process as the signal's default action
would, writes `process N killed by signal S` to the log, and gives the
parent the status of a process ended by that signal. A signal to another
process gets `-EPERM`.

What Unix does with signals, MyNOS does with messages. Ctrl-C is the
console service killing the foreground program with the native `kill`
(call 34, appendix A.9), as `sh` names that program to the console; a
service learns that a client went away when its channel breaks
(appendix C).

## D.9 Known limits

- The calls are a subset, and some are partial: `mmap` gives anonymous
  memory only (libmynos maps a file through the external pager, B.14;
  a static binary of another libc cannot), `mprotect` does nothing, the signal calls are accepted
  without effect, `kill` reaches only oneself. The CPU time is
  sampled at each tick, not measured, and is all user time.
  The gaps are collected in mynos-51c.
- There is no `execve`, `brk`, `readv`, `pipe`, `dup`, `select` or socket
  call: `-ENOSYS`. OCaml's `Unix` functions built on `execve`, `pipe` or
  `dup` fail with `ENOSYS` (appendix F). Sockets, `select`, `poll` and a socket's
  `fcntl` are `libmynos`'s (14.2), before the kernel is asked.
- `freopen` and `tmpfile` still open with musl's raw `open`; `libmynos`
  replaces `fopen` only (D.4).
- The kernel's own file calls ignore their path: on a system without
  file services every `open` and `stat` finds module 1.
- The initial stack must fit in one page; the auxiliary vector is empty.
- Futexes: 256 waiters in all; no priority inheritance or robust lists.
- The clocks tick at 1000 Hz: no time is finer than 1 ms, and a sleep
  lasts what it asked plus up to a tick. The tick counter has 32 bits:
  the clocks since boot wrap after 49.7 days.
- Threads share one processor (mynos-awn).
