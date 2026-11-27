/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* virtio 1.x over PCI, and split virtqueues: see mynos_virtio.h and
   doc/decisions/virtio.md. The numbers are the specification's (virtio
   1.2: 4.1 for PCI, 2.7 for the queues). */

#include <stddef.h>
#include "../include/mynos.h"
#include "../include/mynos_virtio.h"

/* the device sees memory in the order the driver writes it: a fence */
#define mb() __sync_synchronize()

#ifdef __aarch64__
/* ---- PCI's configuration space on QEMU virt: memory (ECAM) ----
   bus 0's 1 MB at 0x4010000000 (virt's high ECAM), mapped at the first
   use (doc/decisions/aarch64.md, choice 8) */

#define ECAM_BASE 0x4010000000UL

static volatile unsigned int * ecam;

/* ---- a Raspberry Pi 4's PCIe (btq.8.1): its bridge's registers, which
   the kernel lets a driver map once the link is up (arch/aarch64/
   pcie4.c). Bus 0 is the root port, the bridge's own registers; bus 1
   (the VL805, the USB's xHCI: device 0 only, a link has one) through
   an index (0x9000) and a data window (0x8000): two accesses, which
   one driver at a time makes (the USB's) ---- */

#define PI4_PCIE 0xFD500000UL

static volatile unsigned int * pi4;
static int pi4_tried;

static volatile unsigned int * pi4_reg(int bus, int dev, int fn, int reg)
{
  if (!pi4_tried) { pi4_tried = 1; pi4 = mynos_mapPhysical(PI4_PCIE, 16); }
  if (!pi4 || dev != 0 || fn != 0 || bus > 1) return 0;
  if (bus == 0) return pi4 + ((reg & 0xFFC) >> 2);
  pi4[0x9000 / 4] = 1u << 20;
  return pi4 + ((0x8000 + (reg & 0xFFC)) >> 2);
}

static volatile unsigned int * pci_reg(int bus, int dev, int fn, int reg)
{
  static int ecam_tried;
  if (!ecam_tried) { ecam_tried = 1; ecam = mynos_mapPhysical(ECAM_BASE, 256); }
  if (!ecam) return pi4_reg(bus, dev, fn, reg);
  if (bus != 0) return 0;
  return ecam + (((dev << 15) | (fn << 12) | (reg & 0xFFC)) >> 2);
}

unsigned int pci_read32(int bus, int dev, int fn, int reg)
{
  volatile unsigned int * r = pci_reg(bus, dev, fn, reg);
  return r ? *r : 0xFFFFFFFF;
}

void pci_write32(int bus, int dev, int fn, int reg, unsigned int v)
{
  volatile unsigned int * r = pci_reg(bus, dev, fn, reg);
  if (r) *r = v;
}
#else
/* ---- PCI's configuration space: ports 0xCF8 (address), 0xCFC (data) ----
   Two accesses, the address then the data: the kernel does them (native
   call 103), so that another driver's address cannot come in between
   (at boot every driver looks for its devices, on four processors) */

#include "syscall.h"

static unsigned int pci_address(int bus, int dev, int fn, int reg)
{
  return 0x80000000u | (bus << 16) | (dev << 11) | (fn << 8) | (reg & 0xFC);
}

unsigned int pci_read32(int bus, int dev, int fn, int reg)
{
  return (unsigned int)__mynos_syscall(103, 0, pci_address(bus, dev, fn, reg), 0, 0, 0);
}

void pci_write32(int bus, int dev, int fn, int reg, unsigned int v)
{
  __mynos_syscall(103, 1, pci_address(bus, dev, fn, reg), v, 0, 0);
}

#endif

static unsigned int pci_read8(int bus, int dev, int fn, int reg)
{
  return (pci_read32(bus, dev, fn, reg) >> ((reg & 3) * 8)) & 0xFF;
}

/* ---- finding the device ---- */

/* its type, from its PCI device id: 0x1040 + type (virtio 1.x only), or
   a transitional id of 2009 (both, which QEMU gives by default) */
static int device_type(unsigned int id)
{
  if (id >= 0x1041 && id <= 0x107F) return id - 0x1040;
  switch (id) {
  case 0x1000: return VIRTIO_NET;
  case 0x1001: return VIRTIO_BLOCK;
  default: return -1;
  }
}

/* a BAR's region, mapped here: [offset, offset + length) of BAR [bar] */
static volatile unsigned char * map_bar(virtio_dev_t * d, int bar,
                                        unsigned int offset, unsigned int length)
{
  unsigned int lo = pci_read32(d->bus, d->dev, d->fn, 0x10 + 4 * bar), hi = 0;
  unsigned long base, start, end;
  unsigned char * p;
  if (lo & 1) return NULL;                       /* I/O space: legacy only */
  if (((lo >> 1) & 3) == 2)                      /* 64 bits */
    hi = pci_read32(d->bus, d->dev, d->fn, 0x14 + 4 * bar);
  if (hi != 0) return NULL;                      /* above 4 GB: not on i386 */
  base = (lo & ~0xFu) + offset;
  start = base & ~0xFFFul;
  end = (base + length + 0xFFF) & ~0xFFFul;
  p = mynos_mapPhysical(start, (end - start) >> 12);
  return p ? (volatile unsigned char *)(p + (base - start)) : NULL;
}

/* (On AArch64's virt the kernel gives the devices their memory windows,
   at boot: arch/aarch64/pci.c. A driver here took them for every device
   it looked at, under the others' feet) */

int virtio_find(int type, int index, virtio_dev_t * d)
{
  int bus, dev, found = 0;
  for (bus = 0; bus < 256; bus++)
    for (dev = 0; dev < 32; dev++) {
      unsigned int id = pci_read32(bus, dev, 0, 0), cap;
      if ((id & 0xFFFF) != 0x1AF4 || device_type(id >> 16) != type) continue;
      if (found++ != index) continue;
      d->bus = bus; d->dev = dev; d->fn = 0; d->type = type;
      d->common = d->isr = d->device = d->notify = NULL;
      d->irq = pci_read8(bus, dev, 0, 0x3C);
      /* memory space and bus mastering on */
      pci_write32(bus, dev, 0, 0x04, pci_read32(bus, dev, 0, 0x04) | 0x6);
      /* the vendor's capabilities (id 9): where each register block is */
      cap = pci_read8(bus, dev, 0, 0x34);
      while (cap) {
        if (pci_read8(bus, dev, 0, cap) == 0x09) {
          int kind = pci_read8(bus, dev, 0, cap + 3);
          int bar = pci_read8(bus, dev, 0, cap + 4);
          unsigned int off = pci_read32(bus, dev, 0, cap + 8);
          unsigned int len = pci_read32(bus, dev, 0, cap + 12);
          volatile unsigned char * p;
          if (kind >= 1 && kind <= 4 && (p = map_bar(d, bar, off, len)) != NULL) {
            if (kind == 1) d->common = p;
            else if (kind == 2) {
              d->notify = p;
              d->notify_mult = pci_read32(bus, dev, 0, cap + 16);
            } else if (kind == 3) d->isr = p;
            else d->device = p;
          }
        }
        cap = pci_read8(bus, dev, 0, cap + 1);
      }
      return d->common && d->notify && d->isr ? 0 : -1;
    }
  return -1;
}

/* ---- the common configuration (4.1.4.3) ---- */

#define C_DFSELECT  0x00
#define C_DF        0x04
#define C_GFSELECT  0x08
#define C_GF        0x0C
#define C_STATUS    0x14
#define C_QSELECT   0x16
#define C_QSIZE     0x18
#define C_QENABLE   0x1C
#define C_QNOTIFY   0x1E
#define C_QDESC     0x20
#define C_QDRIVER   0x28
#define C_QDEVICE   0x30

#define S_ACKNOWLEDGE 1
#define S_DRIVER      2
#define S_DRIVER_OK   4
#define S_FEATURES_OK 8

#define R8(b, o)  (*(volatile unsigned char *)((b) + (o)))
#define R16(b, o) (*(volatile unsigned short *)((b) + (o)))
#define R32(b, o) (*(volatile unsigned int *)((b) + (o)))

static void write64(volatile unsigned char * b, int o, unsigned long long v)
{
  R32(b, o) = (unsigned int)v;
  R32(b, o + 4) = (unsigned int)(v >> 32);
}

int virtio_start(virtio_dev_t * d, unsigned long long wanted)
{
  unsigned long long offered;
  volatile unsigned char * c = d->common;
  R8(c, C_STATUS) = 0;                           /* reset */
  while (R8(c, C_STATUS) != 0) ;
  R8(c, C_STATUS) = S_ACKNOWLEDGE;
  R8(c, C_STATUS) = S_ACKNOWLEDGE | S_DRIVER;
  R32(c, C_DFSELECT) = 0;
  offered = R32(c, C_DF);
  R32(c, C_DFSELECT) = 1;
  offered |= (unsigned long long)R32(c, C_DF) << 32;
  if (!(offered & VIRTIO_F_VERSION_1)) return -1;
  d->features = offered & (wanted | VIRTIO_F_VERSION_1);
  R32(c, C_GFSELECT) = 0;
  R32(c, C_GF) = (unsigned int)d->features;
  R32(c, C_GFSELECT) = 1;
  R32(c, C_GF) = (unsigned int)(d->features >> 32);
  R8(c, C_STATUS) = S_ACKNOWLEDGE | S_DRIVER | S_FEATURES_OK;
  if (!(R8(c, C_STATUS) & S_FEATURES_OK)) return -1;
  return 0;
}

void virtio_ready(virtio_dev_t * d)
{
  R8(d->common, C_STATUS) = S_ACKNOWLEDGE | S_DRIVER | S_FEATURES_OK | S_DRIVER_OK;
}

unsigned int virtio_isr(virtio_dev_t * d) { return R8(d->isr, 0); }

unsigned int virtio_config8(virtio_dev_t * d, int off) { return R8(d->device, off); }
unsigned int virtio_config16(virtio_dev_t * d, int off) { return R16(d->device, off); }
unsigned int virtio_config32(virtio_dev_t * d, int off) { return R32(d->device, off); }
unsigned long long virtio_config64(virtio_dev_t * d, int off)
{
  return R32(d->device, off) | ((unsigned long long)R32(d->device, off + 4) << 32);
}

/* ---- memory ---- */

void * virtio_dma(int npages, unsigned long * phys)
{
  return mynos_dmaAlloc(npages, phys);
}

/* ---- queues (2.7) ---- */

int virtq_setup(virtio_dev_t * d, int index, int max, virtq_t * q)
{
  volatile unsigned char * c = d->common;
  unsigned int size, desc_bytes, avail_bytes, used_off, total, i;
  unsigned long phys;
  unsigned char * mem;
  R16(c, C_QSELECT) = index;
  size = R16(c, C_QSIZE);
  if (size == 0) return -1;
  while (size > (unsigned)max) size /= 2;
  R16(c, C_QSIZE) = size;
  /* descriptors, then the driver's ring, then (aligned to 4) the
     device's ring: one piece of memory */
  desc_bytes = 16 * size;
  avail_bytes = 6 + 2 * size;
  used_off = (desc_bytes + avail_bytes + 3) & ~3u;
  total = used_off + 6 + 8 * size;
  mem = virtio_dma((total + 4095) / 4096, &phys);
  if (mem == NULL) return -1;
  q->index = index;
  q->size = size;
  q->desc = (volatile struct virtq_desc *)mem;
  q->avail = (volatile struct virtq_avail *)(mem + desc_bytes);
  q->used = (volatile struct virtq_used *)(mem + used_off);
  for (i = 0; i < size; i++) q->desc[i].next = i + 1;
  q->free_head = 0;
  q->num_free = size;
  q->last_used = 0;
  write64(c, C_QDESC, phys);
  write64(c, C_QDRIVER, phys + desc_bytes);
  write64(c, C_QDEVICE, phys + used_off);
  q->notify = (volatile unsigned short *)
    (d->notify + R16(c, C_QNOTIFY) * d->notify_mult);
  R16(c, C_QENABLE) = 1;
  return 0;
}

int virtq_add(virtq_t * q, const virtq_buf_t * bufs, int n)
{
  int i, head, d;
  if (n <= 0 || n > q->num_free) return -1;
  head = d = q->free_head;
  for (i = 0; i < n; i++) {
    q->desc[d].addr = bufs[i].phys;
    q->desc[d].len = bufs[i].len;
    q->desc[d].flags = (bufs[i].write ? VIRTQ_DESC_F_WRITE : 0) |
                       (i < n - 1 ? VIRTQ_DESC_F_NEXT : 0);
    if (i < n - 1) d = q->desc[d].next;
  }
  q->free_head = q->desc[d].next;
  q->num_free -= n;
  q->avail->ring[q->avail->idx % q->size] = head;
  mb();                                  /* the entry, then the index */
  q->avail->idx++;
  return head;
}

void virtq_kick(virtq_t * q)
{
  mb();
  *q->notify = q->index;
}

int virtq_get(virtq_t * q, unsigned int * len)
{
  int id, d, n = 1;
  if (q->last_used == q->used->idx) return -1;
  mb();                                  /* the index, then the entry */
  id = q->used->ring[q->last_used % q->size].id;
  if (len) *len = q->used->ring[q->last_used % q->size].len;
  q->last_used++;
  /* its descriptors back on the free list */
  for (d = id; q->desc[d].flags & VIRTQ_DESC_F_NEXT; d = q->desc[d].next) n++;
  q->desc[d].next = q->free_head;
  q->free_head = id;
  q->num_free += n;
  return id;
}
