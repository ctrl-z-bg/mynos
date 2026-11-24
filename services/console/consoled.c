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
 * line being typed (echo, Backspace and Delete, the cursor moved with Left,
 * Right, Home and End or Ctrl-A and Ctrl-E, Ctrl-D for end of file) and gives
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
 * that set it, and a read from another process ends it. With
 * CONSOLE_RELEASES (raw mode, displayd) a key's release follows it, as a
 * sequence of kitty's keyboard protocol: the graphical session's windows
 * know which keys are held.
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
#include <mynos_wire.h>
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
/* an arrow, Home or End with Shift (selecting text: ESC [ 1 ; 2 A...) */
#define SHIFTED 0x2000000

/* the line being edited (keyboard thread only), and the cursor in it
   (a byte offset, at the start of a character) */
static char line[LINE_MAX];
static int line_len = 0;
static int cur = 0;

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
static int isig = 1;          /* Ctrl-C ends the foreground program */
static int releases = 0;      /* raw mode: key releases too (CONSOLE_RELEASES) */
static int foreground = 0;    /* the program a shell waits for (CONSOLE_FOREGROUND) */

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

/* the cursor back over n cells (Backspace moves it, erasing nothing) */
static void cursor_back(int n)
{
  static char back[LINE_MAX + 1];
  if (n <= 0) return;
  memset(back, '\b', n);
  raw_write(back, n);
}

/* the line from the cursor on drawn again, with `blank` cells cleared
   after it (what a deletion left), and the cursor back in its place */
static void redraw_tail(int blank)
{
  raw_write(line + cur, line_len - cur);
  raw_write("  ", blank);
  cursor_back(cells(line + cur, line_len - cur) + blank);
}

/* the character before or after the cursor: its first byte */
static int char_before(int i)
{
  if (i > 0) i--;
  while (i > 0 && (line[i] & 0xC0) == 0x80) i--;
  return i;
}
static int char_after(int i)
{
  if (i < line_len) i++;
  while (i < line_len && (line[i] & 0xC0) == 0x80) i++;
  return i;
}

/* text typed at the cursor: inserted, the rest of the line moved on */
static void insert(const char * s, int n)
{
  if (line_len + n >= LINE_MAX - 1) return;
  memmove(line + cur + n, line + cur, line_len - cur);
  memcpy(line + cur, s, n);
  line_len += n;
  raw_write(s, n);
  cur += n;
  if (cur < line_len) redraw_tail(0);
}

/* the bytes from..to taken out of the line, the cursor at `from` (on
   screen it is there already) */
static void delete_range(int from, int to)
{
  if (to <= from) return;
  memmove(line + from, line + to, line_len - to);
  line_len -= to - from;
  cur = from;
  redraw_tail(1);
}

/* replace the line on screen and in the buffer */
static void show_line(const char * s, int n)
{
  static char erase[3 * LINE_MAX];
  int i, shown = cells(line, line_len);
  raw_write(line + cur, line_len - cur);      /* to the line's end first */
  for (i = 0; i < shown; i++) {
    erase[3 * i] = '\b';
    erase[3 * i + 1] = ' ';
    erase[3 * i + 2] = '\b';
  }
  raw_write(erase, 3 * shown);
  memcpy(line, s, n);
  line_len = n;
  cur = n;
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
  if (c & SHIFTED) {                   /* as xterm: the modifier 2 */
    switch (c & ~SHIFTED) {
    case KEY_UP:    seq = "\033[1;2A"; break;
    case KEY_DOWN:  seq = "\033[1;2B"; break;
    case KEY_RIGHT: seq = "\033[1;2C"; break;
    case KEY_LEFT:  seq = "\033[1;2D"; break;
    case KEY_HOME:  seq = "\033[1;2H"; break;
    case KEY_END:   seq = "\033[1;2F"; break;
    }
    if (seq) queue_input(seq, strlen(seq), 0);
    return;
  }
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

/* ---- key releases (CONSOLE_RELEASES), queued under input_lock ---- */

/* ESC [ num ; mod:3 final, without the C library (the keyboard thread) */
static void queue_release_mod(unsigned int num, int mod, char final)
{
  char s[24], digits[12];
  int n = 0, d = 0;
  s[n++] = '\033';
  s[n++] = '[';
  do { digits[d++] = '0' + num % 10; num /= 10; } while (num > 0);
  while (d > 0) s[n++] = digits[--d];
  s[n++] = ';';
  s[n++] = '0' + mod;
  s[n++] = ':';
  s[n++] = '3';
  s[n++] = final;
  queue_input(s, n, 0);
}

static void queue_release(unsigned int num, char final)
{
  queue_release_mod(num, 1, final);
}

/* the release of a key whose press was c (as raw_key got it) */
static void release_key(unsigned int c)
{
  if (canon || !releases) return;
  if (c & SHIFTED) {
    switch (c & ~SHIFTED) {
    case KEY_UP:    queue_release_mod(1, 2, 'A'); return;
    case KEY_DOWN:  queue_release_mod(1, 2, 'B'); return;
    case KEY_RIGHT: queue_release_mod(1, 2, 'C'); return;
    case KEY_LEFT:  queue_release_mod(1, 2, 'D'); return;
    case KEY_HOME:  queue_release_mod(1, 2, 'H'); return;
    case KEY_END:   queue_release_mod(1, 2, 'F'); return;
    }
    return;
  }
  switch (c) {
  case KEY_UP:     queue_release(1, 'A'); return;
  case KEY_DOWN:   queue_release(1, 'B'); return;
  case KEY_RIGHT:  queue_release(1, 'C'); return;
  case KEY_LEFT:   queue_release(1, 'D'); return;
  case KEY_HOME:   queue_release(1, 'H'); return;
  case KEY_END:    queue_release(1, 'F'); return;
  case KEY_PGUP:   queue_release(5, '~'); return;
  case KEY_PGDN:   queue_release(6, '~'); return;
  case KEY_INSERT: queue_release(2, '~'); return;
  case KEY_DELETE: queue_release(3, '~'); return;
  }
  if (c & UNI) queue_release(c & ~UNI, 'u');
  else if (c <= 0xFF)
    queue_release(c == '\n' ? '\r' : c == 0x08 ? 0x7F : c, 'u');
}

/* the serial port's keys in raw mode come as bytes: a key is whole at
   the end of a character (UTF-8) or of a sequence (ESC [ ... final),
   and a terminal sends no releases: each key is released at once */
static void serial_release(unsigned char b)
{
  static char seq[16];
  static int seq_len = 0, utf_left = 0;
  static unsigned int code = 0;
  if (canon || !releases) { seq_len = utf_left = 0; return; }
  if (seq_len > 0) {
    if (seq_len < (int)sizeof seq) seq[seq_len++] = b;
    if (seq_len == 2 && b != '[') {              /* ESC and a key: Alt */
      seq_len = 0;
      return;
    }
    if (seq_len > 2 && b >= 0x40 && b <= 0x7E) { /* the final byte */
      int num = 0, i;
      for (i = 2; i < seq_len - 1 && seq[i] >= '0' && seq[i] <= '9'; i++)
        num = num * 10 + seq[i] - '0';
      if (b == '~') queue_release(num, '~');
      else if (seq_len == 3 && b >= 'A' && b <= 'H') queue_release(1, b);
      seq_len = 0;
    }
    return;
  }
  if (utf_left > 0) {
    code = (code << 6) | (b & 0x3F);
    if (--utf_left == 0) queue_release(code, 'u');
    return;
  }
  if (b == 0x1B) { seq[0] = b; seq_len = 1; }
  else if ((b & 0xE0) == 0xC0) { code = b & 0x1F; utf_left = 1; }
  else if ((b & 0xF0) == 0xE0) { code = b & 0x0F; utf_left = 2; }
  else if ((b & 0xF8) == 0xF0) { code = b & 0x07; utf_left = 3; }
  else if (b < 0x80) queue_release(b, 'u');
}

static void key_typed(unsigned int c)
{
  if (!canon) {
    raw_key(c);
    return;
  }
  c &= ~SHIFTED;                       /* line editing: an arrow is an arrow */
  if (c == KEY_UP || c == CTRL_P) {
    history_move(-1);
  } else if (c == KEY_DOWN || c == CTRL_N) {
    history_move(+1);
  } else if (c == KEY_LEFT) {         /* the cursor along the line */
    if (cur > 0) { cur = char_before(cur); raw_write("\b", 1); }
  } else if (c == KEY_RIGHT) {
    int to = char_after(cur);
    raw_write(line + cur, to - cur);
    cur = to;
  } else if (c == KEY_HOME || c == 0x01) {   /* Home, Ctrl-A */
    cursor_back(cells(line, cur));
    cur = 0;
  } else if (c == KEY_END || c == 0x05) {    /* End, Ctrl-E */
    raw_write(line + cur, line_len - cur);
    cur = line_len;
  } else if (c == '\n' || c == '\r') {
    raw_write("\n", 1);
    history_add();
    hist_pos = hist_count;
    line[line_len++] = '\n';
    queue_input(line, line_len, 0);
    line_len = cur = 0;
  } else if (c == 0x08) {              /* backspace: a whole character */
    if (cur > 0) {
      int from = char_before(cur);
      raw_write("\b", 1);
      delete_range(from, cur);
    }
  } else if (c == KEY_DELETE) {        /* the character under the cursor */
    delete_range(cur, char_after(cur));
  } else if (c & UNI) {
    char u[4];
    insert(u, utf8_encode(c & ~UNI, u));
  } else if (c == 0x04) {              /* Ctrl-D */
    if (line_len == 0)
      queue_input("", 0, 1);           /* end of file */
    else {
      queue_input(line, line_len, 0);  /* flush the partial line */
      line_len = cur = 0;
    }
  } else if (c >= 0x20 && c < 0x7F) {
    char ch = (char)c;
    insert(&ch, 1);
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
  if (c == 0x03 && isig && foreground > 0) {
    /* Ctrl-C: an interrupt. The program the shell waits for ends (MyNOS
       has no signals: it is killed); what was typed for it is dropped */
    int pid = foreground;
    foreground = 0;
    raw_write("^C\n", 3);
    line_len = cur = 0;
    mynos_P(lock);
    queue_len = 0;
    mynos_V(lock);
    mynos_kill(pid);
    mynos_V(available);                /* a read it was waiting in ends */
  } else
    key_typed(c);
  mynos_V(input_lock);
}

/* a pid a caller may name as its foreground program: its child */
static int child_of(int pid, int parent)
{
  mynos_process_t ps[128];
  int n = mynos_processes(ps, 128), i;
  for (i = 0; i < n; i++)
    if (ps[i].pid == pid) return ps[i].ppid == parent;
  return 0;
}

/* what each key's press sent, by scan code (grey keys apart), for its
   release (keyboard thread only) */
static unsigned int pressed[2][128];

static void * keyboard_thread(void * arg)
{
  int irq = (int)arg;
  int extended = 0;
  while (1) {
    unsigned int key, c = 0;
    int ext;
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
    ext = extended;
    extended = 0;
    outportb(0x20, 0x20);
    if ((control_keys & CK_SHIFT) && (c == KEY_UP || c == KEY_DOWN || c == KEY_LEFT ||
                                      c == KEY_RIGHT || c == KEY_HOME || c == KEY_END))
      c |= SHIFTED;
    /* a key let go: its release, if its press sent something */
    if (key & 0x80) {
      unsigned int was = pressed[ext][key & 0x7F];
      pressed[ext][key & 0x7F] = 0;
      if (was) {
        mynos_P(input_lock);
        release_key(was);
        mynos_V(input_lock);
      }
      continue;
    }
    /* Shift + Page Up / Page Down: the scrollback, in every mode */
    if ((c == KEY_PGUP || c == KEY_PGDN) && (control_keys & CK_SHIFT)) {
      mynos_P(input_lock);
      raw_write(c == KEY_PGUP ? "\033[?1v" : "\033[?2v", 5);
      looking_back = 1;
      mynos_V(input_lock);
      continue;
    }
    if (c != 0) {
      /* held, the key repeats; if it now sends something else (Shift
         pressed meanwhile), what it sent before is released */
      unsigned int was = pressed[ext][key];
      if (was && was != c) {
        mynos_P(input_lock);
        release_key(was);
        mynos_V(input_lock);
      }
      pressed[ext][key] = c;
      input(c);
    }
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
	if (b == 0x03 && isig && foreground > 0) {   /* Ctrl-C, as a key */
	  input(0x03);
	  continue;
	}
	mynos_P(input_lock);
	queue_input(&ch, 1, 0);
	if (echo && (b >= ' ' && b != 0x7F)) raw_write(&ch, 1);
	serial_release(b);
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
	else if (b == 'C') input(KEY_RIGHT);
	else if (b == 'D') input(KEY_LEFT);
	else if (b == 'H' || (b == '~' && (param == 1 || param == 7))) input(KEY_HOME);
	else if (b == 'F' || (b == '~' && (param == 4 || param == 8))) input(KEY_END);
	else if (b == '~' && param == 3) input(KEY_DELETE);
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
/* the process whose read take_input is serving: if it ends meanwhile
   (Ctrl-C kills it), the read is given up, and the next line is not
   swallowed by a dead reader */
static int reader = 0;

static int reader_alive(void)
{
  int info = reader > 0 ? mynos_processInfo(reader) : 0;
  return reader <= 0 || (info >= 0 && (info & MYNOS_PROC_ALIVE));
}

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
    if (!reader_alive()) return -1;  /* woken by Ctrl-C: its reader is gone */
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

/* console/1 (mynos_console.h): its description, as module Console says it */
static const wire_request_doc requests[] = {
  { 0, "read", "max:I", "S",
    "Up to max bytes of input: a line in line mode, keys in raw mode; \"\" at the "
    "end of the input (Ctrl-D, a hang-up) or when VTIME passes." },
  { 0, "mode", "(mode:I,vmin:I,vtime:I)", "U",
    "The input mode: 1 line editing, 2 echo, 4 Ctrl-C is a key (not an interrupt), "
    "8 key releases too (raw mode: ESC [ code ; 1:3 u, or the key's own final); "
    "vmin and vtime as termios VMIN and VTIME (raw mode)." },
  { 0, "keymap", "layout:I", "I",
    "The keyboard layout: 0 us, 1 it (-1: unchanged); the one in use." },
  { 0, "write", "data:S", "U", "Output, to the screen." },
  { 0, "foreground", "pid:I", "U",
    "The program the caller waits for (one of its children; 0: none): Ctrl-C ends "
    "it." },
  { 1, "size", "U", "(cols:I,rows:I)",
    "The screen: its columns and rows (a terminal window's, as it is now)." },
  { 1, "ready", "U", "B",
    "Whether a read would answer at once: input, or its end, is waiting." },
};

static void describe(wire_writer * w)
{
  wire_reply_description(w, CONSOLE_PROTOCOL,
    "A console: the keyboard and the screen of programs (consoled, the text console; "
    "a terminal window's console). Line editing or keys one by one, echo, Ctrl-C.",
    requests, sizeof requests / sizeof requests[0]);
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
    static char buf[QUEUE_MAX];
    wire_reader r;
    wire_writer w;
    const char * id;
    unsigned int idlen;
    long long kind, a1 = 0, a2 = 0, a3 = 0;
    const char * data = NULL;
    unsigned int dlen = 0;
    int caller, n;

    if (channel < 0) continue;
    if (mynos_recv(channel, &msg, 0, 0) < 0) {
      mynos_freeChannel(channel);
      continue;
    }
    caller = mynos_channelPeer(channel);
    wire_writer_init(&w);
    wire_reader_init(&r, msg->start, msg->size);
    id = wire_get_string(&r, &idlen);
    kind = -1;
    if (!r.error && idlen == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, idlen)
        && wire_at_end(&r)) {
      describe(&w);
      goto reply;
    }
    if (!r.error && idlen == strlen(CONSOLE_PROTOCOL) && !memcmp(id, CONSOLE_PROTOCOL, idlen)) {
      kind = wire_get_int(&r);
      if (kind == CONSOLE_WRITE) data = wire_get_string(&r, &dlen);
      else if (kind == CONSOLE_MODE) {
        a1 = wire_get_int(&r); a2 = wire_get_int(&r); a3 = wire_get_int(&r);
      } else if (kind != CONSOLE_SIZE && kind != CONSOLE_READY) a1 = wire_get_int(&r);
      if (r.error || !wire_at_end(&r) || kind < CONSOLE_READ || kind > CONSOLE_READY)
        kind = -1;
    }
    if (kind < 0) {
      wire_reply_error(&w, "invalid: the console speaks " CONSOLE_PROTOCOL);
    } else if (kind == CONSOLE_READ) {
      int len = a1 < 0 ? 0 : a1 > (long long)sizeof(buf) ? (int)sizeof(buf) : (int)a1;
      if (!canon && caller != mode_owner) {
        canon = echo = 1;        /* its program is gone (or did not restore) */
        releases = 0;
        vmin = 1;
        vtime = 0;
        isig = 1;
      }
      history_sync();            /* a program is about to read: a good time */
      keymap_sync();
      reader = caller;
      n = take_input(buf, len, (!canon && vmin == 0 && vtime > 0) ? vtime * 100 : 0);
      reader = 0;
      if (n < 0) {                     /* its reader has ended */
        wire_writer_free(&w);
        mynos_freeMsg(&msg);
        mynos_freeChannel(channel);
        continue;
      }
      wire_reply_ok(&w);
      wire_put_string(&w, buf, n);
    } else if (kind == CONSOLE_KEYMAP) {
      if (a1 == CONSOLE_LAYOUT_US || a1 == CONSOLE_LAYOUT_IT) {
        layout = a1;
        keymap_saved = 0;
      }
      wire_reply_ok(&w);
      wire_put_int(&w, layout);
      keymap_sync();
    } else if (kind == CONSOLE_SIZE) {
      wire_reply_ok(&w);
      wire_put_int(&w, CONSOLE_COLS);
      wire_put_int(&w, CONSOLE_ROWS);
    } else if (kind == CONSOLE_READY) {
      int ready;
      mynos_P(lock);
      ready = queue_len > 0 || eof_pending;
      mynos_V(lock);
      wire_reply_ok(&w);
      wire_put_bool(&w, ready);
    } else if (kind == CONSOLE_FOREGROUND) {
      if (a1 == 0 || child_of(a1, caller)) foreground = a1;
      wire_reply_ok(&w);
    } else if (kind == CONSOLE_MODE) {
      canon = (a1 & CONSOLE_CANON) != 0;
      echo = (a1 & CONSOLE_ECHO) != 0;
      isig = !(a1 & CONSOLE_NOSIG);
      releases = !canon && (a1 & CONSOLE_RELEASES) != 0;
      vmin = a2;
      vtime = a3;
      mode_owner = caller;
      if (canon) line_len = cur = 0;
      wire_reply_ok(&w);
    } else {                     /* CONSOLE_WRITE: to the screen */
      if (dlen) write(1, data, dlen);
      wire_reply_ok(&w);
    }
  reply:
    if (!w.error) mynos_send(channel, w.buf, w.len, 0);
    wire_writer_free(&w);
    mynos_freeMsg(&msg);
    mynos_freeChannel(channel);
  }
  return 0;
}
