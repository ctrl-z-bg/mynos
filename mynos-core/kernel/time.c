/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.
*/

/*
 * Time: the monotonic clock is the PIT tick counter (timerTicks, PIT_FREQ
 * per second); the wall clock is the CMOS real-time clock read once at boot
 * plus the ticks since then. Sleeping uses the timer queue that sched()
 * checks on every tick.
 *
 * Only 32-bit divisions here: 64-bit ones would need libgcc, which the
 * kernel does not link.
 */

#include "global.h"
#include "io.h"
#include "video.h"
#include "pit.h"
#include "process.h"
#include "sched.h"
#include "sem.h"
#include "time.h"

#define NSEC_PER_TICK (1000000000 / PIT_FREQ)
#define USEC_PER_TICK (1000000 / PIT_FREQ)

/* seconds since 1970-01-01 UTC when timerTicks was 0 */
static uint32_t boot_epoch = 0;

/* ---- CMOS real-time clock ------------------------------------------------ */

static uint32_t cmos_read(uint32_t reg) {
  outportb(0x70, reg);
  return inportb(0x71);
}

static uint32_t bcd(uint32_t v, int binary) {
  return binary ? v : ((v >> 4) * 10 + (v & 0x0F));
}

/* days from 1970-01-01 to y-m-d (proleptic Gregorian) */
static uint32_t days_from_civil(uint32_t y, uint32_t m, uint32_t d) {
  uint32_t era, yoe, doy, doe;
  if (m <= 2) y--;
  era = y / 400;
  yoe = y - era * 400;
  doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

void time_init() {
  uint32_t sec, min, hour, day, mon, year, regb;
  int binary, h12;

  /* wait for the end of an update cycle */
  while (cmos_read(0x0A) & 0x80)
    ;
  sec  = cmos_read(0x00);
  min  = cmos_read(0x02);
  hour = cmos_read(0x04);
  day  = cmos_read(0x07);
  mon  = cmos_read(0x08);
  year = cmos_read(0x09);
  regb = cmos_read(0x0B);

  binary = regb & 0x04;
  h12 = !(regb & 0x02);
  sec  = bcd(sec, binary);
  min  = bcd(min, binary);
  day  = bcd(day, binary);
  mon  = bcd(mon, binary);
  year = bcd(year, binary) + 2000;   /* the RTC century register is optional */
  if (h12 && (hour & 0x80))
    hour = (bcd(hour & 0x7F, binary) % 12) + 12;
  else
    hour = bcd(hour & 0x7F, binary);

  boot_epoch = days_from_civil(year, mon, day) * 86400
    + hour * 3600 + min * 60 + sec;

  printk("Real-time clock: ");
  print_ulong(year); print_char('-');
  if (mon < 10) print_char('0');
  print_ulong(mon); print_char('-');
  if (day < 10) print_char('0');
  print_ulong(day); print_char(' ');
  if (hour < 10) print_char('0');
  print_ulong(hour); print_char(':');
  if (min < 10) print_char('0');
  print_ulong(min);
  printk(" UTC\n");
}

/* ---- clocks ------------------------------------------------------------- */

void time_now(uint32_t clock, uint32_t * sec, uint32_t * nsec) {
  uint32_t t = timerTicks;
  if (clock == CLOCK_PROCESS_CPUTIME_ID || clock == CLOCK_THREAD_CPUTIME_ID)
    t = processTable[currProcess]->cpuTicks;
  *sec = t / PIT_FREQ + (clock == CLOCK_REALTIME ? boot_epoch : 0);
  *nsec = (t % PIT_FREQ) * NSEC_PER_TICK;
}

/* ---- sleeping ----------------------------------------------------------- */

/* ticks needed to wait at least sec + nsec (rounded up) */
uint32_t time_toTicks(uint32_t sec, uint32_t nsec) {
  return sec * PIT_FREQ + (nsec + NSEC_PER_TICK - 1) / NSEC_PER_TICK;
}

/* block the current thread for at least `ticks` ticks (0: just yield the
   rest of the current tick) */
void time_sleepTicks(uint32_t ticks) {
  timerQueueInsert(currThread, ticks * ONE_TICK_TIME);
  privP();
}

void time_sleepUsec(uint32_t usec) {
  time_sleepTicks((usec + USEC_PER_TICK - 1) / USEC_PER_TICK);
}
