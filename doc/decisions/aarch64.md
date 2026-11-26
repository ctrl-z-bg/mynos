# Decision: MyNOS on AArch64 (QEMU virt)

- **Issues:** mynos-btq.6, in the version 2 line (mynos-btq); the step
  before the Raspberry Pis (btq.7, btq.8)
- **Date:** 2026-11-25
- **Status:** accepted (the plan, `tmp/mynos-64bit-multicore-arm.md`,
  approved by the owner on 2026-11-25); in progress on branch `aarch64`.

## What changes, and what does not

As for x86-64 (`doc/decisions/x86-64.md`): above the kernel almost
nothing. OCaml's bytecode is the same, the C services are rebuilt by an
AArch64 toolchain. The kernel's architecture layer (`arch/aarch64`),
`libmynos`'s calls and the start code are new. What has no AArch64
counterpart goes: I/O ports (the PC's drivers: ATA, PS/2, NE2000, Sound
Blaster, the VGA and the Bochs display), the 8259, the PIT. On QEMU's
`virt` machine the devices are virtio (btq.2 wrote the drivers), behind
PCI Express.

## Choices

**1. The toolchain.** A container `dev-aarch64` (amd64, so it runs at the
host's speed): Debian's cross gcc 14 for aarch64, musl 1.2.5 built for
AArch64 (`/opt/musl-aarch64`, its `musl-gcc`), the OCaml 5.5.2 compiler
for the host (bytecode does not depend on the processor) and the
bytecode runtime cross-built for AArch64 with musl. QEMU's AArch64
system emulator is in the image too: the host has none.

**2. The machine.** QEMU `virt`, a Cortex-A72 (the Raspberry Pi 4's and
the Pi 400's core: ARMv8.0, no hardware dirty bits, no permission
indirection), GICv2, the generic timer, one PL011 UART. QEMU's `-kernel`
loads the kernel's ELF image at its physical addresses and starts it at
EL1 with the MMU off; the device tree is at the start of RAM; the
modules come as one archive through `-initrd` (no multiboot): the start
code reads the device tree (memory, the initrd, the command line) and
fills the same `multiboot_info_t` that `mynos_main` reads on the PC.

**3. Physical memory starts at 0, for the kernel.** On `virt` RAM begins
at 1 GB; on a Raspberry Pi at 0. The generic kernel, from the i386,
reads its boot data at "physical == linear" addresses in its low
gigabyte, keeps its memory bitmap at 0x32000 and its image at 2 MB.
Rather than change that, the AArch64 layer numbers physical pages from
the start of RAM: the kernel's "physical" address is the real one minus
the RAM's base. A page table entry of RAM carries the base back in an
address bit (bit 30: RAM's base is 1 GB, and RAM is at most 1 GB on
`virt`, so the OR is exact and doing it twice changes nothing);
`PTE_FRAME` takes it away. On the Pis the base is 0 and the bit is not
used. Devices' entries (marked as such) carry their real address.

  Trade-off: at most 1 GB of RAM on `virt` with this trick (enough for
  the tests; the Pi 400 has 4 GB at address 0 and needs no trick).

**4. The address space**, as on x86-64: the kernel's gigabyte at linear
0 (its image at 2 MB), shared by every process (TTBR0's first level-1
entry points at the same table); the processes from 1 GB, the program at
1 GB as everywhere; all of RAM mapped once in the higher half through
TTBR1 (the direct map, at 0xFFFF800000000000); the devices' registers
mapped in TTBR1 too, as device memory. 4 KB pages, 48-bit addresses,
four levels: the same shape as x86-64's, so `paging.h`'s walk is the
same with other bits.

**5. Entries' bits.** ARM's entry says "read-only" where x86's says
"writable", and a page's entry needs bits x86 has not (the access flag,
shareability, the memory type). The generic code (`mem/`, the pager,
`mmap`) builds and changes entries with x86's bit names: those writes go
through `pte_set`, which on AArch64 sets the hardware bits from MyNOS's
(software "writable" bit, valid, access flag, the RAM's base bit); on
x86 it is a plain store. MyNOS's own bits (copy-on-write, shared, "to
allocate on use", pager) are in the bits the hardware leaves to
software (55-58).

**6. Ways into the kernel.** An exception vector table (`VBAR_EL1`):
from EL0 and EL1, synchronous (calls, faults) and IRQ; the same `struct
frame` on the thread's kernel stack, the same `kernel_enter`,
`trap_return`, big lock as x86-64. Linux's calls are `svc #0` with the
number in x8 (AArch64's "generic" numbers: `openat`, not `open`; `clone`,
not `fork`); MyNOS's own calls `svc #0x90` (the immediate, read from the
exception's syndrome). The processor's `struct cpu` is in `TPIDR_EL1`,
the thread's TLS in `TPIDR_EL0` (saved per thread, as FS's base).

**7. Interrupts and time.** GICv2; the generic timer's virtual timer at
1000 Hz in place of the PIT (`pit_handler` unchanged); the kernel's log
on the PL011 (the PC's COM2: the suite reads it). One processor first;
SMP (PSCI's `CPU_ON`, SGIs as IPIs) after the system runs.

  SMP (2026-11-26), as x86-64's (doc/decisions/smp.md): four processors
  by default (`SMP=N`), started by PSCI's `CPU_ON` before the first
  process (`_start_secondary` in start.S, `ap_main` in smp.c). Each has
  its GIC interface (the distributor's registers of interrupts 0-31 are
  banked), its virtual timer (a slice every 10 ms; processor 0's keeps
  the time at 1000 Hz), its idle thread. Software interrupt 0 is the
  IPI (a thread ready, a process ended). No TLB shootdown: `TLBI ...IS`
  reaches every processor. Device interrupts stay on processor 0. A
  processor started switches to the kernel's tables before it touches
  its stack: the stack is a page of those tables, elsewhere in the
  boot's.

**8. Devices** (btq.2's drivers, in user space): virtio over PCI
Express. Without firmware nobody assigns the PCI devices' memory
windows: the PCI code does, from the window the device tree gives. The
configuration space is memory (ECAM), not the ports 0xCF8/0xCFC.
Console and log on the UART; disk, network, keyboard and mouse, display
(virtio-gpu or ramfb) as on x86 with virtio.

  The UART plays the PC's COM2, the log's port and the serial console's
  (doc/decisions/console.md): the kernel answers COM2's registers with
  the PL011's (`arch/aarch64/io.c`: the data, the line status, the
  scratch register, the "byte received" interrupt). A driver's
  `inportb` and `outportb`, which on ARM cannot reach ports, are a
  native call (102) that the kernel answers from the same table, the
  rest reading 0xFF as an empty bus: consoled reads a terminal's keys
  from it unchanged, the PC's drivers (ata, keyboardd, seriald) find
  nothing and end. Without the io privilege the call ends the process,
  as `in` does on the PC (signal 11). The
  PL011's interrupt is the GIC's 33, line 1 (free: no PS/2 keyboard),
  level-triggered: consoled registers it as a PCI line's, masked at each
  interrupt until it has read the bytes.

**9. Running.** `ARCH=aarch64` for `tools/run-qemu.sh`,
`tools/run-demo.sh`: the modules made into one archive
(`tools/mkmodules.py`), `-M virt -cpu cortex-a72`, virtio devices only,
RAM from 128 MB (the archive at 64 MB) to 1 GB (choice 3); of a caller's
two `-serial` the second (COM2's) is the UART; a virtio GPU (displayd's)
and a tablet (`POINTER=mouse`: a relative mouse, as the PC's PS/2 one,
for QEMU's monitor's `mouse_move`). No text screen: `run-demo.sh` makes
the terminal the console, QEMU's window shows the graphical session. QEMU's AArch64 emulator
is the host's, or the `dev-aarch64` container's (the tree, `/tmp` and the
disk's folder mounted at their own paths, the host's network for
`HTTP`'s forwarding).

**10. The test suite** runs on AArch64 (`tools/run-tests-all.sh
aarch64`, or `ARCH=aarch64 tools/run-tests.sh` in `build/aarch64/tree`),
the same boots as on the PC: `run-qemu.sh` drops a caller's PC options
(`-machine`, `-vga`), the checks of what `virt` has not (the PS/2
keyboard, COM1, IDE, the Sound Blaster, VGA's text screen) are replaced
by what it has (`vblkd` where the PC has `ata`) or left out, and some
waits are doubled (emulated). The PC's ways to turn the machine off and
restart it, which `init` uses (ACPI's sleep state 5 at 0x604, the reset
control register 0xCF9), are PSCI's `SYSTEM_OFF` and `SYSTEM_RESET` in the
kernel's port table; its CMOS clock is a PC's (BCD).

## Risks

- **The amount**: the plan's estimate is 15-25 days for `virt` and the
  suite. Each step leaves something that runs: the banner, the timer,
  a C program in EL0, `ocamlrun`, the shell on the UART, the drivers,
  the suite.
- **Memory ordering**: ARM reorders memory accesses where x86 does not.
  The kernel's locks and the user-space ones (musl's are right; MyNOS's
  own, `safe_alloc.c`'s, and the IPC rings) need barriers.
- **Caches and DMA**: on QEMU coherent; on a real Pi, buffers shared
  with devices need cache maintenance (btq.7/8).
