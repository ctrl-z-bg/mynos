/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Waits on AArch64: the generic timer's counter, whose frequency the
   processor tells (CNTFRQ_EL0): nothing to calibrate. */

#include "global.h"
#include "delay.h"

static uint64_t counter(void)
{
  uint64_t v;
  __asm__ volatile ("isb; mrs %0, cntvct_el0" : "=r"(v));
  return v;
}

void delay(unsigned long milliseconds)
{
  uint64_t f, end;
  __asm__ volatile ("mrs %0, cntfrq_el0" : "=r"(f));
  end = counter() + f / 1000 * milliseconds;
  while (counter() < end) ;
}

unsigned long calibrateDelayLoop(void) { return 0; }
