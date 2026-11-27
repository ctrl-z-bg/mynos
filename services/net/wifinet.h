/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* A Raspberry Pi's Wi-Fi as netd's card (wifinet.c): wifid's frames over
   IPC (wifi/1), with the same calls as the other cards'. */

#ifndef __WIFINET_H__
#define __WIFINET_H__

/* wifid found (waited for up to wait_s seconds), its MAC address; wake
   is called (from another thread) when frames have come: 0, or -1 */
int wifi_init(unsigned char mac[6], int wait_s, void (*wake)(void));

/* send a frame: 0, or -1 */
int wifi_send(const void * frame, unsigned int len);

/* a received frame copied into buf (NE2K_BUFSIZE bytes): its length; 0
   if none is waiting */
int wifi_recv(void * buf);

#endif
