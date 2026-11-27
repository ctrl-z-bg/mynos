/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The SDIO of a Raspberry Pi 4's or 400's Wi-Fi (sdio.c): its Arasan
   SDHCI ("mmcnr", 0xFE300000), the card's functions 0-2, and the chip's
   backplane through function 1's 32 KB window. */

#ifndef __SDIO_H__
#define __SDIO_H__

/* the pins, the chip powered (WL_ON), the controller and the card
   initialised, function 1 enabled: 0, or -1 (logged) */
int sdio_init(void);

/* CMD52: a byte of function fn read (value < 0: the byte, or -1) or
   written (value >= 0: 0, or -1) */
int sdio_byte(int fn, unsigned int addr, int value);

/* CMD53: len bytes (a multiple of 4) read into or written from buf, at
   function fn's address addr (incrementing); in byte mode up to the
   function's block size, else in blocks (len a multiple of it): 0, or -1 */
int sdio_ext(int write, int fn, unsigned int addr, void * buf, int len);

/* a function enabled (its ready bit waited for, up to ms): 0, or -1 */
int sdio_enable(int fn, int ms);

/* the backplane, through function 1's window: a word, or bytes (any
   address, a multiple of 4 bytes) */
int bp_read32(unsigned int addr, unsigned int * v);
int bp_write32(unsigned int addr, unsigned int v);
int bp_write(unsigned int addr, const void * buf, int len);
int bp_read(unsigned int addr, void * buf, int len);

/* function 1's registers (the backplane's window, the clocks) */
#define SB_ADDRLOW     0x1000A
#define SB_ADDRMID     0x1000B
#define SB_ADDRHIGH    0x1000C
#define SB_CHIPCLKCSR  0x1000E
#define SB_PULLUP      0x1000F
#define SB_WATERMARK   0x10008
#define  CLK_FORCE_ALP      0x01
#define  CLK_FORCE_HT       0x02
#define  CLK_ALP_AVAIL_REQ  0x08
#define  CLK_HT_AVAIL_REQ   0x10
#define  CLK_FORCE_HW_OFF   0x20
#define  CLK_ALP_AVAIL      0x40
#define  CLK_HT_AVAIL       0x80

/* the board's firmware (the mailbox): a tag's request, its answer's
   words in out (up to n): 0, or -1 */
int pi_property(unsigned int tag, const unsigned int * in, int nin, unsigned int * out, int nout);

#endif
