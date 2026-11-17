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
 * Characters are UTF-8 (doc/decisions/console.md): keyboard layouts (us,
 * it: CONSOLE_KEYMAP, remembered in KEYMAP_FILE) give Unicode characters,
 * and line editing moves over whole characters. Shift + Page Up / Page
 * Down page through the kernel terminal's scrollback.
 *
 * The second serial port (COM2) is a second keyboard: the host's terminal,
 * when QEMU connects it to one (SERIAL=1 tools/run-demo.sh). The kernel
 * writes the screen's output there, so that terminal is a whole console,
 * with the host's copy and paste.
 *
 * Three threads: the keyboard and the serial threads wait for interrupts
 * and build lines (one at a time: input_lock); the main thread serves
 * clients. MyNOS threads share their creator's TLS
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
#define KEYMAP_FILE "/disk/.keymap"

/* a Unicode character from a layout (other values: ASCII, control
   characters, or a key's scan code << 8) */
#define UNI 0x1000000

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

/* ---- keyboard layouts: the characters of the keys (by scan code):
   normal, with Shift, with AltGr (0: none). Letters follow Caps Lock. ---- */

struct layout_key { unsigned short code, normal, shift, altgr; };

static const struct layout_key layout_us[] = {
  {0x02,'1','!',0}, {0x03,'2','@',0}, {0x04,'3','#',0}, {0x05,'4','$',0},
  {0x06,'5','%',0}, {0x07,'6','^',0}, {0x08,'7','&',0}, {0x09,'8','*',0},
  {0x0A,'9','(',0}, {0x0B,'0',')',0}, {0x0C,'-','_',0}, {0x0D,'=','+',0},
  {0x1A,'[','{',0}, {0x1B,']','}',0}, {0x27,';',':',0}, {0x28,'\'','"',0},
  {0x29,'`','~',0}, {0x2B,'\\','|',0}, {0x33,',','<',0}, {0x34,'.','>',0},
  {0x35,'/','?',0}, {0x39,' ',' ',0}, {0x56,'\\','|',0}, {0,0,0,0}
};

static const struct layout_key layout_it[] = {
  {0x02,'1','!',0}, {0x03,'2','"',0}, {0x04,'3',0xA3,0}, {0x05,'4','$',0},
  {0x06,'5','%',0x20AC}, {0x07,'6','&',0}, {0x08,'7','/','{'},
  {0x09,'8','(','['}, {0x0A,'9',')',']'}, {0x0B,'0','=','}'},
  {0x0C,'\'','?','`'}, {0x0D,0xEC,'^','~'},
  {0x12,'e','E',0x20AC},
  {0x1A,0xE8,0xE9,'['}, {0x1B,'+','*',']'}, {0x27,0xF2,0xE7,'@'},
  {0x28,0xE0,0xB0,'#'}, {0x29,'\\','|',0xAC}, {0x2B,0xF9,0xA7,0},
  {0x33,',',';',0}, {0x34,'.',':',0}, {0x35,'-','_',0}, {0x39,' ',' ',0},
  {0x56,'<','>',0}, {0,0,0,0}
};

static const struct layout_key * layouts[] = { layout_us, layout_it };
static int layout = CONSOLE_LAYOUT_US;
static int altgr_key = 0;            /* right Alt held */

/* the letters of the US keyboard, by scan code (the same in both layouts) */
static const char letters[0x40] =
  "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0qwertyuiop\0\0\0\0asdfghjkl\0\0\0\0\0zxcvbnm";

/* the character of a key in the current layout; 0 if it is not a
   character key there */
static unsigned int layout_char(unsigned int key)
{
  const struct layout_key * k;
  int shift = (control_keys & CK_SHIFT) != 0;
  int altgr = altgr_key || (control_keys & (CK_CTRL | CK_ALT)) == (CK_CTRL | CK_ALT);
  for (k = layouts[layout]; k->code; k++)
    if (k->code == key) {
      if (altgr) return k->altgr;
      if (k->normal >= 'a' && k->normal <= 'z') break;   /* a letter: below */
      return shift ? k->shift : k->normal;
    }
  if (key < sizeof letters && letters[key]) {
    int upper = shift ^ ((led_status & LED_CAPS_LOCK) != 0);
    if (altgr) return 0;
    return letters[key] - (upper ? 32 : 0);
  }
  return 0;
}

static int utf8_encode(unsigned int u, char * out)
{
  if (u < 0x80) { out[0] = u; return 1; }
  if (u < 0x800) { out[0] = 0xC0 | (u >> 6); out[1] = 0x80 | (u & 0x3F); return 2; }
  out[0] = 0xE0 | (u >> 12);
  out[1] = 0x80 | ((u >> 6) & 0x3F);
  out[2] = 0x80 | (u & 0x3F);
  return 3;
}

/* the cells of a line: its characters, not its bytes */
static int cells(const char * s, int n)
{
  int i, c = 0;
  for (i = 0; i < n; i++) if ((s[i] & 0xC0) != 0x80) c++;
  return c;
}

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
  int i, shown = cells(line, line_len);
  for (i = 0; i < shown; i++) {
    erase[3 * i] = '\b';
    erase[3 * i + 1] = ' ';
    erase[3 * i + 2] = '\b';
  }
  raw_write(erase, 3 * shown);
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

/* the layout: read from KEYMAP_FILE once there is a disk, written there
   when a client changes it (main thread) */
static int keymap_loaded = 0, keymap_saved = 1;

static void keymap_sync(void)
{
  struct stat st;
  int fd;
  if (!keymap_loaded) {
    char name[4] = { 0 };
    if (stat("/disk", &st) != 0) return;
    keymap_loaded = 1;
    if (keymap_saved && (fd = open(KEYMAP_FILE, O_RDONLY)) >= 0) {
      read(fd, name, 2);
      close(fd);
      if (!strcmp(name, "it")) layout = CONSOLE_LAYOUT_IT;
      else if (!strcmp(name, "us")) layout = CONSOLE_LAYOUT_US;
    }
  }
  if (!keymap_saved && (fd = open(KEYMAP_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644)) >= 0) {
    write(fd, layout == CONSOLE_LAYOUT_IT ? "it\n" : "us\n", 3);
    close(fd);
    keymap_saved = 1;
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
  if (c & UNI) {
    char u[4];
    int n = utf8_encode(c & ~UNI, u);
    queue_input(u, n, 0);
    if (echo) raw_write(u, n);
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
  } else if (c == 0x08) {              /* backspace: a whole character */
    if (line_len > 0) {
      while (line_len > 1 && (line[line_len - 1] & 0xC0) == 0x80) line_len--;
      line_len--;
      raw_write("\b \b", 3);
    }
  } else if (c & UNI) {
    char u[4];
    int n = utf8_encode(c & ~UNI, u);
    if (line_len + n < LINE_MAX - 1) {
      memcpy(line + line_len, u, n);
      line_len += n;
      raw_write(u, n);
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

/* keys from the keyboard and the serial port, one at a time */
static int input_lock;
static int looking_back = 0;         /* the screen shows the scrollback */

static void input(unsigned int c)
{
  mynos_P(input_lock);
  if (looking_back) {                 /* any other key: the live screen */
    raw_write("\033[?0v", 5);
    looking_back = 0;
  }
  key_typed(c);
  mynos_V(input_lock);
}

static void * keyboard_thread(void * arg)
{
  int irq = (int)arg;
  int extended = 0;
  while (1) {
    unsigned int key, c = 0;
    mynos_P(irq);
    key = inportb(0x60);
    if (key == 0xE0) {                 /* prefix of the grey keys */
      extended = 1;
      outportb(0x20, 0x20);
      continue;
    }
    if (extended && (key == 0x2A || key == 0xAA || key == 0x36 || key == 0xB6)) {
      /* the keyboard's "fake shifts" around the grey keys: not the user's */
    } else if (extended && (key == 0x38 || key == 0xB8))
      altgr_key = key == 0x38;         /* right Alt: AltGr */
    /* the grey keys are themselves even with Num Lock on (the keypad
       shares their scan codes) */
    else if (extended && (key == 0x48 || key == 0x50 || key == 0x4B ||
			  key == 0x4D || key == 0x47 || key == 0x4F ||
			  key == 0x49 || key == 0x51 || key == 0x52 || key == 0x53))
      c = key << 8;
    else if (!extended && key < 0x80 &&
	     ((control_keys & (CK_CTRL | CK_ALT)) == 0 ||
	      (control_keys & (CK_CTRL | CK_ALT)) == (CK_CTRL | CK_ALT)) &&
	     key != 0x53 && (c = layout_char(key)) != 0)
      /* Ctrl + Alt is AltGr too, for keyboards without it (key 0x53, Delete,
	 is left to Ctrl + Alt + Delete) */
      c = c >= 0x80 ? (UNI | c) : c;
    else
      c = keymap_translate(key);
    extended = 0;
    outportb(0x20, 0x20);
    /* Shift + Page Up / Page Down: the scrollback, in every mode */
    if ((c == KEY_PGUP || c == KEY_PGDN) && (control_keys & CK_SHIFT)) {
      mynos_P(input_lock);
      raw_write(c == KEY_PGUP ? "\033[?1v" : "\033[?2v", 5);
      looking_back = 1;
      mynos_V(input_lock);
      continue;
    }
    if (c != 0)
      input(c);
  }
  return NULL;
}

/* ---- the second serial port: a terminal's bytes ---- */

#define COM2 0x2F8

/* is there a UART at COM2? its scratch register keeps what is written */
static int serial_present(void)
{
  if (inportb(COM2 + 5) == 0xFF) return 0;
  outportb(COM2 + 7, 0x5A);
  if (inportb(COM2 + 7) != 0x5A) return 0;
  outportb(COM2 + 7, 0xA5);
  return inportb(COM2 + 7) == 0xA5;
}

static void * serial_thread(void * arg)
{
  int irq = (int)arg;
  int esc = 0, param = 0, last_cr = 0;
  unsigned int u = 0;
  int u_left = 0;
  while (1) {
    int budget = 4096;                 /* never spin on a port gone wrong */
    mynos_P(irq);
    while (budget-- > 0 && inportb(COM2 + 5) != 0xFF && (inportb(COM2 + 5) & 1)) {
      unsigned char b = inportb(COM2);
      if (!canon) {                    /* raw: as the terminal sends them */
	char ch = (char)b;
	mynos_P(input_lock);
	queue_input(&ch, 1, 0);
	if (echo && (b >= ' ' && b != 0x7F)) raw_write(&ch, 1);
	mynos_V(input_lock);
	continue;
      }
      /* line editing: escape sequences, UTF-8, Enter, Backspace */
      if (esc == 1) { esc = (b == '[' || b == 'O') ? 2 : 0; param = 0; continue; }
      if (esc == 2) {
	if (b >= '0' && b <= '9') { param = param * 10 + b - '0'; continue; }
	esc = 0;
	if (b == 'A') input(KEY_UP);
	else if (b == 'B') input(KEY_DOWN);
	continue;                      /* others: not for line editing */
      }
      if (u_left > 0) {
	if ((b & 0xC0) == 0x80) {
	  u = (u << 6) | (b & 0x3F);
	  if (--u_left == 0 && u >= 0x80) input(UNI | u);
	  continue;
	}
	u_left = 0;
      }
      if (b == 0x1B) esc = 1;
      else if ((b & 0xE0) == 0xC0) { u = b & 0x1F; u_left = 1; }
      else if ((b & 0xF0) == 0xE0) { u = b & 0x0F; u_left = 2; }
      else if (b >= 0x80) ;            /* longer or broken: dropped */
      else if (b == '\r') input('\n');
      else if (b == '\n') { if (!last_cr) input('\n'); }
      else if (b == 0x7F || b == 0x08) input(0x08);
      else input(b);
      last_cr = b == '\r';
    }
    outportb(0x20, 0x20);
  }
  return NULL;
}

/* take up to n bytes of queued input; 0 = end of file, or no input
   within timeout_ms (if > 0) */
static int take_input(char * buf, int n, int timeout_ms)
{
  int got, waited = 0;
 again:
  if (timeout_ms > 0) {
    while (mynos_tryP(available) != 0) {
      if (waited >= timeout_ms) return 0;
      mynos_sleep(10000);
      waited += 10;
    }
  } else
    mynos_P(available);
  mynos_P(lock);
  /* every piece of input V'd `available`, and a read takes them all at
     once: the V's of what an earlier read took wake us to an empty queue
     (a burst of bytes from the serial port, a paste). Not an end of file:
     wait again */
  if (queue_len == 0 && !eof_pending) {
    mynos_V(lock);
    goto again;
  }
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
  input_lock = mynos_initSem(1);
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

  /* COM2: interrupts when a byte comes (the kernel writes to it, polling).
     Only if there is one: a missing port reads 0xFF, "a byte waiting"
     forever (QEMU with its window has COM1 only) */
  irq = serial_present() ? mynos_driverRegister("serial2", 3, NULL, NULL)
                         : MYNOS_ERR_INVALID;
  if (irq >= 0) {
    int i;
    for (i = 0; i < 64 && (inportb(COM2 + 5) & 1); i++) inportb(COM2);
    outportb(COM2 + 1, 0x01);          /* receive interrupts */
    outportb(COM2 + 4, 0x0B);          /* DTR, RTS, OUT2 (the IRQ line) */
    mynos_enableIrq(3);
    stack = malloc(0x4000);
    mynos_threadCreate(serial_thread, (void *)irq, stack + 0x4000, 0);
  } else
    mynos_log("consoled: no serial input (%d)\n", irq);

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
	keymap_sync();
	n = take_input(buf, req.len,
		       (!canon && vmin == 0 && vtime > 0) ? vtime * 100 : 0);
	mynos_send(channel, buf, n, 0);
      } else if (req.op == CONSOLE_KEYMAP) {
	char l;
	if (req.mode == CONSOLE_LAYOUT_US || req.mode == CONSOLE_LAYOUT_IT) {
	  layout = req.mode;
	  keymap_saved = 0;
	}
	l = (char)layout;
	mynos_send(channel, &l, 1, 0);
	keymap_sync();
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
