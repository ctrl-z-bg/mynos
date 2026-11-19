# Appendix A. The Microkernel

The kernel of MyNOS lives in `mynos-core/`: about 8,500 lines of C and a
few hundred of assembly, for 32-bit x86 processors. This appendix explains
what it does, in the order in which it comes to life: the boot, the
processor's tables, processes and threads, the scheduler, semaphores,
interrupts, and the system calls. Memory (appendix B), IPC (appendix C)
and the Linux system calls (appendix D) have appendices of their own.

## A.1 What the kernel does, and what it does not

MyNOS is a microkernel. The kernel keeps only what cannot be anywhere
else:

- the memory of each process, and the protection between them;
- processes and threads, and the scheduler that shares the processor;
- semaphores, the one synchronization primitive;
- IPC: ports, channels, messages;
- the routing of hardware interrupts to the processes that handle them;
- two system call interfaces: MyNOS's own (`int 0x90`) and a subset of
  Linux's (`int 0x80`);
- the event recorder (appendix G).

Everything else is a process: the name registry, the file systems, the
disk and network drivers, the console, the windows, `init`, the shells.
The kernel does not know what a file is, or a name, or a keyboard
layout. It moves messages between processes that do.

> **THE MyNOS FACTOR — The kernel does not know what a file is.**
> In MyNOS, `open("/disk/notes.txt")` is not a system call. The C library
> turns it into a message to `fatfs`, an OCaml program, which asks
> another OCaml program, `ata`, for the disk's sectors. The kernel only
> carried the messages. Replace `fatfs` with another program that speaks
> the same protocol, and every program on the system reads files from it.

## A.2 The boot

```
  GRUB ──► start.asm ──► mynos_main() ──► processes from the modules ──► idle
  (multiboot)  (paging on)    (main.c)         (registry, memrofs,
                                                ocamlrun → init)
```

MyNOS is a **multiboot** kernel: GRUB (or QEMU's `-kernel`) loads
`kernel.elf`, linked at `0x200000` (2 MB), together with a list of
**modules**: the programs to start, and the RAM disk. A module's command
line (`module /registry` in GRUB, `-initrd "path args"` in QEMU) becomes
its `argv`.

`kernel/start.asm` turns paging on and calls `mynos_main` in
`kernel/main.c`, which then:

1. copies what it needs of GRUB's information (the kernel's command line,
   the modules' addresses and command lines) and reserves the modules'
   memory, before anything can overwrite it;
2. initializes memory (`init_memory`: the physical page bitmap, the
   kernel's page tables; appendix B) and finds the RAM disk, the module
   whose first bytes are `.RAMDISK`;
3. prepares the process table and the scheduler's queues;
4. programs the two 8259 interrupt controllers (IRQs 0–7 at vectors
   `0x20`–`0x27`, 8–15 at `0x28`–`0x2F`) and loads the IDT;
5. measures a delay loop, then starts the 8253 timer at 100 Hz;
6. reads the clock (`time_init`: the CMOS clock once, then timer ticks),
   seeds the random number pool (`random_init`), and creates the
   semaphore table;
7. starts every module that is an ELF file as a process, with the `io`
   privilege (A.7): in the standard system they are the registry,
   memrofs (which serves the RAM disk as files), and `ocamlrun`, which
   finds `init.byte` on the RAM disk and runs it;
8. initializes IPC, and from then on writes its messages to the log port
   only (the second serial port, `0x2F8`), leaving the screen to the
   programs, unless the kernel's command line says `verbose`.

Its first line on the screen is `Welcome to MyNOS - v2026.11-71dc1d2`:
the version, the year and month of the build and the commit, which
`tools/build-all.sh` writes to `VERSION` (`tools/version.sh`) and the
kernel's Makefile compiles in; programs read it with `uname`
(appendix D), `sh` with `version`. Every message the kernel writes, and
every line a service logs (call 31), is also kept in a ring of 64 KB,
which native call 35 reads: the `log` command and the Log window.

The boot then becomes the **idle thread** of process 0, which halts the
processor (`hlt`) until the next interrupt, whenever nothing else is
ready. What happens next is `init`'s business: it reads `init.rc` and
starts the console, the file systems, the drivers, the network and the
login shell (chapter 6, appendix E).

(`mynos-core/boot/` holds a floppy-disk boot loader from 2002, which is
not used when booting with GRUB, and does not assemble with today's
`nasm`: mynos-s96.)

## A.3 The processor's tables

**The GDT** (`kernel/gdt.c`) is small, because MyNOS uses a flat memory
model: every segment spans the whole 4 GB, and protection comes from
paging (appendix B). Until `init_memory` the kernel runs on the boot
loader's GDT and selectors; `_init_gdt` then loads MyNOS's own and
reloads every segment register from it (a far jump for CS). The boot
loaders differ: QEMU's uses 0x08 for code and 0x10 for data, as MyNOS
does, GRUB 2 uses 0x10 and 0x18; until November 2026 the registers were
not reloaded, and only QEMU's numbers worked.

| Selector | Segment |
|---|---|
| `0x08` | kernel code (ring 0) |
| `0x10` | kernel data (ring 0) |
| `0x18` | user code (ring 3) |
| `0x20` | user data (ring 3) |
| entry 5 | the running thread's TLS segment (Linux threads), rewritten at every context switch |
| | the one hardware TSS |

**The IDT** (`kernel/idt.c`) has 256 gates:

| Vector | Handler |
|---|---|
| 0–16 | processor exceptions. One raised in user mode ends the program, as a fatal signal would on Unix (its status says SIGSEGV), with a line on the log port; one raised in the kernel stops the system. 14, the page fault, first tries to resolve it: copy-on-write, pages allocated on first use, faults inside `copy_from_user`/`copy_to_user` (appendix B). 7 only clears the TS flag. |
| `0x20`–`0x2F` | the 16 IRQ lines. IRQ 0, the timer, runs the scheduler; the others wake the drivers that registered them (A.7). |
| `0x80` | Linux system calls, callable from ring 3 (appendix D) |
| `0x90` | MyNOS system calls, callable from ring 3 (A.8) |

## A.4 Processes and threads

**A process** is an address space, a set of IPC objects, and one or more
threads. The kernel describes it with a `process_descriptor_t`
(`kernel/process.h`), held in a table of 1,000 slots:

```
  process_descriptor_t
  ├── pid, ppid, name[16], privileges   who it is
  ├── tss ──► thread ──► thread ──► …   its threads
  ├── lmemmap                           its free linear space (appendix B)
  ├── portList, channelList             its IPC objects (appendix C)
  ├── exitStatus, reaped, childSem      for the parent's wait
  └── deadThreads, nextZombie, …        for its end (A.9)
```

**A pid names one process for its whole life.** It is
`slot + 1000 × generation`: when a slot is reused, the new process has
another pid, so a stale pid can never reach the wrong process
(`doc/decisions/identity-and-permissions.md`). Ports and channels carry
generations in the same way.

**A thread** is a `tss_t` (`kernel/tss.h`): the saved registers, a
kernel stack (four pages), a private semaphore on which it waits, its
time to wake if it sleeps, its TLS segment, and links to the next thread
of its process and to the queue it is in. The name is historical: in
2002 every thread had a hardware task segment, and the processor switched
between them. Today there is **one hardware TSS**, and the context switch
is done in software (`kernel/softtaskswitch.c`):

```
  switchTo(old, new):
      save old's floating-point state; load new's (or a clean one)
      THEtss.esp0 ← new's kernel stack       (where the next interrupt lands)
      load new's TLS segment into GDT entry 5
      push old's callee-saved registers and segment registers
      if the page directories differ: CR3 ← new's page directory
      save old's ESP and a return label; load new's ESP; jump to new's EIP
      pop new's registers
```

A thread that has never run starts at `startThread`, which pops its
segment registers and returns to user mode with `iret`.

**The floating-point state** (the x87 registers and control word, MMX,
SSE) is part of a thread too: each `tss_t` has a 512-byte area for it.
`switchTo` saves the outgoing thread's state there and loads the
incoming one's, with `FXSAVE`/`FXRSTOR`, or `FNSAVE`/`FRSTOR` on a
processor without them. A new thread starts from the state of a freshly
initialized FPU, recorded at boot; a child made by `fork` goes on with its
parent's. At boot `fpu_init` also turns SSE on (CR4's `OSFXSR` and
`OSXMMEXCPT` bits) when the processor has it. The kernel never uses the
FPU itself: it is compiled with `-mgeneral-regs-only`, so the registers
always hold the running thread's state. (Until November 2026 nothing was
saved: every thread shared one FPU, and a thread preempted in the middle
of a computation could find it changed. The manual's first draft found
it; `tests/fpu` shows it on the old kernel.)

There are two kinds of threads, with the same `tss_t`:

- **native threads** (`mynos_threadCreate`, system call 200, 2002):
  they share their process's address space and TLS. consoled uses them
  for its keyboard and serial threads.
- **Linux threads** (`clone`, 2026, `kernel/lthreads.c`): what musl's
  pthreads and therefore OCaml's domains and threads use. Each has its own
  TLS (`set_thread_area`), a thread id (from 1,000,000,000 up, so it is
  never a pid), and the `futex` calls on which the C library builds its
  mutexes and condition variables.

All threads share **one processor**: MyNOS does not run on several CPUs
yet (mynos-awn).

## A.5 The scheduler

The scheduler (`kernel/sched.c`) is a **round robin** over one queue of
ready threads, from every process. It runs on every timer tick (100 Hz,
so a thread runs at most 10 ms before the next one) and whenever a thread
blocks. Each time it:

1. wakes the threads whose sleep has ended: a second queue, ordered by
   time to wake, holds the sleepers;
2. frees the memory of processes that have ended (A.9);
3. takes the next ready thread. The idle thread (process 0) is chosen
   only if nothing else is ready, and then keeps the processor until the
   next tick;
4. switches to it.

There are no priorities. A thread that waits (for a message, a
semaphore, a child, a tick) leaves the ready queue and costs nothing
until it is woken.

## A.6 Semaphores

Semaphores (`kernel/sem.c`) are the kernel's only synchronization
primitive, and everything else that waits is built on them. The table
holds 4,096. A semaphore belongs to the process that created it, and is
freed when the process ends.

| Call | Number | What it does |
|---|---|---|
| `mynos_initSem(n)` | 9 | a new semaphore with value `n` (at most 100) |
| `mynos_P(s)` | 6 | wait until the value is positive, then decrement it |
| `mynos_tryP(s)` | 7 | the same, without waiting: an error if it would wait |
| `mynos_V(s)` | 8 | increment the value, or wake one waiting thread |
| `mynos_freeSem(s)` | 13 | free it |

Every thread has a **private semaphore**, on which the kernel makes it
wait: for a message (`recv`), for a connection (`listen`), for a child
(`wait`), for a timeout. Waking a thread is a `V` on its private
semaphore. Every process has one more, `childSem`, V'd once for every
child that ends.

## A.7 Interrupts and drivers

Drivers are processes. A process with the **`io` privilege** asks for an
interrupt line with `mynos_driverRegister(name, irq, …)` (call 10),
and gets a semaphore. From then on, at every interrupt on that line, the
kernel (`kernel/irq.c`) acknowledges the interrupt controllers, does a
`V` on the driver's semaphore, and, if the processor was idle, switches
to the driver at once. The driver unmasks its line once, with
`mynos_enableIrq` (100), then loops: it waits with `mynos_P`, and talks
to its device. Lines 0 (the timer) and 2 (the cascade between the two
controllers) are the kernel's; a line nobody registered for stays masked;
a driver's lines are freed when it ends.

The `io` privilege also sets the process's IOPL to 3, so that it can use
the `in` and `out` instructions, and lets it map physical memory
(`mapPhysical`, call 28: the display's frame buffer). The modules that
GRUB loads have it; `init` gives it to the `driver` lines of `init.rc`
(consoled, ata, netd, displayd); a child gets at most its parent's.
`sh` and what it starts have none: an `outb` in a program ends it. A
finer permission, port by port, is mynos-37p.

## A.8 System calls

A program calls the kernel with `int 0x90` (MyNOS) or `int 0x80` (Linux),
the call's number in EAX and its arguments in the other registers; the
result comes back in EAX, and negative values are errors (`MYNOS_ERR_*`
in `mynos-lib/include/mynos.h`). The kernel's entry point
(`_mynos_syscalls_trap_TRAP`, `kernel/syscalls.c`) compares EAX with each
number in turn and calls the C function; the C library of MyNOS,
`libmynos`, wraps each one (`mynos_send`, `mynos_P`, …).

The native calls:

| No. | Call | Appendix |
|---|---|---|
| 3 | `send` (channel, buffer, size, flags) | C |
| 4 | `recv` (channel, message, flags, timeout) | C |
| 5 | `freeChannel` | C |
| 6, 7, 8 | `P`, `tryP`, `V` | A.6 |
| 9, 13 | `initSem`, `freeSem` | A.6 |
| 10 | `driverRegister` (name, IRQ, …) | A.7 |
| 11, 12 | `serviceRegister`, `clientRegister`: a name registry inside the kernel, from 2002, which no program uses any more (the registry is a process) | — |
| 20, 21 | `allocPort`, `allocPortP` (a given well-known port) | C |
| 22, 23 | `connectToPort`, `listenPort` | C |
| 24, 25 | `freePort`, `changePortOwner` | C |
| 26 | `channelPeer`: the pid at the other end of a channel | C |
| 27 | `processInfo`: alive, privileged, an OCaml program | A.4 |
| 28 | `mapPhysical`: physical memory into the caller (`io` only) | B |
| 30 | `spawn` (image, argv, envp, privileges) | A.9 |
| 31 | `log`: a line on the log port | A.2 |
| 32 | `trace`: the event recorder | G |
| 33 | `processes`: the list of live processes | A.4 |
| 34 | `kill` | A.9 |
| 35 | `klog`: the kernel's log, the last 64 KB of its messages (`printk`, call 31), from a position | A.2 |
| 100, 101 | `enableIrq`, `disableIrq` | A.7 |
| 200, 201, 202 | `createThread`, `exitThread`, `selfThread` | A.4 |
| 300 | `setTimer` | A.5 |
| 400 | `stats`: counters for `free` and the System window | — |

Files, time, memory allocation and threads for the C library go through
the Linux interface instead (appendix D): musl, unchanged, calls
`int 0x80`, and the kernel answers as Linux would, or with `-ENOSYS`.

## A.9 Birth and death of a process

**A process is born** from an ELF image: at boot from a module (A.2),
afterwards from `spawn` (call 30), which a parent calls with the bytes of
a program it has read (from a file service: the kernel cannot open
files), its arguments, its environment and its privileges (at most the
parent's). `createProcess` (`kernel/process.c`) makes an address space, maps
the program's segments at `0x40000000`, builds the initial stack the way
Linux does (`argc`, `argv`, `envp`, the auxiliary vector, so that musl
starts unchanged), and puts the first thread in the ready queue. A
process whose program is `ocamlrun` is marked as an OCaml program (for
`ps` and the System window).

**A process ends** when its last thread exits, when it calls `exit`, when
it faults, or when another process kills it (`kill`, call 34: any
process, except the idle process and `init`, provided the victim has no
privilege its killer lacks). `endProcess` then:

1. records the event, and takes its threads out of every queue;
2. frees its ports and channels, acting as the dying process while it
   does so (the ownership checks look at the current process, which,
   for a kill, is the killer). Clients waiting on its ports are woken with
   `MYNOS_ERR_BROKEN` (appendix C);
3. forgets its futex waiters, frees its semaphores and its IRQ lines;
4. makes its children orphans, and does a `V` on its parent's `childSem`;
5. puts itself on the list of **zombies**.

Its memory (pages, page tables, kernel stacks) cannot be freed at once:
the kernel may be running on that stack. The scheduler frees it at the
next context switch, from another thread (`reapZombies`). The descriptor
and the pid stay until the parent collects the status (`waitpid`,
`wait4`); then the slot is free for a new process, with a new
generation.

## A.10 Limits

| What | How many | Where |
|---|---|---|
| processes | 1,000 | `MAXPROCESSES`, `process.h` |
| semaphores | 4,096 | `MAXSEM`, `sem.c` |
| channels | 4,096 | appendix C |
| kernel stack per thread | 4 pages (16 KB) | `KERNEL_STACK_NPAGES`, `global.h` |
| timer | 100 Hz | `PIT_FREQ`, `pit.h` |
| processors | 1 | mynos-awn |

## A.11 Known limits

- One processor (mynos-awn); I/O permission is all or nothing
  (mynos-37p).
- Calls 11 and 12 are a leftover of 2002: nothing calls them.
