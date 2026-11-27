/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A Raspberry Pi 4's Ethernet, GENET (genet.c), with the same calls as
   the NE2000's (ne2k.h): netd uses whichever card it finds. */

#ifndef __GENET_H__
#define __GENET_H__

/* start the GENET and its PHY: 0, its MAC address and its interrupt
   line; -1 if there is none */
int genet_init(unsigned char mac[6], int * irq);

/* send a frame: 0, or -1 */
int genet_send(const void * frame, unsigned int len);

/* a received frame copied into buf (NE2K_BUFSIZE bytes): its length; 0
   if none is waiting, -1 for a frame dropped */
int genet_recv(void * buf);

/* the GENET interrupted: acknowledged, its line unmasked again */
void genet_ack(void);

#endif
