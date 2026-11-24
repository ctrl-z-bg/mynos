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
 * vblkd: the driver of the first virtio disk (doc/decisions/virtio.md),
 * served as the block service "vblk0", protocol block/1, the same as
 * ata's (mynos-lib/ocaml/block.mli): fatfs uses either.
 *
 * One request at a time: a header (the kind, the sector), the data, a
 * status byte, three buffers of one queue in DMA memory. The device's
 * interrupt (a PCI line, shared) wakes the driver; without one it
 * polls. Without a virtio disk it ends at once, with code 0, as ata
 * does without its disk.
 */

#include <string.h>
#include <mynos.h>
#include <mynos_wire.h>
#include <mynos_virtio.h>

#define SERVICE  "vblk0"
#define PROTOCOL "block/1"
#define SECTOR   512
#define MAXCOUNT 32                    /* sectors per request, as ata */

#define T_IN     0                     /* read */
#define T_OUT    1                     /* write */
#define T_FLUSH  4
#define F_FLUSH  (1ULL << 9)           /* the device has a cache to flush */

static virtio_dev_t dev;
static virtq_t q;
static int irq_sem = -1;
static unsigned long long capacity;    /* sectors */

/* the request's memory: a page for the header and the status, then the
   data (MAXCOUNT sectors) */
static struct { unsigned int type, reserved; unsigned long long sector; } * hdr;
static unsigned char * status, * data;
static unsigned long hdr_phys, data_phys;

/* one request to the device, waited for: 0, or -1 if it failed */
static int request(unsigned int type, unsigned long long sector, int count)
{
  virtq_buf_t b[3];
  int n = 0;
  hdr->type = type;
  hdr->reserved = 0;
  hdr->sector = sector;
  *status = 0xFF;
  b[n].phys = hdr_phys; b[n].len = 16; b[n].write = 0; n++;
  if (count > 0) {
    b[n].phys = data_phys; b[n].len = count * SECTOR; b[n].write = type == T_IN; n++;
  }
  b[n].phys = hdr_phys + 16; b[n].len = 1; b[n].write = 1; n++;
  if (virtq_add(&q, b, n) < 0) return -1;
  virtq_kick(&q);
  while (virtq_get(&q, NULL) < 0) {
    if (irq_sem >= 0) {
      mynos_P(irq_sem);
      virtio_isr(&dev);                /* acknowledged: the line drops */
      mynos_enableIrq(dev.irq);
    } else
      mynos_sleep(1000);
  }
  return *status == 0 ? 0 : -1;
}

static const wire_request_doc docs[] = {
  { 1, "info", "U", "I", "The number of sectors of the device." },
  { 1, "read", "(lba:I,count:I)", "S",
    "Read count sectors (1 to 32) from sector lba: their bytes." },
  { 0, "write", "(lba:I,bytes:S)", "U",
    "Write bytes (a whole number of sectors, up to 32) from sector lba." },
  { 0, "flush", "U", "U",
    "Write what the device's cache holds to its medium (the driver also does it "
    "by itself, half a second after the last write)." },
};

static void serve(wire_reader * r, wire_writer * w)
{
  long long kind = wire_get_int(r), lba = 0, count = 0;
  const char * bytes = NULL;
  unsigned int blen = 0;
  if (kind == 1) { lba = wire_get_int(r); count = wire_get_int(r); }
  else if (kind == 2) { lba = wire_get_int(r); bytes = wire_get_string(r, &blen); }
  if (r->error || !wire_at_end(r) || kind < 0 || kind > 3) {
    wire_reply_error(w, "invalid: " SERVICE " speaks " PROTOCOL);
    return;
  }
  if (kind == 0) {
    wire_reply_ok(w);
    wire_put_int(w, (long long)capacity);
    return;
  }
  if (kind == 3) {
    if ((dev.features & F_FLUSH) && request(T_FLUSH, 0, 0) < 0)
      wire_reply_error(w, "the device failed to flush");
    else
      wire_reply_ok(w);
    return;
  }
  if (kind == 2) {
    if (blen == 0 || blen % SECTOR) {
      wire_reply_error(w, "invalid: not a whole number of sectors");
      return;
    }
    count = blen / SECTOR;
  }
  if (count < 1 || count > MAXCOUNT || lba < 0 ||
      (unsigned long long)(lba + count) > capacity) {
    wire_reply_error(w, "invalid: sectors out of range");
    return;
  }
  if (kind == 2) memcpy(data, bytes, blen);
  if (request(kind == 1 ? T_IN : T_OUT, lba, count) < 0) {
    wire_reply_error(w, "the device failed");
    return;
  }
  wire_reply_ok(w);
  if (kind == 1) wire_put_string(w, data, count * SECTOR);
}

int main(void)
{
  int port;
  if (virtio_find(VIRTIO_BLOCK, 0, &dev) < 0) {
    mynos_log("vblkd: no virtio disk\n");
    return 0;
  }
  if (virtio_start(&dev, F_FLUSH) < 0 || virtq_setup(&dev, 0, 16, &q) < 0) {
    mynos_log("vblkd: the virtio disk refused to start\n");
    return 1;
  }
  hdr = virtio_dma(1, &hdr_phys);
  data = virtio_dma(MAXCOUNT * SECTOR / 4096, &data_phys);
  if (hdr == NULL || data == NULL) {
    mynos_log("vblkd: no DMA memory\n");
    return 1;
  }
  status = (unsigned char *)hdr + 16;
  capacity = virtio_config64(&dev, 0);
  irq_sem = mynos_driverRegister("vblk0", dev.irq | MYNOS_IRQ_PCI, NULL, NULL);
  if (irq_sem >= 0) mynos_enableIrq(dev.irq);
  virtio_ready(&dev);
  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("vblkd: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("vblkd: virtio disk, %u sectors, IRQ %d%s, as " SERVICE "\n",
            (unsigned int)capacity, dev.irq, irq_sem >= 0 ? "" : " (polled)");

  for (;;) {
    int channel = mynos_listenPort(port);
    mynos_msg_t * msg;
    wire_reader r;
    wire_writer w;
    const char * id;
    unsigned int idlen;
    if (channel < 0) continue;
    if (mynos_recv(channel, &msg, 0, 1000) < 0) {
      mynos_freeChannel(channel);
      continue;
    }
    wire_writer_init(&w);
    wire_reader_init(&r, msg->start, msg->size);
    id = wire_get_string(&r, &idlen);
    if (!r.error && idlen == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, idlen)
        && wire_at_end(&r))
      wire_reply_description(&w, PROTOCOL,
                             "A block device (a disk): sectors of 512 bytes, numbered from 0 (LBA).",
                             docs, sizeof docs / sizeof docs[0]);
    else if (!r.error && idlen == strlen(PROTOCOL) && !memcmp(id, PROTOCOL, idlen))
      serve(&r, &w);
    else
      wire_reply_error(&w, "invalid: " SERVICE " speaks " PROTOCOL);
    if (!w.error) mynos_send(channel, w.buf, w.len, 0);
    wire_writer_free(&w);
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
  }
  return 0;
}
