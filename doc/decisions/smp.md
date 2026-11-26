# Decision: several processors (SMP)

- **Issues:** mynos-btq.5, in the version 2 line (mynos-btq)
- **Date:** 2026-11-25
- **Status:** accepted by the owner (2026-11-25); built on branch `smp`
  (four processors by default on x86-64).

## Why

OCaml 5 is multicore: its domains would run in parallel without a change
to the runtime, and so would MyNOS's processes: `httpd`'s eight domains,
`llmd`, the agent in its domain, the windows of the graphical session,
any program's `Domain.spawn`. musl and its threads are ready. The kernel
is not: it is written for one processor, whose critical section is
"interrupts off", with the current thread and process global.

## Choices (the owner's, 2026-11-25)

- **x86-64 only.** The i386 stays on one processor: doing it twice would
  write the same parts twice, and the 64-bit kernel has the pieces SMP
  needs (no hardware task switch, the TLS in FS's base).
- **A big kernel lock, first.** One spinlock taken at every entry into
  the kernel (system calls, interrupts, exceptions) and left at the exit:
  the kernel stays "one at a time" as it is today, so concurrency bugs
  stay few, but programs run in parallel. Finer locks would be a second
  stage, decided by measurements.
- **The other processors**: found in the ACPI MADT, started with
  INIT-SIPI-SIPI from a trampoline below 1 MB; each has its LAPIC, whose
  timer gives it its time slices. They are started before the first
  process (until 2026-11-25 after, in processor 0's idle thread: the
  first programs saw one processor); programs learn how many there are
  from `sched_getaffinity` (`nproc`, `sysconf`, OCaml's
  `Domain.recommended_domain_count`). AArch64 has the same design since
  2026-11-26 (doc/decisions/aarch64.md, choice 7).
- **Devices' interrupts stay on the 8259, delivered to processor 0
  only.** The IOAPIC would spread them, which no device needs today.
  Processors talk with inter-processor interrupts (IPIs): to wake a
  thread, and for TLB shootdowns.
- **Per processor**: the current thread and process, a TSS, a kernel
  stack, an idle thread, the FPU's owner, FS's base. One GDT, with one
  TSS slot per processor.
- **One ready queue** under the big lock; a thread made ready while a
  processor idles wakes it with an IPI.
- **TLB shootdown**: when a process's page tables change while it runs
  on other processors too (`munmap`, copy-on-write, `fork`, the pager),
  they are told with an IPI.
- **Four processors by default** on x86-64 (`run-demo.sh`, the release);
  the i386 stays at one.

## Trade-offs and risks

- **Concurrency bugs are intermittent**, as the direction flag's was
  (once in four runs). The big lock keeps the kernel serial; the risk is
  in what crosses it: the scheduler's choice, wake-ups, page tables seen
  by two processors.
- **The big lock limits** what runs in parallel: two programs that call
  the kernel often (IPC-heavy services) still take turns. The measured
  gain may be small for IPC-bound work; computation in domains gains
  most.
- **TLB shootdowns** cost an IPI round trip on every change to a
  multi-threaded process's mappings; missing one corrupts memory
  silently (a stale translation), the hardest bug of all to find.
- **Interrupts on processor 0 only**: drivers' latency depends on that
  processor; a busy processor 0 delays them.
- **Tests**: the suite runs at one and at four processors on x86-64,
  under TCG multi-threaded and KVM; a stress test (many threads, IPC
  across processors, `fork` and `munmap` together) is added.

## What was built (2026-11-25)

- `arch/x86_64/smp.c`: the MADT read, the trampoline (`ap.asm`) copied to
  0x7000, INIT and two STARTUPs; each processor's `ap_main` (GS, its TSS,
  the IDT, syscall's MSRs, the FPU, its local APIC with the 8259's lines
  masked, its idle thread, its LAPIC timer at 10 ms, calibrated against
  the PIT).
- The big lock: `kernel_enter` at every entry (entry.asm, the IRQ
  wrappers, the PIT's), `kernel_exit` in `trap_return`; a depth per
  processor, saved per thread at a switch (`kdepth`: a new thread's is 1,
  which its first `trap_return` ends). A processor waiting for the lock
  flushes its TLB when asked.
- The scheduler skips threads running on another processor and the idle
  threads; a thread made ready wakes an idle processor (IPI 0xF0).
- TLB shootdown in `arch_flush_page` (the kernel's half: every
  processor; a process's: those running its address space), and after
  `fork` marks the parent's pages copy-on-write.
- `tests/smp` (C): counters (atomic, under a semaphore), faults on the
  same fresh pages from four threads, `mmap`/`munmap` from three, `fork`
  while a thread writes. In the suite (lane a), on both architectures.
- `run-qemu.sh`: `SMP=N`, default 4 on x86-64; the i386 stays at 1.

Bugs found on the way (JOURNAL, 2026-11-25): a fault resolved by another
processor taken as invalid; fresh pages zeroed after being mapped; a
thread of a process killed meanwhile going on into its call; `reapZombies`
recognising a busy processor by a slot that may be reused; a test that
assumed one processor (`abi`); the user-space malloc lock's `bts` without
`lock`.

## Measurements (2026-11-25, KVM, host CPU)

`tests/cpu/par.ml`: N domains, each the same work.

Computation (primes below 2,000,000 by trial division), seconds:

| domains | 1 CPU | 2 CPUs | 4 CPUs |
|--------:|------:|-------:|-------:|
| 1       | 2.19  | 2.16   | 2.16   |
| 2       | 4.37  | 2.17   | 2.17   |
| 4       | 8.64  | 4.58   | 2.40   |
| 8       | 17.35 | 8.88   | 4.93   |

The speed-up is the number of processors (3.6x with four domains on
four): computation does not touch the kernel, the big lock does not
matter.

Allocation (lists built and dropped: minor collections, which stop every
domain together), seconds:

| domains | 1 CPU | 4 CPUs |
|--------:|------:|-------:|
| 1       | 6.91  | 0.51   |
| 2       | 18.29 | 0.55   |
| 4       | 58.89 | 3.87   |

Not a parallel speed-up but a uniprocessor problem shown up: with one
domain the four processors are 13 times faster. The runtime's
stop-the-world barrier waits, spinning, for domains that are not running
(the main one, blocked in `join`): on one processor each wait lasts until
the next preemption. The same with more domains than processors (four
domains and the main one on four). mynos-c6a.

What it was (measured with the timer sampling the user program counter):
at each minor collection the allocating domain leads a stop-the-world
section, wakes the main domain's backup thread through a futex, finishes
its own part first, goes back to allocating, and at the next collection
finds the section not yet closed: it retries in a loop
(`caml_empty_minor_heaps_once`), without a system call, while the backup
thread, woken and ready, waits for the end of the time slice. Linux lets
a woken thread preempt its waker; MyNOS now runs a thread woken by
`FUTEX_WAKE` at once, before the waker, unless another processor idles
(`sched_handoff`). Seconds, KVM, after:

| domains | 1 CPU before | 1 CPU after | 4 CPUs after |
|--------:|-------------:|------------:|-------------:|
| 1       | 6.93         | 1.05        | 0.48         |
| 2       | 18.20        | 13.79       | 0.53         |
| 4       | 59.36        | 42.55       | 3.45         |

With more domains than processors the leader also waits for domains
that are ready but not woken by it (running OCaml, they answer the
interrupt at their next poll): that wait lasts the time slice. With a
4 ms slice instead of 10 ms, on one processor: 0.68, 6.44 and 19.06 s,
and the computation of the first table unchanged (3.50 s for one
domain, 7.01 for two). Not adopted: the time slice is every program's,
the owner's decision (asked on 2026-11-25).

The suite (TCG, multi-threaded) takes the same 230 s at four processors:
its time is set by fixed waits, not by the processor.
