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
 * The PC's I/O ports that the generic kernel still uses, on AArch64
 * (doc/decisions/aarch64.md): there are no ports, and these few are
 * answered by the machine's devices, so that video.c and time.c stay as
 * they are:
 *   - COM2 (0x2F8-0x2FF), the kernel's log and a terminal's keys (the
 *     console's serial input, consoled's): the PL011 UART. The data
 *     register, the line status (a byte waiting, the transmitter empty),
 *     the scratch register, the interrupt enable's "a byte came" (the
 *     PL011's receive and receive-timeout interrupts, SPI 1: line 1);
 *   - the CMOS clock (0x70, 0x71): the PL031 real-time clock's seconds,
 *     as the CMOS's registers in binary, 24-hour mode;
 *   - the rest (the VGA's registers, the 8259's EOI): nothing.
 * QEMU virt's addresses; a Raspberry Pi has its own (btq.7).
 */

#include "global.h"
#include "io.h"

#define UART      0x09000000UL          /* PL011 */
#define UART_DR   0x00
#define UART_FR   0x18                  /* bit 4: nothing received, 5: transmit FIFO full */
#define UART_IMSC 0x38                  /* interrupt mask: bit 4 receive, 6 receive timeout */
#define FR_RXFE   (1 << 4)
#define RTC       0x09010000UL          /* PL031: RTCDR, seconds since 1970 */

#define REG32(BASE, OFF) (*(volatile uint32_t *)DEVICE((BASE) + (OFF)))

static void uart_putc(unsigned char c)
{
  while (REG32(UART, UART_FR) & (1 << 5)) ;
  REG32(UART, UART_DR) = c;
}

/* ---- the CMOS clock, from the PL031's seconds ---- */

static unsigned char cmos_index;

static unsigned char cmos_value(unsigned char reg)
{
  static const unsigned char mdays[12] = { 31,28,31,30,31,30,31,31,30,31,30,31 };
  uint32_t t = REG32(RTC, 0), days = t / 86400, s = t % 86400, y = 1970, m = 0;
  for (;;) {
    uint32_t n = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 366 : 365;
    if (days < n) break;
    days -= n; y++;
  }
  for (;; m++) {
    uint32_t n = mdays[m] + (m == 1 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0));
    if (days < n) break;
    days -= n;
  }
  switch (reg) {
  case 0x00: return s % 60;
  case 0x02: return (s / 60) % 60;
  case 0x04: return s / 3600;
  case 0x07: return days + 1;
  case 0x08: return m + 1;
  case 0x09: return y % 100;
  case 0x0A: return 0;                  /* no update in progress */
  case 0x0B: return 0x06;               /* binary, 24 hours */
  default:   return 0;
  }
}

static unsigned char com2_scratch;

unsigned char inportb(unsigned short port)
{
  int ready = !(REG32(UART, UART_FR) & FR_RXFE);
  if (port == 0x2F8) return ready ? REG32(UART, UART_DR) & 0xFF : 0;
  if (port == 0x2F8 + 5) return 0x60 | ready;    /* transmitter empty; a byte */
  if (port == 0x2F8 + 7) return com2_scratch;
  if (port == 0x71) return cmos_value(cmos_index);
  return 0xFF;
}

void outportb(unsigned short port, unsigned char value)
{
  if (port == 0x2F8) uart_putc(value);
  else if (port == 0x2F8 + 1)                    /* interrupt enable */
    REG32(UART, UART_IMSC) = (value & 1) ? (1 << 4) | (1 << 6) : 0;
  else if (port == 0x2F8 + 7) com2_scratch = value;
  else if (port == 0x70) cmos_index = value & 0x7F;
}

void outportw(unsigned short port, unsigned short value)
{
  (void)port; (void)value;
}
