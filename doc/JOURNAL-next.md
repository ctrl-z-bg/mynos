# MyNOS — Engineering Journal of the next branch

The diary of the work done on the branch `next` only (version 2: the
x86-64 and AArch64 ports, several processors, virtio, the Raspberry
Pis, the USB...), in the same form as `doc/JOURNAL.md`: symptom,
diagnosis, cause, fix, lesson; newest entries at the bottom.

Which journal: `doc/JOURNAL.md` is the one `main` and `next` share
(kernel, services, system libraries, toolchain: what is found on
`main` comes here with its merges, and is left as it is on `next`);
`doc/JOURNAL-apps.md` (from `main`) has the applications' (`packages/`
and their libraries); this file has what is found while working on
`next`. It begins where `next` left `main` (2026-11-24, the virtio
work).

---

## 2026-11-24 — dmaAlloc zeroed its own page table

**Symptom.** In the suite's virtio boot (256 MB, a disk, a network card,
a keyboard, a tablet, a GPU) `displayd` was killed when the graphical
session started: "invalid memory access at 0x42401000". The same boot
without the disk and the card, or by hand with 512 MB, worked.

**Diagnosis.** The address was one page past a 4 MB boundary, in the
3 MB frame buffer `displayd` had just asked `dmaAlloc` for. Its first
4 MB were fine; the next page table was not.

**Cause.** `__OS_allocDma` chose a run of free physical pages first,
then reserved the linear pages with `__OS_askPagesFrom`, which makes the
page tables the range needs and takes their pages from the same free
pool: one page table landed inside the run. The run was then mapped and
zeroed, and the zeroing wiped that page table. Whether it happened
depended on what the other drivers had taken before.

**Fix.** The linear pages, and their page tables, first; the physical
run after.

**Lesson.** When a function takes two resources from the same pool, the
one taken first must not be counted as free by the search for the
second: order them so that the search sees the pool as it will be.

## 2026-11-24 — A key became a mouse event

**Symptom.** After the virtio tablet was added to `displayd`, no key
reached a window of the graphical session: the Terminal, `edit`, the
keys test, all silent. The mouse worked; the text console too.

**Diagnosis.** By halves: the old `consoled` with the new `displayd`
failed, the new `consoled` with the old `displayd` worked.

**Cause.** The virtio tablet's code defined Linux's event types as
macros, `#define EV_KEY 1`, after `displayd`'s own `enum { EV_KEY,
EV_MOUSE, ... }` of the events it posts to windows. From that line on,
every key was posted as kind 1: a mouse event.

**Fix.** The virtio constants are `VEV_*`, in `displayd` and in
`consoled`.

**Lesson.** A macro defined late silently overrides a name declared
early, with no warning; constants taken from another vocabulary (Linux's
input events) get a prefix of their own.

## 2026-11-25 — x86-64: the graphical session without text

**Symptom.** On x86-64 the graphical session came up with windows,
buttons and the logo, but not a letter: every label empty. The font
file read fine from the toplevel, and `Gfx.text t 0 0 "hi" 0` answered
0 cells.

**Diagnosis.** `Gfx.text` has an optional limit of cells, `?max`, whose
default is `max_int / 2`. The stub `caml_gfx_text` read it with
`int max = Long_val(vmax)`.

**Cause.** On the i386 `max_int / 2` is 2^29, which fits an `int`. At 64
bits it is 2^61: truncated to 32 bits it is −1, and the loop
`cells < max` never ran.

**Fix.** The stub reads the limit as a `long` and clamps it to
`0x7FFFFFFF`.

**Lesson.** OCaml's `int` follows the word; C's `int` does not. A stub
that narrows `Long_val` to `int` is safe only for values bounded by
something real (a pixel, a length), not for "no limit" defaults built on
`max_int`.

## 2026-11-25 — Two test binaries in git

**Symptom.** At 64 bits the FPU test did not start ("module is not a
valid MyNOS program") and the stdio test was killed by a general
protection fault, though both had been rebuilt.

**Diagnosis.** In `build/x86_64/tree`, `tests/fpu/fpu.o` was a 64-bit
object and `tests/fpu/fpu` a 32-bit program. `git ls-files` listed
`tests/fpu/fpu` and `tests/stdio/stdio`.

**Cause.** Both binaries had been committed with the sources
(ee0aa74). The copy of the tracked files made them newer than their
objects, so make did not link them again: the i386 programs ran on the
x86-64 kernel.

**Fix.** Out of git, into `.gitignore` next to their sources.

**Lesson.** A build product in git is invisible on one architecture and
wrong on the next. Look for ELF files among the tracked ones when a
second toolchain arrives.

## 2026-11-25 — x86-64: every network request four seconds late

**Symptom.** On x86-64 `ask` took 14 s where the i386 took 2 to 8, the
network test needed 124 s against 22, and in the suite the keyboard-
driven boot fell behind the keys typed into it. Alone, the system was as
fast as the i386 at everything tried: files, the console, `spawn`, the
toplevel.

**Diagnosis.** Timing one command at a time on both architectures, with
the network on: `fetch` from the host 3.3 s on the i386, 7.5 s on
x86-64; `llm` 2.6 s against 7.2. A constant of about four seconds per
connection. `netd`'s main loop sleeps in `pthread_cond_timedwait` (at
most 100 ms) and is woken by the card's interrupt thread.

**Cause.** `_linux_syscall_futex_time64` took its fourth argument, the
pointer to the timeout, as `uint32_t`. On x86-64 a program's stack is
above 4 GB: the pointer was cut, the kernel found it outside the
program's memory and answered `-EFAULT` at once. Every timed wait
returned immediately, and `netd`'s loop spun, taking the processor from
the other threads until each tick. Without a network card `netd` ends at
boot, which is why the system looked as fast when tried alone.

**Fix.** `vaddr_t arg4` in both futex entries. The other Linux and
native calls x86-64 uses were checked for 32-bit parameters: all are
values, not addresses. After it, `fetch` and `llm` take the i386's time.

**Lesson.** A parameter typed `uint32_t` that holds an address is a
64-bit bug waiting; and a fast system "alone" may only mean that the
spinning service did not start. Measure with the same devices the slow
case had.

## 2026-11-25 — The disk under KVM: not the driver's loop

**Symptom.** With KVM, copying 1.5 MB to `/disk` and reading it twice
took 11.5 s, and `ata` used 98% of the processor; with the processor
emulated (TCG) it took 2.55 s.

**Diagnosis.** `ata` waits for each sector by reading the status port in
a loop; under KVM every port access leaves the virtual machine. The
guess: the loop. The driver was changed to wait for the controller's
interrupt (IRQ 14) instead. Nothing changed under KVM (11.6 s, `ata`
95%), and under TCG it became 15% slower (2.94 s against 2.55, twice):
waking a process at each interrupt costs more than a few status reads
when the emulated disk answers at once. The same workload on the virtio
disk (`VIRTIO=1`, `vblkd`, DMA): 0.20 s under KVM.

**Cause.** QEMU's emulation of the IDE disk in PIO mode: each sector
moves through the data port, and under KVM each transfer is an exit to
QEMU's emulation. The driver's waiting was a small part of it.

**Fix.** None to `ata`: the interrupts were taken out again. A disk that
must be fast under KVM is the virtio one (or an IDE driver with
bus-master DMA); the issue for it is in beads.

**Lesson.** Measure the alternative before the fix: the virtio disk,
tried first, would have said in one run that the cost was the device's
emulation, not the loop.

## 2026-11-25 — x86-64: the terminal shows no output (an empty auxiliary vector)

**Symptom.** On x86-64 the Terminal window showed sh's prompt and what
was typed, but nothing a program wrote: not sh's banner, not `echo`'s
line, not `cat`'s file; a stray block at the start of each such line.

**Diagnosis.** The terminal received the text (a log of each Write) and
drew the rows (`Gfx.text` returned their cells), and displayd accepted
the damage. A small program then showed it: a window filled from a
second domain (or a Thread) stayed red on x86-64, green on the i386;
the domain read back red right after its own `Gfx.fill`, while a direct
`Bigarray.set` worked. `Gfx.fill` from any thread but the first drew
nothing: `clip_on`, a `__thread` variable meant to start at 0, read
-26000, and its neighbours held a return address in musl's `__clone`
and the domain's start function: the top of the new thread's stack. The
terminal draws programs' output from its service domain, and the
prompt from its main thread: hence one seen, the other not.

**Cause.** The kernel gave every program an empty auxiliary vector (on
both architectures). Without `AT_PHDR` musl finds no `PT_TLS`, takes
the TLS block as empty, and gives each new thread a TLS area of nothing:
its `__thread` variables lie on its stack's top, where `pthread_create`
writes its start arguments and `__clone` pushes a return address. On the
i386 the offsets happened to miss what mattered.

**Fix.** The kernel builds a real auxiliary vector on both
architectures: `AT_PHDR` (the program's headers in memory, inside the
loaded segment that holds them), `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ`,
`AT_ENTRY`, and `AT_RANDOM` (16 bytes from the kernel's generator: musl's
stack canary had none). `tests/abi` checks that a new thread's TLS
starts at zero and that the vector is there.

**Lesson.** "It works" on one architecture can be luck in the layout:
a libc's startup contract (here the auxiliary vector) is part of the
ABI, and an empty one fails silently.

## 2026-11-25 — SMP: what one processor had been hiding

**Symptom.** With the other processors started and the big kernel lock
in place, the x86-64 suite at four processors failed 21 checks: programs
killed by "invalid memory access" in musl's `free`, the graphical
session gone, the abi test failing one run in three, a lost write in the
new `tests/smp`, once a kernel panic (general protection) reading the
current thread right after a semaphore wait.

**Diagnosis and causes**, one at a time, each run several times in
parallel QEMUs:
1. *A fault resolved by another processor.* Two threads of a process
   fault on the same page; the big lock serialises the handlers, and the
   second finds the page already allocated (or copied): present and
   writable. The handler knew only "not allocated, not copy-on-write":
   the process was killed. On one processor the faulting thread is the
   only one that can retry.
2. *Fresh pages zeroed after being mapped.* `__allocateOnUse` set the
   entry, then zeroed the page through the user's address: a thread on
   another processor wrote into it in between, and the zeroing erased it
   (`tests/smp`: a lost increment).
3. *`fork` flushed only its own TLB*, after marking the parent's pages
   copy-on-write: a processor running another of the parent's threads
   kept writable translations, and wrote into the page now shared with
   the child. The shootdown also missed the direct map.
4. *A thread of a dead process going on.* Processor A kills a process
   while B, running one of its threads, waits for the big lock to enter
   a call: when B gets it, it runs the call for a process that no longer
   exists. The panic was its trace. Fixed at a call's start and at the
   way back to a process (not at the entry: an interrupt's handler must
   run, for its EOI).
5. *`reapZombies` checked "busy" by a process-table slot*, which may
   already be free or reused: now by the pid of each processor's thread.
6. *A test that assumed one processor* (`abi`: the connector freed its
   channel before the listener had looked at it), and the user-space
   malloc lock's `bts` without `lock`.

**Fix.** Each as above; the page-fault handler returns when the access
is allowed now (after flushing its own TLB entry); fresh pages are
zeroed through the kernel's window before the entry is set; `fork`
shoots down the address space; `smp_leave_if_dead` schedules away. The
suite passes at four processors; `tests/smp` covers 1-3.

**Lesson.** On one processor "the kernel runs one at a time" also meant
"no user code runs while the kernel works": the big lock keeps only the
first. Anything the kernel does to a process's memory in two steps
(map, then fill) is now visible half-done; and anything decided before
waiting for the lock may be false after it.

## 2026-11-25 — AArch64: three things a PC had been hiding

**Symptom.** The first AArch64 kernel (a) panicked in the physical page
finder, "KERNEL ERROR IN __find_first_free_physical_page"; (b) received
no modules from QEMU; (c) once programs ran, hung: the big kernel lock
held for ever after `ocamlrun`'s first sleep.

**Causes.**
- (a) `char` is unsigned on AArch64, signed on x86. The bitmap's bytes
  are `byte_t` (a `char`): `~byte` of a full byte is 0 when it is -1, and
  0xFFFFFF00 when it is 255, so a full byte looked like one with room.
  The kernel's C, and MyNOS's user-space C, were written where `char` is
  signed: both are built with `-fsigned-char` on AArch64.
- (b) QEMU passes `-initrd` and `-append` to Linux images only (its
  bootloader stub writes them into the device tree's `/chosen`); an ELF
  kernel gets neither. The modules now come as one archive that QEMU puts
  at 64 MB into RAM (`-device loader`), carrying the kernel's command line
  too (`tools/mkmodules.py`, `arch/aarch64/dtb.c`).
- (c) The thread's FP and SIMD state is 528 bytes (32 Q registers, FPCR,
  FPSR), stored at the first 16-byte boundary inside a 528-byte area: up
  to 15 bytes past it, over `kdepth`, the thread's big-lock depth. The
  idle thread came back with depth 0, `kernel_exit` never released the
  lock, and the next entry spun on it. Found by recording the lock's
  taker (an `svc #0x90` of `mynos_sleep`) and printing switches whose
  depths were not 1. The area is 16 bytes larger on AArch64.

**Lesson.** A port finds assumptions, not only missing code: the sign of
`char`, a bootloader's contract, a buffer sized for one instruction set's
save format.

## 2026-11-25 — AArch64: from OCaml's hello to the shell

**Symptoms and causes**, in the order met:
- *init.byte "has not the right magic number"*: ocamlrun found no file
  system, memrofs could not register. The registry had opened its port
  before `mynos_main` called `initIPC()`, which cleared the port table:
  the processes of the boot modules are made, the timer is on, and a
  quick process runs before the kernel goes on. Under emulated AArch64
  the registry was quick enough; on the PC never so far. `initIPC()` now
  runs before the modules' processes (all architectures).
- *consoled jumped to 0*: the thread start code of libmynos is a label in
  top-level assembly, local. Debian's gcc builds position-independent
  code and takes a function's address through the GOT; a GOT relocation
  against a local label keeps the section and loses the offset: the
  thread started at the section's first function. The label is global.
- *no keys*: the virtio queues' addresses given to the device were
  MyNOS's physical ones, numbered from RAM's base (doc/decisions/
  aarch64.md, choice 3); the device needs the real ones. `allocDma`
  returns `ARCH_BUS_ADDR`, the real address on AArch64.
- *no virtio device found*: `mapPhysical` took any address below RAM's
  size for RAM and refused any above 4 GB (the i386's rules); on AArch64
  devices have real addresses, which RAM's numbering does not share:
  `ARCH_DEVICE_PHYS_OK`. And no firmware assigns PCI windows on `virt`:
  libmynos's `virtio_find` gives each slot its own 1 MB and the line of
  virt's swizzle.

**Lesson.** Moving RAM's numbering made three kinds of address: the
kernel's (from 0), the CPU's (real) and the device's (real): every place
where an address leaves the kernel says which it is.

## 2026-11-25 — OCaml domains 13 times slower on one processor (mynos-c6a)

**Symptom.** `par.byte` (tests/cpu/par.ml) building and dropping lists
in one domain: 6.93 s on one processor, 0.51 s on four, under KVM.
Computation alone ran at the same speed on both.

**Diagnosis.** A first guess, that the runtime's back-off sleeps of some
microseconds lasted a whole tick on MyNOS, was measured and was wrong
(sub-tick sleeps made a yield: no change). Counting the system calls
showed almost the same on one processor as on four: the time was not in
the kernel. The timer then sampled the user program counter at each
tick, and a snapshot of the process's threads at each time slice:
the domain's thread was in `caml_try_run_on_all_domains_with_spin_work`
and `caml_empty_minor_heaps_once`, and another thread of the process,
the main domain's backup thread, was ready, at every slice. OCaml's GC
log (`OCAMLRUNPARAM=v=0x800`) told the rest: 2220 retries of
"requesting stw empty_minor_heap" by domain 1 while domain 0 had not yet
closed the previous section.

**Cause.** At a minor collection the allocating domain leads a
stop-the-world section and wakes the main domain's backup thread (a
futex). Both do their part; the domain finishes first, allocates again,
and at the next collection finds the section still open (the last one
out closes it): it retries in a loop, without a system call. The backup
thread, woken and ready, ran only when the domain's 10 ms slice ended:
about 10 ms lost at each of some 50 collections. On Linux the woken
thread preempts its waker (CFS's wake-up preemption), and nobody waits.

**Fix.** `FUTEX_WAKE` hands the processor to the first thread it woke
(`sched_handoff`), the waker staying ready in its place, unless another
processor idles and takes it. One domain: 6.93 s to 1.05 s on one
processor (0.48 on four). With more domains than processors the leader
also waits for domains that are ready but were not woken by it: the
slice's length still decides there (a 4 ms slice halves those times;
left to the owner, doc/decisions/smp.md).

**Lesson.** A spin that is not in the kernel cannot be seen by counting
calls: sample where the processor is. And a mere "the thread I woke is
ready" means nothing to a scheduler that lets the waker keep its slice.

## 2026-11-25 — The other processors started after the first programs

**Symptom.** A new check, `tests/smp` printing `sysconf(_SC_NPROCESSORS_ONLN)`
(which musl answers with `sched_getaffinity`, added today), read 1 on
x86-64 with four processors; `nproc` typed in `sh` read 4.

**Cause.** `mynos_main` started the other processors last, in what then
becomes processor 0's idle thread: after the boot's processes had been
made, with the timer on. The idle thread runs only when nothing else is
ready, so the first program (here the test, a module) ran before the
others were up; under load the processors could come up later still.

**Fix.** `arch_smp_start` before the ports and the boot's processes, as
Linux starts its processors before init; the boot's work that follows,
on the kernel's tables, under the big lock (`arch_boot_lock`, a no-op on
the i386 and on AArch64, one processor), since the other processors may
run the scheduler from then on.

**Lesson.** "Started at boot" must mean before the first program, or
the first program sees a different machine from the others.

## 2026-11-25 — AArch64: the console on the UART, run-demo.sh

**Symptom.** `ARCH=aarch64 tools/run-demo.sh` booted the i386 system:
run-demo.sh knew only i386 and x86_64. Once it booted AArch64, nothing
could be typed: the system has no display there yet, and consoled read
COM2's keys with `inb`, which on ARM user space was a stub reading 0xFF.

**Fix.** The kernel's table of the PC ports it answers on AArch64
(`arch/aarch64/io.c`, already COM2's output for the log) gained COM2's
input from the PL011 (data, line status, scratch, receive interrupt);
drivers reach it through a native call (102) that libmynos's `inportb`
and `outportb`, and OCaml's `Mynos.inb`/`outb`, use on ARM. The rest
reads 0xFF: ata now finds no disk and ends with 0, where it raised
"no I/O ports" and init restarted it five times. The PL011's interrupt
is level-triggered: consoled registers it as a PCI line (masked at each
interrupt, unmasked after reading), on line 1. run-qemu.sh and
run-demo.sh take `ARCH=aarch64` (doc/decisions/aarch64.md, choice 9).
On the way: virtio-net-pci wanted a boot ROM the container's QEMU has
not (`romfile=`); a test of mine, `pkill -f` with a pattern in its own
command line, killed its own shell.

**Lesson.** A port I/O table in the kernel, which was there for the log,
was the shortest way to a serial console: the driver did not change.

## 2026-11-26 — AArch64 SMP: a byte skipped by copy_user, and three more

**Symptom.** With two or more processors, displayd died in musl's `free`
(called from `mynos_freeMsg` in its main loop) as soon as the graphical
session had events (keys or the mouse); a client of it (ocamlrun) too.
Never with one processor, never on x86-64 with the same virtio devices
and four processors.

**Diagnosis**, by elimination (each a few boots of a script that types or
moves the mouse in the session): not the futex handoff, not the TLS, not
`malloc` and `mmap` in parallel, not IPC with shared pages, not musl's
locks, not the TLB (a full broadcast flush changed nothing). The
registers at the crash: the pointer given to `free` was not aligned (its
low bits 4): a `mynos_msg_t` with wrong contents. Sending long messages
by copy instead of copy-on-write made it go away, and so did copying only
displayd's.

**Cause.** `copy_user` on AArch64 is a loop, `LDRB` then `STRB`, each
moving its pointer on. A fault in it was resumed at the loop's start
(for mem.c's fixup, which looks for one address, the i386's single
instruction). After a faulting `STRB` the `LDRB` had moved the source
on: starting over skipped a byte, and the rest of the copy came out
shifted. `recv` writes the message's description into the receiver's
memory; in displayd that was a page of its heap another of its threads
had just sent a reply from, copy-on-write: the kernel's write faulted,
the copy was made, and the description came out shifted by a byte.

**Fix.** The fault is handled with the loop's start as the address
mem.c knows; if it was resolved, the copy resumes at the instruction
that faulted.

**On the way**, found and fixed (each real, none the cause):
- a receiver waiting with a timeout could be woken twice, by its timer
  and by a sender that still found it waiting: its private semaphore
  left at 1, its next wait returned at once (every architecture; ipc.c,
  channel.c);
- the drivers assigned PCI's memory windows on AArch64, each for every
  device it looked at, under the owner's feet: the kernel does it once at
  boot now (arch/aarch64/pci.c), as the PC's BIOS;
- `clrex` before every return from the kernel (a reservation of another
  thread must not survive a switch).

**Lesson.** A fault in the middle of a multi-instruction copy must resume
where it stopped. And a bug seen only with many processors is not always
a race on shared data: here the processors only made two rare events
meet often.

## 2026-11-26 — AArch64 SMP: a stack seen through two page tables

**Symptom.** The other processors started ("Processor 0 started", three
times), `tests/smp` failed with two of them: `pthread_join` returned
ETIMEDOUT without a timeout, and the counters were short.

**Diagnosis.** A futex wait woke with its waiter still listed: the
thread's private semaphore had gone below zero, never V'd. A P had
returned from `sched()` without being woken: `sched` found nothing else
ready and, with no idle thread on that processor (`arch_cpu()->idle` was
0), went back to the thread that was blocking. `ap_main` did set it: it
printed `c->idle` right, and `arch_cpu()->idle` 0 just after. `c` was
`&cpus[0]`, and its number 0.

**Cause.** A processor started by PSCI turns its MMU on with the boot's
tables (`pt_l0_lo`). Its stack, a page the kernel allocated, is mapped by
the kernel's tables (`kernel_pml4`) and is elsewhere in the boot's.
`ap_main` saved its argument on the stack, switched to the kernel's
tables, and read it back from another physical page: 0. So every
processor wrote its idle thread into processor 0's `struct cpu`.

**Fix.** start.S switches to the kernel's tables (their real address,
`ap_ttbr0`) before it touches the stack.

**Lesson.** Changing the page tables under one's own stack is changing
the stack.

## 2026-11-26 — x86-64 with KVM: no graphics (PCI's two ports)

**Symptom.** `ARCH=x86_64 tools/run-demo.sh`: `gui` answered "no display
service"; displayd had found "no Bochs VGA". The suite (no KVM) passed,
and so did the demo with `KVM=`. It had worked before x86-64 had four
processors.

**Cause.** PCI's configuration space is read in two port accesses: the
address to 0xCF8, then the data from 0xCFC. displayd and libmynos (netd,
vblkd, consoled's virtio keyboard) each did both. At boot they all look
for their devices at once; with KVM four processors really run them
together, and another driver's address came in between: displayd read
someone else's register. Under emulation the window was too small to
be hit; on the i386 a timer switch between the two could do the same.

**Fix.** A native call (103) does both accesses in the kernel (interrupts
off, the big lock); libmynos's `pci_read32` and `pci_write32`, and
displayd, use it.

**Lesson.** A pair of ports holding a state between two accesses is a
lock nobody takes. On one processor it was safe by luck.

## 2026-11-26 — The kernel's heap corrupted at boot, under load

**Symptom.** The suite on AArch64 (emulated, nine lanes at once): in the
stress test's boot, "memrofs service port: -2" (BUSY: a port whose queue
of connections is full, at boot), then "kernel heap: free list corrupted"
in `newPort`, then a kernel page fault. Alone, the same boot passed every
time.

**Cause.** `mynos_main` makes the boot's processes after `tsksw()`, with
interrupts on (`init_idt` turns them on early) and the timer running. The
timer switched it out in the middle of a `kmalloc` or of `createProcess`,
to a process just made whose system calls changed the same tables. The
big lock did not help: it is the processor's, and a thread of the same
processor took it again. On the PC, fast, the window was never hit; the
`initIPC` race of 2026-11-25 was the same one, seen from another side.

**Fix.** The boot's processes are made with this processor's interrupts
masked (and, for the others, under the big lock): `arch_irq_disable`
around the work after `arch_smp_start`.

**Lesson.** Code that runs with interrupts on and no lock of its own is
preemptible kernel code: MyNOS's kernel is not written for that, and
the boot was the one place doing it.

## 2026-11-25 — AArch64: the pager's dirty bit, kept by faults

**Symptom.** `tests/abi`, ported to AArch64, failed one check: "pager:
copy: the page, its writes forgotten". After `mynos_pagerCopy` the page
still read as written.

**Cause.** ARMv8.0 (the Cortex-A72 of the Pi 4) has no dirty bit the
kernel can use, and AArch64's `pte_mark_clean` did nothing: a writable
page was "written" until given again (a limit noted in the code). The
accessed bit was the same: `pte_mark_old` cleared MyNOS's bit, but the
hardware's access flag stayed on, and nothing set the bit again.

**Fix.** Kept by faults, as on processors without them: forgetting the
use clears the access flag too, and the next access faults; writing a
page back makes it read-only for the hardware (MyNOS's writable bit
kept), and the next write faults. The page fault handler's "the access
is allowed" path (a fault resolved meanwhile by another processor) calls
`pte_fault_fixup`, which on AArch64 sets the access flag and the
accessed bit, and on a write the hardware's writable bit and the dirty
one; on x86 it does nothing (the processor keeps the bits). Only pages
the pager has looked at pay the extra fault.

**Lesson.** A test ported to a new architecture finds the shortcuts
taken there: this one was written down, and still wrong.

## 2026-11-26 — GavML flickered on several processors

**Symptom.** GavML's sprites flickered on x86-64 and AArch64, not on the
i386.

**Cause.** A window's pixels are shared by its program and displayd. To
`damage` (show this frame) displayd answered first and then copied the
frame to the screen. The program, answered, drew its next frame at once
in the same pixels (GavML copies its background, then the sprites):
on another processor displayd was still copying, and sometimes the
screen got the background without the sprites. On one processor the
program does not run until displayd has done.

**Fix.** First, displayd answered `damage` after copying: not enough,
since displayd also composes for other reasons (the pointer, the clock,
other windows) while the program draws. Then the real one: displayd
keeps a copy of each window's pixels, taken at attach, resize and
damage (the frames the program said were done), and composes from it,
never from the program's live pixels.

**Lesson.** Two processors drawing in and reading from one buffer need
a hand-over: here the copy taken at the program's word.

## 2026-11-27 — MyNOS on a Raspberry Pi 3 (QEMU raspi3b)

**Goal.** The Raspberry Pis' common base (btq.7) on QEMU `raspi3b`,
the Pi 3's and Zero 2 W's chip.

**What the machine does.** A probe of a few instructions showed it: a
raw image (`kernel8.img`, as the Pi's firmware wants) starts at 0x80000,
at EL2, x0 zero (the real firmware gives the device tree there), the
other three processors waiting in the firmware's spin tables; an ELF
image instead starts at EL3 with all four processors. The PL011 prints
only once its control register turns it on (the firmware does that on
a real Pi).

**Choices.** One kernel per platform (`MYNOS_RASPI`): RAM's base is
part of the kernel's numbering (0x40000000 on `virt`, 0 on a Pi). The
image moves itself to 2 MB, where it is linked. The RAM's maps stop at
the peripherals: a normal-memory map over device registers lets the
processor read them speculatively. The kernel keeps the GIC's
interrupt numbers, and the Pi's two controllers translate into them.

**Findings.** Every driver started at boot: those that look for PCI
(`vblkd`, `netd`, `displayd`) would have mapped QEMU `virt`'s ECAM, an
address with nothing behind it on a Pi (an external abort).
`mapPhysical` now maps only the platform's own device ranges, and the
drivers, told no, end as on a machine without the card. A Pi has no
real-time clock: the CMOS emulation's 1970 became 2070 in the kernel's
reading (two-digit years are 20xx); the time starts at the build's
commit instead. The framebuffer, mapped as device memory, would fault on
the unaligned copies of programs' `memcpy`: the VideoCore's memory is
mapped normal non-cacheable for programs.

**Lesson.** A new board is mostly "what does the firmware leave, and
where": a probe of ten instructions answered it before any code.

## 2026-11-27 — The Raspberry Pi's SD card

**What was done.** `sdhcid`, the SD card's driver through the SDHCI
controller (Arasan's on the BCM2837), and a card image for a real Pi.

**Findings.**
- The card's size came out 480 MB for a 64 MB card: the CSD's
  version-1 `C_SIZE` (bits 73:62) was taken from the wrong bits. The
  response registers hold the CSD without its CRC, each bit 8 places
  lower: the field spans RESP1's top 10 bits and RESP2's bottom 2.
- QEMU wants an SD card's image a power of 2 in size; MyNOS's disk
  images are (64 MB).
- On `raspi3b` the first `-serial` is the PL011: a manual run with
  `-serial null -serial file:...` put the output on the mini UART and
  looked like a dead kernel (run-qemu.sh keeps the caller's second).
- With `gui &` the shell and displayd's keys thread read the console
  together: after the session ends, displayd's pending read may take
  the next line. Not seen with `gui` in the foreground; the suite types
  `shutdown` again until QEMU ends.

**Real hardware, not yet tried.** The BCM2835's controller loses a
register write that follows another closer than two of the card's clock
periods (Linux's `sdhci-iproc.c`): `sdhcid` waits 10 µs after each while
the clock is 400 kHz. A real card has a partition table: fatfs now
looks for an MBR's first FAT partition.

- The suite's new lane j passed alone and failed in the whole suite:
  its log and monitor socket were `$tmp/logr` and `$tmp/mon-r`, the
  names lane c's restarts already used. Two lanes wrote one log and
  talked to one monitor. Renamed (`logpi`, `mon-pi`).
- With three suites and one more emulated machine at once, two checks
  that slept a fixed time failed on x86-64: the boot without COM2 typed
  after 5 s and looked once 3 s later; the first boot was killed at
  10 s, before `abi` ended. Both now wait for what they look for (the
  prompt, then the answer; `abi`'s last line), with a cap.

**Lesson.** A field read from a register dump needs its bit positions
written down beside the code: the arithmetic is easy to get wrong. And
lanes that share a directory need names of their own.

## 2026-11-27 — Ending the graphical session without a mouse

**Symptom.** On QEMU's Raspberry Pi (no mouse), `gui &` then `gui stop`
stayed stuck for the user: the shell and the session's keys read one
console, and the line went to the window in front.

**Fix.** A key: Ctrl-Alt-End. consoled sends it in raw mode as xterm
does (`ESC [ 1 ; 7 F`, the modifier 7: Ctrl and Alt), a serial terminal
sends the same; displayd ends the session on it.

**Two more findings on the way.** The sequence is 6 bytes: the first
try compared 7 (and consoled sent the string's NUL too), and nothing
happened. And from a serial terminal the bytes come as they come: a
read of displayd's could end inside a sequence, whose ESC then counted
as the Escape key and the rest as text. displayd now keeps an
unfinished sequence for the next read; an ESC that nothing follows
within 0.1 s is still Escape.

**Lesson.** Count an escape sequence's bytes, don't guess them; and
code that assumes "a read ends with a whole key" holds for one source
(consoled's keyboard) and not for another (a terminal's bytes).

## 2026-11-27 — The Pi 4's PCIe, first part

**What was done.** The BCM2711's PCIe bring-up in the kernel, as Linux's
`pcie-brcmstb.c` does it, from the Pi 400's device tree's own numbers
(its `ranges`: the CPU's 0x6_0000_0000 is PCI's 0xC000_0000, 1 GB; its
`dma-ranges`: PCI 0 is RAM's 0, 3 GB; its interrupt, SPI 147, not the
143 first guessed). Only when the firmware's device tree has the
controller: QEMU's `raspi4b` has nothing at 0xFD500000.

**Finding.** libmynos's PCI functions, once taught the Pi 4's bridge,
hung every PCI driver on QEMU's `raspi4b` (consoled, vblkd, netd,
displayd never answered): the bridge's registers lie inside the
BCM2711's peripherals' range, which `mapPhysical` allowed, and an
access with nothing behind it never ended. The bridge is now mapped
only once the kernel has brought the link up.

**Also.** Ctrl-Alt-End failed once in the lane on the emulated Pi 3:
the terminal's ESC and the rest of the sequence came in two pieces
more than 0.1 s apart through the emulated UART. displayd now waits
0.3 s after a lone ESC, 1 s after a begun sequence (ncurses waits 1 s).

**Lesson.** "The platform's device range" is too coarse once a device
inside it may be absent: such a device gets its own gate.

## 2026-11-27 — The USB, on QEMU first

**Goal.** The Pi 400's keyboard is USB, behind the VL805, an xHCI
controller behind PCIe. QEMU's `raspi4b` has none of it, but QEMU's
`virt` has `qemu-xhci`: the driver was written and tried there, the Pi's
differences kept small (the controller found on PCI either way; its
DMA kept out of the caches by hand, `dc cvac` and `dc civac`, which
EL0 may use).

**A design turned back.** The keys first went to consoled as a new
request of `console/1`. But consoled serves its requests on one thread,
which waits inside a `read` for the next key: a key sent to it as a
request would wait for that thread, which waits for the key. consoled
got a second service instead, `keys/1`, on a POSIX thread of its own
(its other threads share main's TLS and keep away from the C library;
this one needs `wire`'s buffers). displayd likewise got `pointer/1`.
`console/1` is unchanged.

**Findings.** QEMU aborted on QMP's `input-send-event` aimed at one
device with no display (`qemu-fixed-text-console.device not found`):
the test boots without the virtio keyboard and pointer instead, so that
the monitor's `sendkey` and `mouse_move` reach the USB ones.

**Lesson.** Before adding a request to a server, look at what its
serving thread waits for.

## 2026-11-27 — The stress test's "jump to 0xC" was the test's (mynos-4dz)

**Symptom.** On x86-64 and AArch64, with four processors, the stress
test died now and then right after its IPC check: `process 3: a jump to
0x12C` (or 0xC, 0x8). Never alone, never under a plain load: only in
the three suites at once, and more often as the suites got heavier.

**Cause.** The test. Its timers' round starts 16 threads, each on
`stacks[i]`, and waits for each one's `V(done_sem)`; the next round
starts 16 more on the same stacks. But a thread says "done" and then
returns, on its stack, to the thread start's exit: on another processor
the next round's thread i had already written its first frame there,
and the return found a word of it. `pingpong` reused its ponger's stack
the same way.

**Fix.** Each round waits for its threads to have ended, as the kernel
counts them (`mynos_procstat`'s threads), before the stacks are used
again.

**And the suites' load.** Three suites at once run about 80 emulated
processors on 16 cores. Lane j (three emulated boots more) pushed
checks that wait a fixed time over their budget: lane j now starts
100 s later (when the short lanes are done; it still ends before the
longest), the USB boot has one processor, and three checks wait for
what they look for instead: the agent's last line before the next
command is typed (its first key went to the agent, still reading the
console: `sh: gent: command not found`), the host's fetch of MyNOS's
page before the network boot is stopped.

**Lesson.** "Done" said by a thread is not "ended": its stack is still
its own until it has returned.

## 2026-11-27 — The USB's hubs, before the Pi 400 (mynos-btq.8.5)

**Why now.** Before the first try on the Pi 400: on a Pi 4 and a 400
the USB 2 devices are not on the VL805's root ports but behind its own
USB 2 hub (VIA Labs 2109:3431), the 400's keyboard (a Holtek) too. A
usbd without hubs would have found one device on the board, the hub,
and no keyboard: the try would have told nothing about the keys.

**What was done.** usbd attaches a USB 2 hub as any device, then: its
configuration, its hub descriptor (ports, power-on time, the TT's think
time), the hub's fields in its slot's context (Hub, ports, TTT, set
with its interrupt endpoint's Configure Endpoint), its ports powered,
each connected one reset (`SET_FEATURE PORT_RESET`, then `C_PORT_RESET`
waited for), its speed from `wPortStatus`, the device attached with a
route string (four bits a tier) under the same root port. A low- or
full-speed device behind a high-speed hub names that hub's slot and
port as its transaction translator. Devices are found once, when usbd
starts (none plugged in later yet). The log names devices by where
they are: `port 5.1` is port 1 of the hub on root port 5.

**Tried.** QEMU's `virt` with `usb-hub` (a full-speed hub: no TT there)
and the keyboard behind it, as on a 400; the suite's USB boot now has
it so. The TT path runs only on the board.

**Lesson.** Look at the board's USB tree (`lsusb -t` on its Linux)
before deciding what "the keyboard on a root port" means.

## 2026-11-27 — The Pi 400, first try: the PCIe up, the USB's address wrong

**Symptom.** On the Pi 400 (the image of 7df92ac) MyNOS boots to the
shell on HDMI, four processors, and the kernel says `PCIe: revision
0x304, link up, 0x34831106 at 0x600000000`: the link trained, the VIA
VL805 (0x1106:0x3483) answered on bus 1. But no key of the 400's
keyboard reached the shell, and nothing of usbd showed: services'
messages leave the screen once the shell starts.

**Diagnosis.** usbd mapped its controller at the BAR's address, as on
QEMU's `virt`. But a BAR holds an address of the PCI bus: the kernel
had put the VL805 at PCI's 0xC000_0000, which the processor reaches at
0x6_0000_0000 through the outbound window. usbd asked for 0xC000_0000,
which the kernel refuses (RAM, not the window), and ended.

**Fix.** libmynos's `pci_cpu_address`: the BAR's address as the
processor reaches it (the Pi 4's window; the same elsewhere); usbd maps
that. `make-sd-raspi.sh` takes `VERBOSE=1`: the kernel's command line
says `verbose`, and the services' messages stay on the screen, for a
board with no serial cable.

**Lesson.** On `virt` the PCI bus's addresses and the processor's are
the same: a driver tried only there never learns that they are two.

## 2026-11-27 — The Pi 400's mouse: a moment, then nothing

**Symptom.** With the VL805 mapped right (9401496), the Pi 400's own
keyboard typed into the shell and `gui` started; a USB mouse moved the
pointer for a fraction of a second, then never again.

**Diagnosis** (a guess, not confirmed: the log of the next try, where
the mouse worked, shows no failed transfer at all). On a failed
interrupt transfer (a stall, a transaction
error: likelier for a low-speed mouse reached through the hub's
transaction translator, many reports a second) the xHCI halts the
endpoint. usbd queued the next transfer as after a good one; a halted
endpoint takes it and does nothing: the mouse was never read again.
On QEMU no transfer ever fails.

**Fix.** A failed transfer is logged; if the endpoint's context says
Halted, usbd sends Reset Endpoint (keeping the data toggle, but for a
stall, which `CLEAR_FEATURE(ENDPOINT_HALT)` clears on the device too)
and Set TR Dequeue Pointer past the failed TRB, then reads again. The
ports' changes, the root's and the hubs' (their status change
endpoints now read), are logged and acknowledged. The mouse works, but
that try's log has no `a transfer failed`: the first try's stop is
still unexplained; if it comes back, the log will say what it was.

**The board's USB tree** (that log): the VL805's hub, 2109:3431, high
speed, 4 ports, on root port 1; a mouse (093a:2510) on its port 3 and
the 400's keyboard (04d9:0007) on its port 4, both **low** speed:
reached through the hub's transaction translator, the path QEMU's
full-speed `usb-hub` never takes, and it works.

**Lesson.** An error path that "goes on as before" is a path never
tried; and a fix that came with the cure is not the cure until a log
says so.

## 2026-11-27 — GENET, the Pi 400's Ethernet, at the first try (mynos-btq.8.4)

**What was done.** `services/net/genet.c`, netd's third card, from
U-Boot's and Linux's drivers' registers: the receive buffer flushed and
the UniMAC reset, the PHY (a BCM54213PE at MDIO address 1, RGMII with
the receive clock delayed by the PHY: the MAC's own delay off,
`ID_MODE_DIS`) reset and autonegotiated, the default queue's two rings.
All 256 descriptors go to that ring, as U-Boot does: a descriptor is
then the producer's or consumer's count modulo 256 whichever way the
GENET counts, the one thing about it no document settles. The MAC
address is the board's, asked of the firmware (tag 0x00010003) through
a new native call, 105 (`mynos_piFirmware`), which the Wi-Fi will want
too (its power is on the firmware's GPIO expander). The kernel lets a
driver map the GENET only if the device tree has it: on QEMU's
`raspi4b` netd finds no card and ends, as before.

**A finding before the board.** netd, without a DHCP answer in 5 s,
took QEMU's user network's address (10.0.2.15): on a real network a
wrong address for good. On a GENET DHCP goes on trying.

**Tried.** On the Pi 400, with a cable to the LAN's router: the link
up, an address from its DHCP, ping 1-2 ms (the interrupt works:
polling would be up to 100 ms), 1400-byte pings 50 of 50, MyNOS's httpd
answering a browser of the LAN. The kernel's log can now be read from
another computer: `log > /disk/web/log.txt` on the Pi.

**Lesson.** Where two drivers that work disagree on nothing, copy what
they agree on (here: every descriptor to one ring) rather than the
cleverer layout.

## 2026-11-27 — wifid broke the emulated Pi 4's SD card (one controller, two owners)

**Symptom.** With wifid added (btq.9, its first step), lane j's Pi 4 on
QEMU failed to write its SD card: `sh: /disk/r4.txt: Invalid argument`,
while wifid was still trying its SDIO card.

**Cause.** The same controller has a different owner on each machine. A
real Pi 4's Arasan SDHCI (0xFE300000) is the Wi-Fi's, its SD card on
EMMC2; QEMU's `raspi4b` puts the SD card on the Arasan controller (and
has no Wi-Fi), which sdhcid knows ("tries both"). wifid reset that
controller and sent CMD0 under sdhcid's card.

**Fix.** The firmware's device tree decides: the kernel notes `wifi@1`
(`brcm,bcm4329-fmac`) as it notes the PCIe and the GENET, and a native
call, 106 (`mynos_piDevices`), tells drivers. wifid runs only if the
device tree has a Wi-Fi; sdhcid leaves the Arasan controller alone if it
does. On QEMU (no device tree from a firmware) nothing changes for
sdhcid, and wifid ends at once.

**Also.** The Pi 400's mouse's wheel (btq.8.7): usbd set every mouse to
HID's boot protocol, whose three bytes have no wheel. A mouse now keeps
the report protocol when its report descriptor is understood (its
buttons, X, Y and wheel found, report id included); else the boot
protocol as before. QEMU's mouse reports its wheel that way.

**Lesson.** "This controller is the Wi-Fi's" is a fact of a board, not
of a chip: ask the board's description, not the address.

## 2026-11-27 — The Pi 400 joins a network, and the handshake times out

**What the log said.** The CLM loaded, the country set, the join done,
the link up; then `disconnected (event 6, reason 15)` (a deauthentication
from the AP: reason 15 is "4-way handshake timeout"), again and again.
Two commands had no answer at all (the scan, `SET_AUTH`); one failed
with -23: `sup_wpa`.

**Two causes.** -23 is the firmware's "unsupported": the Pi 400's
firmware has no supplicant of its own, the one thing the design counted
on (doc/decisions/wifi.md: corrected). The AP sent its first EAPOL-Key
frame and nobody answered. The commands without an answer: SDPCM's
credit. The firmware says in every frame's header up to which sequence
number it will take frames; wifid ignored it, and after the CLM's six
pieces sent in a row the firmware dropped what came beyond its window,
silently.

**Fix.** A frame waits for the firmware's credit (reading its frames
meanwhile). The handshakes are the host's: `services/wifi/wpa.c`
(PBKDF2-HMAC-SHA1, the 802.11i PRF, HMAC-SHA1 MICs, RFC 3394's unwrap;
SHA-1 and AES from mbedTLS), checked on the host against IEEE 802.11's
PBKDF2 vectors, RFC 2202's HMAC and RFC 3394's unwrap, and the PRF's
test vector. EAPOL frames come on SDPCM's data channel, after BDC's
header; they are queued and answered outside the frames' loop (the
replies and the keys go through the same buffer as the commands).

**Lesson.** A protocol's flow control is part of the protocol even when
the first messages get through without it; and a firmware's feature is
a fact to ask it (`cap`), not to assume from another firmware.

## 2026-11-27 — The lost answers were in superframes (glom)

**Symptom.** Commands without an answer, a different one each try (the
scan, `SET_INFRA`, `SET_AUTH`), and always the pairwise key's after the
handshake's message 4; no frame read failed.

**Diagnosis.** wifid was taught to log what came while it waited: frames
on channel 3, 16 bytes with flags 0x83 and then 1056 or 448 bytes. SDPCM's
glom: the firmware gathers several frames into a superframe, announced
by a descriptor (the subframes' lengths), and wifid dropped both. The
answers in them were lost; others came late, behind them (the scan's
answer, id 15, arrived while the next command waited). With one more
attempt for a command without an answer, both keys went in and the Pi
400 was connected, WPA2, to the LAN's network.

**Fix.** `bus:txglom` set to 0 when the firmware starts, as Plan 9's
ether4330 does: no superframes to the host.

**Then the frames (step 4).** wifid serves `wifi` (its MAC address, a
frame to send, its status) and `wifirx` (the frames received), each on a
thread of its own so that a waiting receive holds no send up; only its
main thread touches the SDIO, the frames go through two queues. netd
uses the Wi-Fi as its card when the GENET has no link (`wifinet.c`: a
thread waits on `wifirx` and wakes the main loop as an interrupt would),
and registers its service before waiting for wifid (half a minute;
programs give up after 5 s).

**And a near miss.** `mynos_piDevices` returned the kernel's error on a
PC (-3, no call 106): -3 & 4 is 4, "a Wi-Fi". netd on i386 would have
waited for a wifid. It returns 0 on an error now.

**Lesson.** Log what you drop: the superframes were there from the first
try, silent.

## 2026-11-27 — Over the Wi-Fi: HTTP works, the keys installed twice

**What the log said** (read over the Wi-Fi itself, from MyNOS's httpd at
the Pi's Wi-Fi address): the scan works (seven networks: the
superframes were the cause), DHCP, TLS, HTTP over WPA2. But a cycle:
the keys installed, then the AP's deauthentication (reason 3, then
class 3 frames, reason 7), the link up again, the handshake again.
And always the same shape: a command's answer came only while the next
command waited (SET_AUTH's, the pairwise key's, the group key's), and
the second attempt was always answered.

**Diagnosis (probable).** Two things. The second attempt installed each
key twice: a key installed again has its packet counters reset, which
an AP takes for replays; it ends the association. And the answers that
wait: since the previous try wifid read function 2 at every poll, the
chip saying a frame was there or not; brcmfmac never reads it empty,
and the answers seemed to come only after the host wrote to the chip.

**Fix.** Function 2 read only when the chip says a frame is there (the
indication read again after each batch, as brcmfmac). A command is sent
once; if its answer is late, a harmless command (WLC_GET_MAGIC) is sent
after 300 ms and every second, and the answer awaited up to 5 s.

**Lesson.** A retry is not harmless when the command has a state: a key
is not a question.

## 2026-11-27 — The Pi 400's mouse stops: it had come again, and nobody asked

**Symptom.** After a while in the graphical session the USB mouse
stopped, its light off (the first try's stop, unexplained then).

**Diagnosis** (usbd's log, read over the Wi-Fi). The hub said `port 1.3:
changed (status 0301, changes 0001)`: a connection change, the mouse now
connected, powered, low speed, but not enabled. It had gone and come
again by itself (a glitch, or the mouse resetting itself). usbd only
logged it, and went on asking the old device's endpoint: 8700 transfers
failed with code 36 (split transaction error, the hub's TT finding
nobody), the mouse never configured again, its light off.

**Fix.** A hub port's connection change is now a plug: the old device
detached (Disable Slot, its entry free, a hub's devices with it), and if
something is connected, the port reset and the device attached again.
After 20 failed transfers in a row a device is left alone until its
port changes. Tried on QEMU (a mouse behind the hub removed and added
again from the monitor: gone, then a mouse again; the keyboard types on).

**Lesson.** On real hardware "plugged at boot" is not "plugged for
ever": a device may come back as a new one without anybody touching it.

## 2026-11-27 — The Pi 400 at a twentieth of a PC: not its clock

**Symptom.** The `bench` package on the Pi 400 scored 81 (1000: MyNOS in
QEMU with KVM on the reference PC, an i7-12650H): the processor's
measures at 3 to 6 % of the PC's, memory copies 1.1 GB/s, drawing 2 %.
The emulators follow: the MSX under 10 frames a second, the Spectrum 20
(on the PC, unthrottled, 212 and 330: a twentieth of each).

**Diagnosis.** First suspect, the clock: the firmware answers
`GET_CLOCK_RATE` (clock 3, the ARM) with 600 MHz, its minimum, and Linux
raises it through the mailbox (cpufreq). The kernel asked for the
maximum at boot (`SET_CLOCK_RATE`, 1800 MHz): the answers made no sense
(500 MHz once, below the minimum; then no answer at all), and the
firmware's `GET_CLOCK_RATE_MEASURED` answered nothing. So the kernel now
measures the clock itself: the processor's cycles (`PMCCNTR_EL0`) in
10 ms of the generic timer. On the Pi 400: `ARM clock: 600 MHz (measured
1799), asked 1800: answered 0, now 1800 (measured 1800, ...)`, not
throttled. The ARM was at 1.8 GHz from the start, whatever the firmware
said.

**Not the cause either.** The caches (MAIR 0 write-back, SCTLR's C and
I, RAM's pages normal and inner shareable, MyNOS's page flags clear of
the attribute index); the bytecode interpreter's compilation (the
AArch64 runtime's `libcamlrun.a` is built `-O2`, as on x86); idle
processors (they wait with `wfi`); the drivers' polling (usbd and wifid
sleep 5 ms between rounds).

**Where it stands.** No fault found. The same bytecode, the MSX1's
bench, runs at 197 frames a second on the PC and 24 on the Pi: an
eighth, what an A72 at 1.8 GHz is to a core at 4.7 GHz; the bench's
twentieth is against its reference, MyNOS i386 under KVM. The
emulators' answer is native code (2026-11-28, below). The request for
the maximum stays, harmless, and the measured clock is logged.

**Lesson.** On a board whose firmware owns the clocks, what the
firmware says the clock is and what it is are two things: measure it.

## 2026-11-28 — OCaml's native code on AArch64: the GC's mark in the top byte

**Symptom.** The first native OCaml programs for MyNOS on AArch64 (a
cross `ocamlopt` 5.5.2 for aarch64-linux-musl, linked with libmynos:
btq.4 taken up again for the Pi) ran, until their first minor
collection: there they stopped for ever. `Gc.minor ()` alone was enough;
the bytecode runtime, the same sources, never did.

**Diagnosis.** gdb (QEMU's stub, gdb-multiarch in a container) stepping
through the GC stopped in different places; the processors were idle.
QEMU's `-d int` told: 900 000 prefetch aborts in a minute, all from EL0
at `0x1000000040003804`, ESR 0x82000004 (a translation fault) — the
return address into `camlM3.entry` with bit 60 set.

**Cause.** OCaml 5's arm64 runtime marks the stack frames its GC has
already scanned by setting bit 60 of their return addresses
(`CODE_POINTER_MARK_BIT 60`, runtime/caml/stack.h), and returns
through them: it counts on the top byte being ignored (TBI), as Linux
has it for its programs. MyNOS's TCR_EL1 had TBI0 off: the return
faulted, the kernel's handler found nothing to do, the instruction
faulted again.

**Fix.** TCR_EL1.TBI0 (bit 37) set at boot and on every processor
(start.S). Under QEMU (TCG) native code then runs 17 to 50 times as fast
as bytecode on small loops (integers, floats, allocation), the Spectrum's
Z80 391 frames a second against 20, the MSX1 245 against 9.

**Lesson.** A port's ABI is more than its system calls: the address
space's conventions (here, the top byte) are part of what a compiler
may rely on.
