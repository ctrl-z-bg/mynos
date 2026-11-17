/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The NE2000 (DP8390) network card, through I/O ports, polled. */

#ifndef __NE2K_H__
#define __NE2K_H__

#define NE2K_MAXFRAME 1518
#define NE2K_BUFSIZE  1520     /* a receive buffer: a frame, rounded up */

/* find and start the card at this I/O base (0x300 for QEMU's ne2k_isa):
   0, and its MAC address; -1 if there is no card */
int ne2k_init(unsigned short iobase, unsigned char mac[6]);

/* send a frame (padded to the minimum length): 0, or -1 */
int ne2k_send(const void * frame, unsigned int len);

/* a received frame copied into buf (NE2K_BUFSIZE bytes): its length; 0
   if none is waiting; -1 for a frame dropped (call again) */
int ne2k_recv(void * buf);

#endif
