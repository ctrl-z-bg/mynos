# Old notes (2002-2004)

These twelve files were kept in a directory of the original MyNOS project
and found again in November 2026. Their dates on disk
are all 2005-07-25, the day they were copied; their contents go from
February 2002 to July 2004, the years in which the 2002 kernel was written.

They are excerpts of public discussions about operating system
development, saved as reference while the kernel was being designed:
questions, and the answers of people who were building their own
systems. Only one keeps its Usenet headers (the newsgroup
alt.os.development); the others have the form of Usenet replies, quoted
lines and signatures, but no headers left to say where they appeared.

## Why they are worth keeping

They show what a small hobby operating system had to work out by itself
in 2002-2004, and where it looked for answers: no tutorial covered a
software task switch or a microkernel's IPC, so one asked on Usenet and
kept the replies.

Five of them touch on what MyNOS did next. The dates line up; the notes
alone do not say which ideas were taken from them, so the table only puts
them side by side:

| Note | Its date | MyNOS |
|---|---|---|
| `soft_taskswitch.txt`: switching threads in software instead of with the processor's TSS | 2002-02-15 | `mynos-core/kernel/softtaskswitch.c`, 2003-07-30 ("soft taskswitch"; the news item "Soft taskswitch and more...") |
| `threads.txt`: Kirk's questions on kernel threads | not dated | `mynos-core/kernel/threads.c`, 2003-08-18 ("thread support added"; the news item "Threads support") |
| `signals.txt`: Kirk's question on POSIX signals | not dated | never done: MyNOS delivers no signals (manual, appendix D) |
| `20040723_ipc_problem.txt`: how a microkernel's IPC should look | 2004-07-23 | `mynos-core/kernel/ipc/`, 2004-09-01 ("IPC!!!"; the news item "New IPC for mynos-core"): ports and channels |
| `driver.txt`: drivers in user space and their access to I/O ports | not dated | every process ran with I/O privilege level 3 (2002); since 2026 only drivers do; the per-port I/O bitmap is still to do (mynos-37p) |

## The files

### Kernel design

- **`soft_taskswitch.txt`**. A thread that starts on 2002-02-15 with a
  question by "sefirot": how to switch tasks without hardware task
  switching. "Viktor" answers with two recipes (save the registers on the
  kernel stack, switch stacks, reload CR3, patch the single TSS's stack
  pointer, `iret`; or save and load the registers in the thread's own
  structure) and the assembly of an interrupt entry. Others follow up with
  their own switchers and questions (one kernel stack or many, a kernel
  mapped at 3 GB). MyNOS's switcher today does the first recipe's essential
  step: one TSS for the whole system (`THEtss`), whose `esp0` is set to
  the incoming thread's kernel stack at every switch (`switchTo`).
- **`threads.txt`**. Several threads. In two of them "Kirk" asks how
  to make kernel threads (one TSS per thread with a new stack?) and about
  fixed-size stacks. The answers: one TSS per process, not per thread,
  since the GDT can hold only about 8,000 of them; a kernel-mode stack per
  thread, of fixed size; a user-mode stack of the program's choice; a
  kernel thread as a thread with no user address space. A later exchange
  (with Maxim S. Shatskih and "cr88192") compares "hardware" (TSS) and
  "software" switches. MyNOS's threads today have a kernel stack each,
  four pages, kept for reuse when a thread ends (`threadAlloc`).
- **`signals.txt`**. Kirk asks how a process can be interrupted by a
  POSIX signal. Viktor gives two ways: a signal as an IPC message to a
  handler thread, safer for a microkernel, or the traditional way, a
  frame pushed on the user stack and `iret` into the handler.
- **`20040723_ipc_problem.txt`**. The longest note, with its Usenet
  headers. Julian Gunter describes an IPC made of message boxes shared
  between a process and the kernel, and asks for opinions. Viktor
  describes his: blocking `send`, `recv`, `call`, `answ`, over
  connections that a resource manager opens, that are connected end to
  end, and that close by themselves when a process exits; the kernel
  passes a message when the other side is waiting and queues the sender
  otherwise. Nick Roberts sketches an L4-like design: queues owned by a
  process, with a list of the processes allowed to use them, messages
  with direct data and address-length pairs, page-aligned buffers moved by
  remapping pages. Five weeks later MyNOS got its second IPC (the first,
  of November 2002, sent to a pid): ports, where a service waits, and
  channels, the connections between two processes; long messages move
  copy-on-write. Today a process's ports and channels are freed when it
  ends (manual, chapter 16 and appendix C).
- **`driver.txt`**. Someone asks how a driver in user space can reach
  only the I/O ports it should. Viktor lists the four ways on the x86: a
  system call per access, a protection fault caught and emulated, ports
  mapped as memory, the TSS's I/O permission bitmap (the fastest); and
  notes that a software task switch can be faster than the processor's.
  MyNOS took the simplest way: from 2002 every process ran with I/O
  privilege level 3 and could touch every port; since 2026 only a process
  started with the `io` privilege (a driver) does. The bitmap, which would
  limit each driver to its own ports, is mynos-37p.

### The PC, at a low level

- **`ATA`**. How to start an IDE disk driver: read Hale Landis's
  tutorials, implement IDENTIFY DRIVE, READ and WRITE SECTORS from ATA-1;
  the ports and IRQs of the two channels (`0x1F0`/`0x3F6`, IRQ 14;
  `0x170`/`0x376`, IRQ 15); the steps of a transfer. Signed Frank Millea;
  an unsigned paragraph follows. MyNOS's disk driver came in 2026, in
  OCaml (`services/ata/ata.ml`): the primary channel's master, those
  ports, PIO with polling.
- **`page_invalidating.txt`**. When to use `INVLPG` (Alexei A. Frounze,
  then an unsigned reply): after every change of a page table entry that
  was present, copy-on-write included. MyNOS's `INVALIDATE_THE_CACHE`
  (`mynos-core/kernel/mem/mem.h`) is `INVLPG`, or a reload of CR3 on a
  386.
- **`lowmem.txt`**. Which memory below 1 MB the BIOS uses (its data area,
  the extended data area at `0x9FC00`) and where a loader may start. MyNOS
  is loaded by GRUB, at 2 MB.
- **`register_c_calling.txt`**. The registers a function compiled by GCC
  must preserve (EBX, EDI, ESI, EBP and the segment registers DS, ES, SS)
  and those it may change: what an assembly entry into the kernel must
  save before calling C. It does not mention the direction flag, which the
  same convention requires clear: in 2026 a kernel entry that did not
  clear it let a program's copies run backwards over the GDT (JOURNAL,
  2026-11-24).
- **`graphics.txt`**. A GRUB patched to set a VESA graphics mode at boot
  and pass the frame buffer's address in the multiboot information, so
  that the kernel needs no real mode or VM86 code. MyNOS's graphics
  (2026) took another way: `displayd` sets the mode of QEMU's Bochs
  display adapter through its I/O ports.
- **`cpu_speed.txt`**. `dcpu.c` (by "sysfree", 2003-05-08): the CPU's
  frequency from the time stamp counter, counted over one second of the
  CMOS clock. MyNOS reads the time stamp counter only as a source of
  randomness (`mynos-core/kernel/random.c`).

### Off the path

- **`cxx`**. Someone rewriting a kernel in C++ asks how to define `new`
  and `delete`; Aaron answers (`operator new`, `operator delete`, name
  mangling, the ISO standard). MyNOS stayed with C for the kernel and
  OCaml above it.

## Changes from the originals

Only the e-mail addresses were removed, each replaced by
`[address removed]`: the sender's of the 2004 post, Kirk's (twice),
cr88192's and sysfree's. Names, web addresses and everything else are as
they were, including the file names (`ATA` and `cxx` have no extension).
Their permissions are the repository's usual ones (some were executable).
