# Decision: several processors (SMP)

- **Issues:** mynos-btq.5, in the version 2 line (mynos-btq)
- **Date:** 2026-11-25
- **Status:** accepted by the owner (2026-11-25), in progress on branch
  `smp`.

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
  timer gives it its time slices.
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

## Measurements

To be made: a parallel workload in domains, and the suite, at 1, 2 and 4
processors, with KVM.
