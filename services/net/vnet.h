/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A virtio network card (doc/decisions/virtio.md), with the same calls as
   the NE2000's (ne2k.h): netd uses whichever it finds. */

#ifndef __VNET_H__
#define __VNET_H__

/* find and start the first virtio network card: 0, its MAC address and
   its interrupt line; -1 if there is none */
int vnet_init(unsigned char mac[6], int * irq);

/* send a frame: 0, or -1 */
int vnet_send(const void * frame, unsigned int len);

/* a received frame copied into buf (NE2K_BUFSIZE bytes): its length; 0
   if none is waiting */
int vnet_recv(void * buf);

/* the card interrupted: acknowledged (the line may be unmasked) */
void vnet_ack(void);

#endif
