/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * virtio devices for drivers (doc/decisions/virtio.md): QEMU's (and a
 * cloud's) disks, network cards, input devices and screens, all through
 * the same transport. This is virtio 1.x over PCI ("modern"): the
 * device's registers are memory, found through its PCI capabilities, and
 * it shares with the driver queues in RAM (split virtqueues) that both
 * read and write. Drivers only: port I/O (PCI's configuration), device
 * memory and DMA memory need the io privilege.
 */

#ifndef __MYNOS_VIRTIO_H__
#define __MYNOS_VIRTIO_H__

/* device types (virtio 1.2, 5) */
#define VIRTIO_NET    1
#define VIRTIO_BLOCK  2
#define VIRTIO_GPU   16
#define VIRTIO_INPUT 18

/* features every driver here takes (bit 32: virtio 1.x) */
#define VIRTIO_F_VERSION_1 (1ULL << 32)

/* ---- PCI's configuration space (port I/O on the PC) ---- */

unsigned int pci_read32(int bus, int dev, int fn, int reg);
void pci_write32(int bus, int dev, int fn, int reg, unsigned int v);

/* ---- a device ---- */

typedef struct {
  int bus, dev, fn;
  int type;                          /* VIRTIO_NET... */
  int irq;                           /* its interrupt line (PCI INTx) */
  volatile unsigned char * common;   /* the common configuration */
  volatile unsigned char * isr;      /* the interrupt status */
  volatile unsigned char * device;   /* the device's own configuration */
  volatile unsigned char * notify;   /* where queues are notified */
  unsigned int notify_mult;
  unsigned long long features;       /* those agreed */
} virtio_dev_t;

/* the [index]th device of [type] (from 0): 0, or -1 if there is none, or
   if its registers cannot be reached (a 64-bit BAR above 4 GB) */
int virtio_find(int type, int index, virtio_dev_t * d);

/* reset the device and agree on features: those of [wanted] it offers,
   with VIRTIO_F_VERSION_1. 0, or -1 if the device refuses */
int virtio_start(virtio_dev_t * d, unsigned long long wanted);

/* the device may now work (after its queues are set) */
void virtio_ready(virtio_dev_t * d);

/* why the device interrupted (bit 0: a queue, bit 1: its configuration);
   reading it acknowledges the interrupt */
unsigned int virtio_isr(virtio_dev_t * d);

/* the device's configuration, by offset */
unsigned int virtio_config8(virtio_dev_t * d, int off);
unsigned int virtio_config16(virtio_dev_t * d, int off);
unsigned int virtio_config32(virtio_dev_t * d, int off);
unsigned long long virtio_config64(virtio_dev_t * d, int off);

/* ---- a queue ---- */

#define VIRTQ_DESC_F_NEXT  1
#define VIRTQ_DESC_F_WRITE 2         /* the device writes this buffer */

struct virtq_desc { unsigned long long addr; unsigned int len;
                    unsigned short flags, next; };
struct virtq_avail { unsigned short flags, idx, ring[]; };
struct virtq_used_elem { unsigned int id, len; };
struct virtq_used { unsigned short flags, idx; struct virtq_used_elem ring[]; };

typedef struct {
  int index, size;
  volatile struct virtq_desc * desc;
  volatile struct virtq_avail * avail;
  volatile struct virtq_used * used;
  volatile unsigned short * notify;
  unsigned short free_head, num_free, last_used;
} virtq_t;

/* a buffer of a request: its physical address, its length, and whether
   the device writes it (else it reads it) */
typedef struct { unsigned long phys; unsigned int len; int write; } virtq_buf_t;

/* set queue [index] up with at most [max] entries (a power of 2): 0, or -1 */
int virtq_setup(virtio_dev_t * d, int index, int max, virtq_t * q);

/* offer a request of n buffers: its id (the first descriptor), or -1 if
   the queue is full. virtq_kick tells the device. */
int virtq_add(virtq_t * q, const virtq_buf_t * bufs, int n);
void virtq_kick(virtq_t * q);

/* a request the device has finished: its id, and in *len the bytes it
   wrote; -1 if none yet. Its descriptors are free again. */
int virtq_get(virtq_t * q, unsigned int * len);

/* ---- memory the device reads and writes ---- */

/* npages of RAM in one physical piece, zeroed: its address here, and in
   *phys the one to give the device (mynos_dmaAlloc) */
void * virtio_dma(int npages, unsigned long * phys);

#endif
