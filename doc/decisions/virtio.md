# Decision: virtio, the devices of virtual machines

- **Issues:** mynos-btq.2, in the version 2 line (mynos-btq)
- **Date:** 2026-11-24
- **Status:** accepted by the owner (C, virtio 1.x); the disk done, the
  network next, then input and the screen.

## Why

MyNOS's drivers are for the PC of the 1990s that QEMU emulates: the
i8042 keyboard, VGA and the Bochs display, an IDE disk, an NE2000 on the
ISA bus, a Sound Blaster. None of them exists on QEMU's `virt` machines
for AArch64 and RISC-V, nor in a cloud's virtual machines. virtio does,
on all of them, with one transport and one way of exchanging data: the
drivers written once on i386 are the drivers of every port.

## Choices (the owner's, 2026-11-24)

- **In C.** The transport (PCI, queues in DMA memory, memory barriers)
  is C in any case, because `netd` (C, lwIP) needs it; the disk's driver
  is C too, rather than OCaml with new runtime primitives.
- **virtio 1.x over PCI ("modern")**, not the legacy interface of 2009:
  its registers are memory, found through the PCI capabilities, which is
  what x86-64, AArch64 and RISC-V will have. The legacy one uses I/O
  ports, which ARM does not have.

## What there is

- **The kernel**: `dmaAlloc` (call 39), 1 to 256 pages of RAM in one
  physical piece, zeroed, mapped into a driver with their physical
  address; the driver's mapping is their only reference, so they are
  freed when it ends. PCI interrupt lines, registered with
  `MYNOS_IRQ_PCI`: level-triggered, shared by up to four drivers, masked
  at each interrupt until a driver unmasks them (appendix A.7). ISA
  lines keep their old rules (one driver, never masked by the kernel).
- **`libmynos`'s transport** (`mynos-lib/src/virtio.c`,
  `mynos_virtio.h`): the PCI configuration space (ports `0xCF8`/`0xCFC`
  on the PC), finding a device by type, mapping its register blocks,
  the start (reset, features, `FEATURES_OK`, `DRIVER_OK`), split
  virtqueues (add, kick, get). A 64-bit BAR above 4 GB cannot be reached
  from the i386, and the device is then not found.
- **`vblkd`** (`services/virtio/vblkd.c`): the first virtio disk as
  `vblk0`, protocol block/1, the same as `ata0`. `fatfs` takes `ata0`,
  else `vblk0`; `init` flushes both before the power goes.

## Next

- **virtio-net** in `netd`, beside the NE2000: an lwIP interface over two
  queues (receive, transmit).
- **virtio-input** (keyboard and mouse) and **the screen** (virtio-gpu,
  or QEMU's `ramfb`): what the graphical session needs on `virt`.
- On AArch64 and RISC-V, PCI's configuration space is memory (ECAM)
  instead of ports: `pci_read32` and `pci_write32` are the only part of
  the transport to change.
