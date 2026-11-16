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
 * Protocol (mynos_console.h), port registered as "console", one connection
 * per request: CONSOLE_READ returns up to len bytes of input (0 bytes: end
 * of file); CONSOLE_MODE switches between line editing ("canonical") and
 * raw input, key by key, as termios does: libmynos turns tcsetattr into
 * it. In raw mode Enter is \r, Backspace DEL, the arrows and the editing
 * keys VT100 sequences (ESC [ A...); the raw mode belongs to the process
 * that set it, and a read from another process ends it.
 *
 * History: the last HIST_MAX lines typed are kept in memory; Up and Down
 * (or Ctrl-P and Ctrl-N) bring them back for editing, as in a Unix shell.
 * When there is a disk (/disk, fatfs), the history is kept in
 * HISTORY_FILE too, read at the first request and appended to by the main
 * thread, so it survives a reboot.
 *
 * Two threads: the keyboard thread waits for interrupts and builds lines;
 * the main thread serves clients. MyNOS threads share their creator's TLS
 * (mynos-l9h), so the keyboard thread never calls the C library: only
 * MyNOS calls, port I/O and a raw write system call.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mynos.h>
#include <mynos_console.h>
#include "../keyboard/keymap.h"

#define LINE_MAX 256
#define QUEUE_MAX 4096
#define HIST_MAX 64
#define HISTORY_FILE "/disk/.history"
#define HISTORY_READ 65536        /* the end of the file that is read */

/* the line being edited (keyboard thread only) */
static char line[LINE_MAX];
static int line_len = 0;

/* history: a ring of the last HIST_MAX lines, without their newline,
   protected by hist_lock (the keyboard thread edits it, the main thread
   loads it). hist_pos is the line shown while browsing; hist_count when
   editing a new line, which is kept in scratch meanwhile. */
static char history[HIST_MAX][LINE_MAX];
static int history_len[HIST_MAX];
static int hist_count = 0;       /* lines entered so far (all time) */
static int hist_pos = 0;
static char scratch[LINE_MAX];
static int scratch_len = 0;
static int hist_lock;

/* lines entered and not yet appended to HISTORY_FILE, under hist_lock */
static char pending[QUEUE_MAX];
static int pending_len = 0;

/* the input mode (CONSOLE_MODE) */
static int canon = 1, echo = 1, vmin = 1, vtime = 0, mode_owner = 0;

/* keys beyond ASCII (keymap_translate: scan code << 8) */
#define KEY_UP     0x4800
#define KEY_DOWN   0x5000
#define KEY_LEFT   0x4B00
#define KEY_RIGHT  0x4D00
#define KEY_HOME   0x4700
#define KEY_END    0x4F00
#define KEY_PGUP   0x4900
#define KEY_PGDN   0x5100
#define KEY_INSERT 0x5200
#define KEY_DELETE 0x5300
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

/* add a line to the ring (under hist_lock); 0 if it repeats the last */
static int history_push(const char * s, int n)
{
  int last = (hist_count - 1) % HIST_MAX;
  if (n == 0 || n > LINE_MAX - 1) return 0;
  if (hist_count > 0 && history_len[last] == n &&
      !memcmp(history[last], s, n))
    return 0;                          /* same as the previous one */
  memcpy(history[hist_count % HIST_MAX], s, n);
  history_len[hist_count % HIST_MAX] = n;
  hist_count++;
  return 1;
}

static void history_add(void)
{
  mynos_P(hist_lock);
  if (history_push(line, line_len) &&
      pending_len + line_len + 1 <= QUEUE_MAX) {
    memcpy(pending + pending_len, line, line_len);
    pending[pending_len + line_len] = '\n';
    pending_len += line_len + 1;
  }
  mynos_V(hist_lock);
}

/* move in the history: -1 older, +1 newer */
static void history_move(int dir)
{
  int oldest = hist_count > HIST_MAX ? hist_count - HIST_MAX : 0;
  int pos = hist_pos + dir;
  if (pos < oldest || pos > hist_count) return;
  mynos_P(hist_lock);
  if (hist_pos == hist_count) {        /* leaving the new line: keep it */
    memcpy(scratch, line, line_len);
    scratch_len = line_len;
  }
  hist_pos = pos;
  if (pos == hist_count)
    show_line(scratch, scratch_len);
  else
    show_line(history[pos % HIST_MAX], history_len[pos % HIST_MAX]);
  mynos_V(hist_lock);
}

/* ---- the history file (main thread only: it uses the C library) ---- */

static int history_loaded = 0;

/* the last HIST_MAX lines of HISTORY_FILE into the ring; a file grown past
   twice that is rewritten with them only */
static void history_load(void)
{
  static char data[HISTORY_READ];
  int fd, n = 0, i, start, nlines = 0;
  long size;
  int begin[HIST_MAX];

  if ((fd = open(HISTORY_FILE, O_RDONLY)) < 0) return;
  size = lseek(fd, 0, SEEK_END);
  lseek(fd, size > HISTORY_READ ? size - HISTORY_READ : 0, SEEK_SET);
  n = read(fd, data, sizeof(data));
  close(fd);
  if (n <= 0) return;

  /* the start of each whole line; keep the last HIST_MAX */
  start = size > HISTORY_READ ? -1 : 0;      /* a cut first line is dropped */
  for (i = 0; i < n; i++)
    if (data[i] == '\n') {
      if (start >= 0 && i > start) {
	begin[nlines % HIST_MAX] = start;
	nlines++;
      }
      start = i + 1;
    }
  mynos_P(hist_lock);
  for (i = nlines > HIST_MAX ? nlines - HIST_MAX : 0; i < nlines; i++) {
    int b = begin[i % HIST_MAX], e = b;
    while (data[e] != '\n') e++;
    history_push(data + b, e - b);
  }
  hist_pos = hist_count;
  mynos_V(hist_lock);

  if (nlines > 2 * HIST_MAX &&
      (fd = open(HISTORY_FILE, O_WRONLY | O_TRUNC)) >= 0) {
    int b = begin[(nlines - HIST_MAX) % HIST_MAX];
    write(fd, data + b, n - b);
    close(fd);
  }
}

/* load the history once a disk is there, then append the new lines */
static void history_sync(void)
{
  static char out[QUEUE_MAX];
  struct stat st;
  int n, fd;

  if (!history_loaded) {
    if (stat("/disk", &st) != 0) return;     /* no disk (yet) */
    history_load();
    history_loaded = 1;
  }
  mynos_P(hist_lock);
  n = pending_len;
  memcpy(out, pending, n);
  pending_len = 0;
  mynos_V(hist_lock);
  if (n > 0 &&
      (fd = open(HISTORY_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644)) >= 0) {
    write(fd, out, n);
    close(fd);
  }
}

/* raw mode: the key goes to the program at once, as a terminal sends it */
static void raw_key(unsigned int c)
{
  const char * seq = NULL;
  char b;
  switch (c) {
  case KEY_UP:     seq = "\033[A"; break;
  case KEY_DOWN:   seq = "\033[B"; break;
  case KEY_RIGHT:  seq = "\033[C"; break;
  case KEY_LEFT:   seq = "\033[D"; break;
  case KEY_HOME:   seq = "\033[H"; break;
  case KEY_END:    seq = "\033[F"; break;
  case KEY_PGUP:   seq = "\033[5~"; break;
  case KEY_PGDN:   seq = "\033[6~"; break;
  case KEY_INSERT: seq = "\033[2~"; break;
  case KEY_DELETE: seq = "\033[3~"; break;
  }
  if (seq) {
    queue_input(seq, strlen(seq), 0);
    return;
  }
  if (c > 0xFF) return;
  b = (char)c;
  if (b == '\n') b = '\r';
  else if (b == 0x08) b = 0x7F;
  queue_input(&b, 1, 0);
  if (echo && b >= ' ' && b < 0x7F) raw_write(&b, 1);
}

static void key_typed(unsigned int c)
{
  if (!canon) {
    raw_key(c);
    return;
  }
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
    /* the grey keys are themselves even with Num Lock on (the keypad
       shares their scan codes) */
    if (extended && (key == 0x48 || key == 0x50 || key == 0x4B ||
		     key == 0x4D || key == 0x47 || key == 0x4F ||
		     key == 0x49 || key == 0x51 || key == 0x52 || key == 0x53))
      c = key << 8;
    else
      c = keymap_translate(key);
    extended = 0;
    outportb(0x20, 0x20);
    if (c != 0)
      key_typed(c);
  }
  return NULL;
}

/* take up to n bytes of queued input; 0 = end of file, or no input
   within timeout_ms (if > 0) */
static int take_input(char * buf, int n, int timeout_ms)
{
  int got;
  if (timeout_ms > 0) {
    int waited = 0;
    while (mynos_tryP(available) != 0) {
      if (waited >= timeout_ms) return 0;
      mynos_sleep(10000);
      waited += 10;
    }
  } else
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
  hist_lock = mynos_initSem(1);
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
	if (!canon && req.pid != mode_owner) {
	  canon = echo = 1;      /* its program is gone (or did not restore) */
	  vmin = 1;
	  vtime = 0;
	}
	history_sync();          /* a program is about to read: a good time */
	n = take_input(buf, req.len,
		       (!canon && vmin == 0 && vtime > 0) ? vtime * 100 : 0);
	mynos_send(channel, buf, n, 0);
      } else if (req.op == CONSOLE_MODE) {
	canon = (req.mode & CONSOLE_CANON) != 0;
	echo = (req.mode & CONSOLE_ECHO) != 0;
	vmin = req.vmin;
	vtime = req.vtime;
	mode_owner = req.pid;
	if (canon) line_len = 0;
	mynos_send(channel, buf, 0, 0);
      }
    }
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
  }
  return 0;
}
