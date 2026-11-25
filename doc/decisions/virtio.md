# Decision: virtio, the devices of virtual machines

- **Issues:** mynos-btq.2, in the version 2 line (mynos-btq)
- **Date:** 2026-11-24
- **Status:** accepted by the owner (C, virtio 1.x); done: the disk,
  the network, the keyboard, the tablet or mouse, and the screen.

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

- **The kernel**: `dmaAlloc` (call 39), 1 to 4096 pages (16 MB) of RAM in one
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

- **virtio-net** in `netd` (`services/net/vnet.c`), with the NE2000's
  calls: queue 0 receives (32 buffers of 2 KB always offered), queue 1
  transmits (16 buffers, reused as the card gives them back); a header
  of 12 bytes, all zero, before each frame (no offloads). `netd` takes a
  virtio card if it finds one, else the NE2000.
- **`VIRTIO=1`** for `tools/run-qemu.sh` and `tools/run-demo.sh`: `DISK`
  and `NET` become virtio devices.

- **virtio-input**: a keyboard in `consoled` (Linux's key codes turned
  into the PC's scan codes, so that layouts and line editing are the
  same), a tablet or a mouse in `displayd` (which device is which: the
  event types its configuration lists). Without the PC's keyboard
  controller (`-machine pc,i8042=off`, or `virt`) both still start.
- **virtio-gpu** in `displayd`, when there is no Bochs VGA: a 2D
  resource whose backing is the frame buffer, in DMA memory (`dmaAlloc`
  gives up to 16 MB in one piece), and two commands for each rectangle
  that changes. The text console is VGA's, so a machine with only a
  virtio GPU shows the graphical session and nothing before it; the
  serial port has the boot.

## Next

- On AArch64 and RISC-V, PCI's configuration space is memory (ECAM)
  instead of ports: `pci_read32` and `pci_write32` are the only part of
  the transport to change.
