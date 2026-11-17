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
 * The kernel's random numbers, for getrandom (Linux 355), good enough for
 * cryptography (TLS keys in netd). See random.c.
 */

#ifndef __RANDOM_H__
#define __RANDOM_H__

#include "global.h"

void random_init(void);
/* an event's time stamp counter, and a word about it (an IRQ number...):
   called by the timer and by the interrupt dispatcher */
void random_event(uint32_t what);
/* len bytes into buf (kernel memory) */
void random_get(ubyte_t * buf, uint32_t len);

#endif
