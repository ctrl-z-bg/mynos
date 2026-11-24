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
 * The virtio network card (virtio 1.2, 5.1): queue 0 receives, queue 1
 * transmits. Every frame is preceded by a header of 12 bytes (virtio 1.x
 * always has num_buffers), all zero when sending: no checksum offload,
 * no segmentation. RXBUFS receive buffers of a page each are always
 * offered to the card; TXBUFS transmit buffers, reused as the card
 * gives them back. Called from netd's main loop only (lwIP's thread),
 * except vnet_ack (the interrupt thread).
 */

#include <string.h>
#include <mynos.h>
#include <mynos_virtio.h>
#include "vnet.h"
#include "ne2k.h"

#define F_MAC   (1ULL << 5)            /* the MAC address is in its config */
#define HDR     12
#define RXBUFS  32
#define TXBUFS  16
#define BUFSIZE 2048                   /* a header and a frame */

static virtio_dev_t dev;
static virtq_t rxq, txq;
static unsigned char * rx, * tx;       /* RXBUFS, TXBUFS buffers */
static unsigned long rx_phys, tx_phys;
static int rx_of[256];                 /* a queue entry's buffer */
static int tx_busy[TXBUFS];
static int tx_of[256];

static void offer_rx(int b)
{
  virtq_buf_t v = { rx_phys + b * BUFSIZE, BUFSIZE, 1 };
  int id = virtq_add(&rxq, &v, 1);
  if (id >= 0) rx_of[id] = b;
}

int vnet_init(unsigned char mac[6], int * irq)
{
  int i;
  if (virtio_find(VIRTIO_NET, 0, &dev) < 0) return -1;
  if (virtio_start(&dev, F_MAC) < 0 ||
      virtq_setup(&dev, 0, RXBUFS, &rxq) < 0 ||
      virtq_setup(&dev, 1, TXBUFS, &txq) < 0)
    return -1;
  rx = virtio_dma(RXBUFS * BUFSIZE / 4096, &rx_phys);
  tx = virtio_dma(TXBUFS * BUFSIZE / 4096, &tx_phys);
  if (rx == NULL || tx == NULL) return -1;
  for (i = 0; i < 6; i++)
    mac[i] = (dev.features & F_MAC) ? virtio_config8(&dev, i)
                                    : (i == 0 ? 0x52 : 0x54 + i);
  for (i = 0; i < rxq.size && i < RXBUFS; i++) offer_rx(i);
  virtio_ready(&dev);
  virtq_kick(&rxq);
  *irq = dev.irq;
  return 0;
}

/* the transmit buffers the card is done with */
static void reclaim_tx(void)
{
  int id;
  while ((id = virtq_get(&txq, NULL)) >= 0) tx_busy[tx_of[id]] = 0;
}

int vnet_send(const void * frame, unsigned int len)
{
  int b, id, tries;
  virtq_buf_t v;
  if (len > NE2K_MAXFRAME) return -1;
  for (tries = 0; tries < 1000; tries++) {
    reclaim_tx();
    for (b = 0; b < TXBUFS && tx_busy[b]; b++) ;
    if (b < TXBUFS) break;
    mynos_sleep(1000);
  }
  if (b == TXBUFS) return -1;
  memset(tx + b * BUFSIZE, 0, HDR);
  memcpy(tx + b * BUFSIZE + HDR, frame, len);
  v.phys = tx_phys + b * BUFSIZE;
  v.len = HDR + len;
  v.write = 0;
  if ((id = virtq_add(&txq, &v, 1)) < 0) return -1;
  tx_busy[b] = 1;
  tx_of[id] = b;
  virtq_kick(&txq);
  return 0;
}

int vnet_recv(void * buf)
{
  unsigned int len;
  int id = virtq_get(&rxq, &len), b, n;
  if (id < 0) return 0;
  b = rx_of[id];
  n = len > HDR ? (int)(len - HDR) : 0;
  if (n > NE2K_BUFSIZE) n = NE2K_BUFSIZE;
  memcpy(buf, rx + b * BUFSIZE + HDR, n);
  offer_rx(b);
  virtq_kick(&rxq);
  return n > 0 ? n : -1;
}

void vnet_ack(void)
{
  virtio_isr(&dev);
  mynos_enableIrq(dev.irq);
}
