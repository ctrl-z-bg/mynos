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
 * consoled: the console service. It owns the keyboard (IRQ 1), edits the
 * line being typed (echo, backspace, Ctrl-D for end of file) and gives
 * complete lines to clients over IPC: it is what a program reads as its
 * standard input (see mynos-lib/src/fileio.c). Output still goes straight
 * to the kernel's screen driver.
 *
 * Protocol, port registered as "console", one connection per request:
 *   request: struct console_req { int op; int len; }, op CONSOLE_READ
 *   reply:   up to len bytes of input; 0 bytes means end of file
 *
 * Two threads: the keyboard thread waits for interrupts and builds lines;
 * the main thread serves clients. MyNOS threads share their creator's TLS
 * (mynos-l9h), so the keyboard thread never calls the C library: only
 * MyNOS calls, port I/O and a raw write system call.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mynos.h>
#include <mynos_console.h>
#include "../keyboard/keymap.h"

#define LINE_MAX 256
#define QUEUE_MAX 4096

/* the line being edited (keyboard thread only) */
static char line[LINE_MAX];
static int line_len = 0;

/* completed input waiting for readers, protected by `lock` */
static char queue[QUEUE_MAX];
static int queue_len = 0;
static int eof_pending = 0;

static int lock;        /* mutex for queue/eof_pending */
static int available;   /* V'd when input (or an end of file) is queued */

/* write to the screen through the kernel, without the C library */
static void raw_write(const char * s, int n)
{
  int ret = 4;  /* Linux write */
  __asm__ volatile ("int $0x80"
		    : "+a"(ret) : "b"(1), "c"(s), "d"(n) : "memory");
}

static void queue_input(const char * s, int n, int eof)
{
  mynos_P(lock);
  if (queue_len + n > QUEUE_MAX) n = QUEUE_MAX - queue_len;
  memcpy(queue + queue_len, s, n);   /* memcpy uses no TLS: safe here */
  queue_len += n;
  if (eof) eof_pending = 1;
  mynos_V(lock);
  mynos_V(available);
}

static void key_typed(unsigned int c)
{
  if (c == '\n' || c == '\r') {
    raw_write("\n", 1);
    line[line_len++] = '\n';
    queue_input(line, line_len, 0);
    line_len = 0;
  } else if (c == 0x08) {              /* backspace */
    if (line_len > 0) {
      line_len--;
      raw_write("\b \b", 3);
    }
  } else if (c == 0x04) {              /* Ctrl-D */
    if (line_len == 0)
      queue_input("", 0, 1);           /* end of file */
    else {
      queue_input(line, line_len, 0);  /* flush the partial line */
      line_len = 0;
    }
  } else if (c >= 0x20 && c < 0x7F && line_len < LINE_MAX - 1) {
    char ch = (char)c;
    line[line_len++] = ch;
    raw_write(&ch, 1);
  }
}

static void * keyboard_thread(void * arg)
{
  int irq = (int)arg;
  while (1) {
    unsigned int key, c;
    mynos_P(irq);
    key = inportb(0x60);
    c = keymap_translate(key);
    outportb(0x20, 0x20);
    if (c != 0 && c <= 0xFF)
      key_typed(c);
  }
  return NULL;
}

/* take up to n bytes of queued input; 0 = end of file */
static int take_input(char * buf, int n)
{
  int got;
  mynos_P(available);
  mynos_P(lock);
  if (queue_len == 0 && eof_pending) {
    eof_pending = 0;
    mynos_V(lock);
    return 0;
  }
  got = queue_len < n ? queue_len : n;
  memcpy(buf, queue, got);
  memmove(queue, queue + got, queue_len - got);
  queue_len -= got;
  if (queue_len > 0 || eof_pending)
    mynos_V(available);   /* more for the next reader */
  mynos_V(lock);
  return got;
}

int main()
{
  int irq, port;
  char * stack;

  lock = mynos_initSem(1);
  available = mynos_initSem(0);

  irq = mynos_driverRegister("keyboard", 1, NULL, NULL);
  if (irq < 0) {
    printf("consoled: cannot get the keyboard (%d)\n", irq);
    return 1;
  }
  led_status = 0;
  setleds();
  mynos_enableIrq(1);

  stack = malloc(0x4000);
  mynos_threadCreate(keyboard_thread, (void *)irq, stack + 0x4000, 0);

  port = mynos_registryRegister(CONSOLE_SERVICE);
  if (port < 0) {
    printf("consoled: cannot register (%d)\n", port);
    return 1;
  }
  printf("consoled: console service on port %d\n", port);

  while (1) {
    int channel = mynos_listenPort(port);
    mynos_msg_t * msg;
    struct console_req req;
    static char buf[QUEUE_MAX];
    int n;

    if (channel < 0) continue;
    if (mynos_recv(channel, &msg, 0, 0) < 0) {
      mynos_freeChannel(channel);
      continue;
    }
    if (msg->size == sizeof(req)) {
      memcpy(&req, msg->start, sizeof(req));
      if (req.op == CONSOLE_READ) {
	if (req.len > (int)sizeof(buf)) req.len = sizeof(buf);
	n = take_input(buf, req.len);
	mynos_send(channel, buf, n, 0);
      }
    }
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
  }
  return 0;
}
