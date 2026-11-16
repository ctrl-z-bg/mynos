/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

#ifndef __TIME_H__
#define __TIME_H__

#include "global.h"

/* Linux clock ids */
#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1

/* read the CMOS real-time clock (call once at boot) */
void time_init();

/* current time of a clock: CLOCK_REALTIME (since 1970) or any other id
   (monotonic, since boot) */
void time_now(uint32_t clock, uint32_t * sec, uint32_t * nsec);

/* ticks needed to wait at least sec + nsec */
uint32_t time_toTicks(uint32_t sec, uint32_t nsec);

/* block the current thread */
void time_sleepTicks(uint32_t ticks);
void time_sleepUsec(uint32_t usec);

#endif
