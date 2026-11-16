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
 * History: the last HIST_MAX lines typed are kept in memory; Up and Down
 * (or Ctrl-P and Ctrl-N) bring them back for editing, as in a Unix shell.
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
#define HIST_MAX 64

/* the line being edited (keyboard thread only) */
static char line[LINE_MAX];
static int line_len = 0;

/* history (keyboard thread only): a ring of the last HIST_MAX lines, without
   their newline. hist_pos is the line shown while browsing; hist_count when
   editing a new line, which is kept in scratch meanwhile. */
static char history[HIST_MAX][LINE_MAX];
static int history_len[HIST_MAX];
static int hist_count = 0;       /* lines entered so far (all time) */
static int hist_pos = 0;
static char scratch[LINE_MAX];
static int scratch_len = 0;

/* keys beyond ASCII (keymap_translate: scan code << 8) */
#define KEY_UP   0x4800
#define KEY_DOWN 0x5000
#define CTRL_P   0x10
#define CTRL_N   0x0E

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

/* replace the line on screen and in the buffer */
static void show_line(const char * s, int n)
{
  static char erase[3 * LINE_MAX];
  int i;
  for (i = 0; i < line_len; i++) {
    erase[3 * i] = '\b';
    erase[3 * i + 1] = ' ';
    erase[3 * i + 2] = '\b';
  }
  raw_write(erase, 3 * line_len);
  memcpy(line, s, n);
  line_len = n;
  raw_write(line, line_len);
}

static void history_add(void)
{
  int last = (hist_count - 1) % HIST_MAX;
  if (line_len == 0) return;
  if (hist_count > 0 && history_len[last] == line_len &&
      !memcmp(history[last], line, line_len))
    return;                            /* same as the previous one */
  memcpy(history[hist_count % HIST_MAX], line, line_len);
  history_len[hist_count % HIST_MAX] = line_len;
  hist_count++;
}

/* move in the history: -1 older, +1 newer */
static void history_move(int dir)
{
  int oldest = hist_count > HIST_MAX ? hist_count - HIST_MAX : 0;
  int pos = hist_pos + dir;
  if (pos < oldest || pos > hist_count) return;
  if (hist_pos == hist_count) {        /* leaving the new line: keep it */
    memcpy(scratch, line, line_len);
    scratch_len = line_len;
  }
  hist_pos = pos;
  if (pos == hist_count)
    show_line(scratch, scratch_len);
  else
    show_line(history[pos % HIST_MAX], history_len[pos % HIST_MAX]);
}

static void key_typed(unsigned int c)
{
  if (c == KEY_UP || c == CTRL_P) {
    history_move(-1);
  } else if (c == KEY_DOWN || c == CTRL_N) {
    history_move(+1);
  } else if (c == '\n' || c == '\r') {
    raw_write("\n", 1);
    history_add();
    hist_pos = hist_count;
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
  int extended = 0;
  while (1) {
    unsigned int key, c;
    mynos_P(irq);
    key = inportb(0x60);
    if (key == 0xE0) {                 /* prefix of the grey keys */
      extended = 1;
      outportb(0x20, 0x20);
      continue;
    }
    /* grey arrows are arrows even with Num Lock on (keypad 8 and 2 share
       their scan codes) */
    if (extended && (key == 0x48 || key == 0x50))
      c = key << 8;
    else
      c = keymap_translate(key);
    extended = 0;
    outportb(0x20, 0x20);
    if (c != 0 && (c <= 0xFF || c == KEY_UP || c == KEY_DOWN))
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
    mynos_log("consoled: cannot get the keyboard (%d)\n", irq);
    return 1;
  }
  led_status = 0;
  setleds();
  mynos_enableIrq(1);

  stack = malloc(0x4000);
  mynos_threadCreate(keyboard_thread, (void *)irq, stack + 0x4000, 0);

  port = mynos_registryRegister(CONSOLE_SERVICE);
  if (port < 0) {
    mynos_log("consoled: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("consoled: console service on port %d\n", port);

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
