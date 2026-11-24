# Decision: the architecture in its own directory

- **Issues:** mynos-btq.1 (arch-split), in the version 2 line (mynos-btq)
- **Date:** 2026-11-24
- **Status:** in progress, on branch `arch-split` from `next`.

## Why

MyNOS was written for the i386, and the i386 was everywhere in the
kernel: the boot, the processor's tables, the task switch and the
system call gates, but also a `cli` in a panic, a `rdtsc` in the random
pool, a `bts` in the semaphores, an `invlpg` in the memory code. Every
port of version 2 (x86-64, then AArch64 or RISC-V, `tmp` plan of
2026-11-24) must replace exactly that code and nothing else. The first
step makes it visible: the architecture's code in one directory, behind
a small interface, with no change in behaviour.

## The layout

```
mynos-core/kernel/
  arch/i386/        the i386 and the PC: start.asm, GDT, IDT, TSS, the
                    software task switch, port I/O, PIC, PIT, the delay
                    calibration, the ways into the kernel (entry.c),
                    kmemcpy/kmemset (string.c), and arch.h
  mem/ ipc/ ...     generic: they include "arch.h" (through global.h)
```

`ARCH` (in `mynos-core/CommonHeader`, `i386` by default) chooses the
directory; every part of the kernel sees the kernel's headers
(`"mem/mem.h"`) and the architecture's (`"gdt.h"`, `"arch.h"`) by name.
The kernel links `arch/$(ARCH)/start.o` first: the multiboot header must
be in its first 8 KB.

## arch.h: what generic code asks of the processor

| Function | i386 |
|---|---|
| `arch_irq_disable`, `arch_irq_enable` | `cli`, `sti` |
| `arch_irq_save`, `arch_irq_restore` | `pushf; cli`, `popf` |
| `arch_wait_interrupt`, `arch_halt_forever` | `hlt`; `cli` and `hlt` for ever |
| `arch_cycles` | `rdtsc` |
| `arch_cpuid`, `arch_rdrand`, `arch_rdseed` | `cpuid`, `rdrand`, `rdseed` |
| `arch_test_and_set`, `arch_clear` | `bts`, `lock btr` (the semaphores' locks) |
| `arch_flush_page` | `invlpg` |
| `arch_write_protect_kernel` | CR0.WP |
| `arch_fpu_reset` | `finit` |

They are `static inline`: what each one costs is the instruction.

## What stays generic, and is not yet

Moving files and instructions is the easy half. Three things in generic
code still have the i386's shape, and are the work of the x86-64 step
(mynos-btq.3), where a second architecture shows what the interface
must be:

- **The thread is the TSS.** `tss_t` is both the kernel's thread and
  the processor's task state segment (2002's design: the task switch
  was the processor's until 2003). Its registers are i386 registers.
- **The page tables have two levels.** `mem/` walks a page directory
  and its page tables, with the last entry mapping the tables themselves
  (`__GET_PAGE_TABLE_ENTRY`); `fork` copies them the same way.
- **The Linux ABI is i386's.** The handlers in `linux_syscalls.c` take
  i386's arguments; the numbers are in `arch/i386/entry.c`, where the
  entry dispatches them.
