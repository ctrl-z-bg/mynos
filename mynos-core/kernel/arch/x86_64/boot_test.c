/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The first step of x86-64 (doc/decisions/x86-64.md): long mode reached,
   a line on the screen and on the log port (COM2), through the identity
   map and through the direct map; then the processor stops. */

typedef unsigned long u64;
typedef unsigned short u16;
typedef unsigned char u8;

#define DIRECT_MAP 0xFFFF800000000000ul

static inline void outb(u16 port, u8 v) { __asm__ volatile ("outb %0, %1" : : "a"(v), "Nd"(port)); }

static void log_str(const char * s)
{
  for (; *s; s++) outb(0x2F8, *s);
}

static void screen(int row, const char * s, volatile u16 * vga)
{
  int i;
  for (i = 0; s[i]; i++) vga[row * 80 + i] = 0x0A00 | (u8)s[i];
}

void arch_start64(unsigned int magic, unsigned int mbi)
{
  (void)mbi;
  screen(0, "MyNOS: long mode, 64 bits", (volatile u16 *)0xB8000);
  screen(1, "and the direct map works", (volatile u16 *)(DIRECT_MAP + 0xB8000));
  log_str(magic == 0x2BADB002 ? "MyNOS x86-64: long mode, multiboot\n"
                              : "MyNOS x86-64: long mode, no multiboot?\n");
  log_str("MyNOS x86-64: the direct map reaches the screen\n");
  for (;;) __asm__ volatile ("cli; hlt");
}
