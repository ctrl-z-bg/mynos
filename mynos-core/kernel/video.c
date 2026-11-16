/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/

#include "video.h"
#include "io.h"
#include "kutils.h"

/* void update_cursor(int row, int col)
 * by Dark Fiber
 * taken from alt.os.development FAQ
 */
static void update_cursor(uint32_t row, uint32_t col)
{
  ushort16_t position=(row*80) + col;
  
  // cursor LOW port to vga INDEX register
  outportb(0x3D4, 0x0F);
  outportb(0x3D5, (ubyte_t)(position&0xFF));
  // cursor HIGH port to vga INDEX register
  outportb(0x3D4, 0x0E);
  outportb(0x3D5, (ubyte_t)((position>>8)&0xFF));
}

/* to print a digit */
#define ZERO 48

/* to convert a number to a string */
#define MAX_INT_LEN 11


/* Kernel messages (printk) are written to the log port and, while this is
   set, on the screen. It is cleared once user space is started, unless the
   kernel command line says "verbose": the screen then belongs to the
   programs (the shell). Programs' output (write) is always shown. */
int kernel_on_screen = 1;


void printk(char * s) {
  while (*s) {
    print_char(*(s++));
  }
}

void print_long(long32_t n) {
  if (n < 0) {
    print_char('-');
    n = -n;
  }
  print_ulong((ulong32_t)n);
}

void print_ulong(ulong32_t n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  tmp = n;
  do {
    q = tmp / 10;
    r = tmp % 10;
    *curr_char = r + ZERO;
    curr_char--;
    tmp = q;
  } while (q);

  printk(curr_char + 1);
}
 
void print_ulong_hex(ulong32_t n) {
  char s[MAX_INT_LEN];
  char * curr_char;
  ulong32_t q;      /* quotient */
  ulong32_t r;      /* rest */
  ulong32_t tmp;

  s[MAX_INT_LEN - 1] = '\0';
  curr_char = s + MAX_INT_LEN - 2;

  printk("0x");
  tmp = n;
  do {
    q = tmp / 16;
    r = tmp % 16;
    if (r < 10)
      *curr_char = r + ZERO;
    else
      *curr_char = (r - 10) + 65;

    curr_char--;
    tmp = q;
  } while (q);

  printk(curr_char + 1);
}
 
/* Every character printed on screen is also sent to the second serial port
   (COM2, 0x2F8), so that a headless QEMU can log the console to a file
   (tools/run-tests.sh). COM1 is left to the seriald service. */
#define LOG_PORT 0x2F8

static void log_char(char c) {
  static int initialized = 0;
  if (!initialized) {
    outportb(LOG_PORT + 1, 0x00);    /* no interrupts */
    outportb(LOG_PORT + 3, 0x80);    /* DLAB on */
    outportb(LOG_PORT + 0, 0x01);    /* 115200 baud */
    outportb(LOG_PORT + 1, 0x00);
    outportb(LOG_PORT + 3, 0x03);    /* 8N1, DLAB off */
    initialized = 1;
  }
  while (!(inportb(LOG_PORT + 5) & 0x20))   /* transmitter empty */
    ;
  outportb(LOG_PORT, c);
}

/* ---- the screen: a VT100-like terminal ----
   Programs' output (write) goes through a small terminal emulator: the
   control characters and the ANSI/VT100 escape sequences that text user
   interfaces use (cursor moves, erasing, colours, an alternate screen).
   Kernel messages are written plainly, in their own colour. */

#define CELL(r, c) ((char *)BASE_VIDEO + 2 * ((r) * COLUMNS + (c)))

static int row = 0, col = 0;          /* the cursor */
static int wrap_pending = 0;          /* the last column was written */
static int saved_row = 0, saved_col = 0;
static int cursor_on = 1;

/* attribute of programs' text: VGA colours, from SGR */
static int fg = 7, bg = 0, bold = 0, reverse = 0;
static char attr = CHAR_USER_ATTRIB;

/* escape sequence parser */
static int esc_state = 0;             /* 0: text, 1: after ESC, 2: CSI */
static int params[8], nparams, private_mark;

/* the screen saved by the alternate screen (CSI ?1049h / ?47h) */
static char saved_screen[2 * COLUMNS * ROWS];
static int saved_screen_row, saved_screen_col, on_alternate = 0;

static void show_cursor(void)
{
  if (cursor_on) update_cursor(row, col);
  else update_cursor(ROWS, 0);        /* off the screen */
}

static void erase(int r, int c0, int c1)    /* row r, columns c0..c1-1 */
{
  int c;
  for (c = c0; c < c1; c++) {
    *CELL(r, c) = ' ';
    *(CELL(r, c) + 1) = attr;
  }
}

static void scroll_up(int top, int n)       /* lines top.. move up by n */
{
  int r;
  for (r = top; r < ROWS; r++) {
    if (r + n < ROWS) kmemcpy(CELL(r, 0), CELL(r + n, 0), 2 * COLUMNS);
    else erase(r, 0, COLUMNS);
  }
}

static void scroll_down(int top, int n)     /* lines top.. move down by n */
{
  int r;
  for (r = ROWS - 1; r >= top; r--) {
    if (r - n >= top) kmemcpy(CELL(r, 0), CELL(r - n, 0), 2 * COLUMNS);
    else erase(r, 0, COLUMNS);
  }
}

static void newline(void)
{
  col = 0;
  wrap_pending = 0;
  if (++row >= ROWS) {
    scroll_up(0, 1);
    row = ROWS - 1;
  }
}

static void put(char c, char a)
{
  if (wrap_pending) newline();
  *CELL(row, col) = c;
  *(CELL(row, col) + 1) = a;
  if (col == COLUMNS - 1) wrap_pending = 1;
  else col++;
}

/* control characters common to kernel and programs' text */
static int control(char c)
{
  switch (c) {
  case '\n': newline(); return 1;
  case '\r': col = 0; wrap_pending = 0; return 1;
  case '\b': if (col > 0) col--; wrap_pending = 0; return 1;
  case '\t':
    col = (col + 8) & ~7;
    if (col >= COLUMNS) col = COLUMNS - 1;
    return 1;
  case '\a': return 1;
  }
  return 0;
}

static void update_attr(void)
{
  int f = fg | (bold ? 8 : 0), b = bg;
  if (reverse) { int t = f & 7; f = b | (f & 8); b = t; }
  attr = (char)((b << 4) | f);
}

static void sgr(void)
{
  /* ANSI colour number -> VGA colour */
  static const int vga[8] = { 0, 4, 2, 6, 1, 5, 3, 7 };
  int i;
  if (nparams == 0) params[nparams++] = 0;
  for (i = 0; i < nparams; i++) {
    int p = params[i];
    if (p == 0) { fg = 7; bg = 0; bold = 0; reverse = 0; }
    else if (p == 1) bold = 1;
    else if (p == 22) bold = 0;
    else if (p == 7) reverse = 1;
    else if (p == 27) reverse = 0;
    else if (p >= 30 && p <= 37) fg = vga[p - 30];
    else if (p == 39) fg = 7;
    else if (p >= 40 && p <= 47) bg = vga[p - 40];
    else if (p == 49) bg = 0;
    else if (p >= 90 && p <= 97) fg = vga[p - 90] | 8;
    else if (p >= 100 && p <= 107) bg = vga[p - 100];
  }
  update_attr();
}

static int param(int i, int dflt)
{
  return (i < nparams && params[i] > 0) ? params[i] : dflt;
}

static void alternate(int on)
{
  if (on && !on_alternate) {
    kmemcpy(saved_screen, (char *)BASE_VIDEO, sizeof(saved_screen));
    saved_screen_row = row;
    saved_screen_col = col;
    on_alternate = 1;
    {                                 /* the alternate screen starts clear */
      int r;
      for (r = 0; r < ROWS; r++) erase(r, 0, COLUMNS);
      row = col = 0;
    }
  } else if (!on && on_alternate) {
    kmemcpy((char *)BASE_VIDEO, saved_screen, sizeof(saved_screen));
    row = saved_screen_row;
    col = saved_screen_col;
    on_alternate = 0;
  }
}

static void csi(char final)
{
  int n = param(0, 1), r, c;
  wrap_pending = 0;
  if (private_mark) {                 /* CSI ? ... h / l */
    int on = final == 'h';
    if (final != 'h' && final != 'l') return;
    for (r = 0; r < nparams; r++) {
      if (params[r] == 25) cursor_on = on;
      if (params[r] == 1049 || params[r] == 47 || params[r] == 1047)
	alternate(on);
    }
    return;
  }
  switch (final) {
  case 'A': row -= n; break;
  case 'B': row += n; break;
  case 'C': col += n; break;
  case 'D': col -= n; break;
  case 'E': row += n; col = 0; break;
  case 'F': row -= n; col = 0; break;
  case 'G': col = n - 1; break;
  case 'd': row = n - 1; break;
  case 'H': case 'f': row = param(0, 1) - 1; col = param(1, 1) - 1; break;
  case 'J':
    switch (param(0, 0)) {
    case 0:
      erase(row, col, COLUMNS);
      for (r = row + 1; r < ROWS; r++) erase(r, 0, COLUMNS);
      break;
    case 1:
      for (r = 0; r < row; r++) erase(r, 0, COLUMNS);
      erase(row, 0, col + 1);
      break;
    default:
      for (r = 0; r < ROWS; r++) erase(r, 0, COLUMNS);
    }
    break;
  case 'K':
    switch (param(0, 0)) {
    case 0: erase(row, col, COLUMNS); break;
    case 1: erase(row, 0, col + 1); break;
    default: erase(row, 0, COLUMNS);
    }
    break;
  case 'L': scroll_down(row, n); break;
  case 'M': scroll_up(row, n); break;
  case 'P':                           /* delete n characters */
    for (c = col; c < COLUMNS; c++) {
      if (c + n < COLUMNS) {
	*CELL(row, c) = *CELL(row, c + n);
	*(CELL(row, c) + 1) = *(CELL(row, c + n) + 1);
      } else erase(row, c, c + 1);
    }
    break;
  case '@':                           /* insert n blanks */
    for (c = COLUMNS - 1; c >= col; c--) {
      if (c - n >= col) {
	*CELL(row, c) = *CELL(row, c - n);
	*(CELL(row, c) + 1) = *(CELL(row, c - n) + 1);
      } else erase(row, c, c + 1);
    }
    break;
  case 'X': erase(row, col, col + n < COLUMNS ? col + n : COLUMNS); break;
  case 'm': sgr(); break;
  case 's': saved_row = row; saved_col = col; break;
  case 'u': row = saved_row; col = saved_col; break;
  default: break;                     /* r (scroll region), n, ... */
  }
  if (row < 0) row = 0;
  if (row >= ROWS) row = ROWS - 1;
  if (col < 0) col = 0;
  if (col >= COLUMNS) col = COLUMNS - 1;
}

/* a character of a program's output */
static void term_char(char c)
{
  if (esc_state == 1) {               /* after ESC */
    esc_state = 0;
    if (c == '[') {
      esc_state = 2;
      nparams = 0;
      private_mark = 0;
      params[0] = 0;
    } else if (c == 'E') newline();               /* NEL: next line */
    else if (c == 'D') {                           /* IND: down, scrolling */
      if (row == ROWS - 1) scroll_up(0, 1); else row++;
    } else if (c == 'M') {                         /* RI: up, scrolling */
      if (row == 0) scroll_down(0, 1); else row--;
    } else if (c == '7') { saved_row = row; saved_col = col; }
    else if (c == '8') { row = saved_row; col = saved_col; }
    else if (c == 'c') { clear_screen(); fg = 7; bg = 0; bold = reverse = 0; update_attr(); }
    return;
  }
  if (esc_state == 2) {               /* CSI parameters, then the final */
    if (c >= '0' && c <= '9') {
      if (nparams == 0) nparams = 1;
      params[nparams - 1] = params[nparams - 1] * 10 + (c - '0');
    } else if (c == ';') {
      if (nparams == 0) nparams = 1;
      if (nparams < 8) params[nparams++] = 0;
    } else if (c == '?' || c == '>' || c == '=') {
      private_mark = 1;
    } else if (c >= 0x40 && c <= 0x7E) {
      esc_state = 0;
      csi(c);
    }
    return;
  }
  if (c == 0x1B) { esc_state = 1; return; }
  if (!control(c) && (unsigned char)c >= ' ') put(c, attr);
}

void _print_char(char c, char attrib) {
  log_char(c);
  if (attrib == CHAR_KERNEL_ATTRIB) {
    if (!kernel_on_screen)
      return;
    if (!control(c)) put(c, attrib);
  } else
    term_char(c);
  show_cursor();
}

void clear_screen() {
  int r;
  for (r = 0; r < ROWS; r++) erase(r, 0, COLUMNS);
  row = col = 0;
  wrap_pending = 0;
  show_cursor();
}

void scroll_screen() {
  scroll_up(0, 1);
}
