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
#include "mem/mem.h"
#include "mynos.h"

/* void update_cursor(int row, int col)
 * by Dark Fiber
 * taken from alt.os.development FAQ
 */
#ifdef ARCH_TEXT_ON_FB
void arch_text_sync(const unsigned char * cells, int row, int col);
#endif
static void update_cursor(uint32_t row, uint32_t col)
{
#ifdef ARCH_TEXT_ON_FB
  /* no text mode: the cells drawn on a framebuffer (a Raspberry Pi's) */
  arch_text_sync((const unsigned char *)BASE_VIDEO, (int)row, (int)col);
#endif
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

/* ---- characters: UTF-8 in, code page 437 on screen ----
   (doc/decisions/console.md) Programs write UTF-8; each character is shown
   with the glyph of VGA's font (code page 437) that draws it. Six glyphs
   MyNOS has no use for are redrawn at boot (video_font_init) as the
   letters the font lacks: their slots below hold the new characters. */

/* the characters of glyphs 0x80-0xFF */
static const ushort16_t cp437_high[128] = {
  0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7,
  0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
  0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9,
  0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0xC0 /* was U+20A7 */, 0xC8 /* was ƒ */,
  0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA,
  0xBF, 0xCC /* was U+2310 */, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x3B1, 0xDF, 0x393, 0x3C0, 0x3A3, 0x3C3, 0xB5, 0x3C4,
  0x3A6, 0x398, 0x3A9, 0x3B4, 0x221E, 0x3C6, 0x3B5, 0x2229,
  0x2261, 0xB1, 0x2265, 0x2264, 0xD2 /* was U+2320 */, 0xD9 /* was U+2321 */, 0xF7, 0x2248,
  0xB0, 0x20AC /* was U+2219 */, 0xB7, 0x221A, 0x207F, 0xB2, 0x25A0, 0xA0
};

/* the characters of glyphs 0x01-0x1F (shown as glyphs, not as control
   characters, when they come as UTF-8) */
static const ushort16_t cp437_low[32] = {
  0, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022,
  0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
  0x25BA, 0x25C4, 0x2195, 0x203C, 0xB6, 0xA7, 0x25AC, 0x21A8,
  0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC
};

/* Latin-1 letters without a glyph: the letter without its accent */
static const char latin1_base[] =
  "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYTsaaaaaaaceeeeiiiidnooooo/ouuuuyty";

static unsigned char glyph_of(ulong32_t u)
{
  int i;
  if (u < 0x80) return (unsigned char)u;
  for (i = 0; i < 128; i++) if (cp437_high[i] == u) return 0x80 + i;
  for (i = 1; i < 32; i++) if (cp437_low[i] == u) return i;
  if (u == 0x2302) return 0x7F;
  if (u >= 0xC0 && u <= 0xFF) return latin1_base[u - 0xC0];
  switch (u) {
  case 0x2018: case 0x2019: case 0x201A: case 0x2032: return '\'';
  case 0x201C: case 0x201D: case 0x201E: case 0x2033: return '"';
  case 0x2010: case 0x2011: case 0x2012: case 0x2013: case 0x2014:
  case 0x2212: return '-';
  case 0x2026: return '.';
  case 0x2039: return '<';
  case 0x203A: return '>';
  case 0x2192: return 0x1A;
  case 0x2713: case 0x2714: return 0xFB;    /* check marks: the root */
  }
  return '?';
}

/* the character a slot's glyph draws (the drawing of the console on a
   framebuffer: arch/aarch64/fbcon.c) */
ulong32_t video_glyph_char(unsigned char slot)
{
  if (slot >= 0x80) return cp437_high[slot - 0x80];
  if (slot < 0x20) return cp437_low[slot];
  if (slot == 0x7F) return 0x2302;
  return slot;
}

/* the UTF-8 decoder of programs' output */
static ulong32_t utf8_char;
static int utf8_left = 0;

/* ---- the font: the six redrawn glyphs ---- */

#define FONT ((volatile unsigned char *)0xA0000)   /* plane 2: 32 bytes a glyph */

static void font_access(int on)
{
  static const unsigned char seq_on[] = { 0x00, 0x01, 0x02, 0x04, 0x04, 0x07, 0x00, 0x03 };
  static const unsigned char seq_off[] = { 0x00, 0x01, 0x02, 0x03, 0x04, 0x03, 0x00, 0x03 };
  static const unsigned char gc_on[] = { 0x04, 0x02, 0x05, 0x00, 0x06, 0x04 };
  static const unsigned char gc_off[] = { 0x04, 0x00, 0x05, 0x10, 0x06, 0x0E };
  const unsigned char * s = on ? seq_on : seq_off, * g = on ? gc_on : gc_off;
  int i;
  for (i = 0; i < 8; i += 2) { outportb(0x3C4, s[i]); outportb(0x3C5, s[i + 1]); }
  for (i = 0; i < 6; i += 2) { outportb(0x3CE, g[i]); outportb(0x3CF, g[i + 1]); }
}

/* a capital with a grave accent: the letter one row lower, the accent on
   the two rows above it */
static void grave_capital(unsigned char slot, char base)
{
  int r;
  for (r = 15; r >= 1; r--) FONT[32 * slot + r] = FONT[32 * base + r - 1];
  FONT[32 * slot + 0] = 0x30;
  FONT[32 * slot + 1] = 0x18;
}

void video_font_init(void)
{
  static const unsigned char euro[16] =
    { 0x00, 0x00, 0x1C, 0x36, 0x62, 0x60, 0xFC, 0x60,
      0xF8, 0x60, 0x62, 0x36, 0x1C, 0x00, 0x00, 0x00 };
  int r;
  font_access(1);
  grave_capital(0x9E, 'A');
  grave_capital(0x9F, 'E');
  grave_capital(0xA9, 'I');
  grave_capital(0xF4, 'O');
  grave_capital(0xF5, 'U');
  for (r = 0; r < 16; r++) FONT[32 * 0xF9 + r] = euro[r];
  font_access(0);
}

/* ---- scrollback (doc/decisions/console.md) ----
   The lines scrolled off the top of the main screen, the last SB_LINES of
   them. While one looks back (view > 0 lines), the live screen is kept in
   live[] and the screen shows older lines; any output brings it back. */

#define SB_LINES 500
static char sb[SB_LINES][2 * COLUMNS];
static int sb_count = 0, sb_next = 0;     /* lines kept, the next slot */
static int view = 0;
static char live[2 * COLUMNS * ROWS];

static void sb_push(int r)
{
  kmemcpy(sb[sb_next], CELL(r, 0), 2 * COLUMNS);
  sb_next = (sb_next + 1) % SB_LINES;
  if (sb_count < SB_LINES) sb_count++;
}

static void view_set(int v);

static void show_cursor(void)
{
  if (cursor_on) update_cursor(row, col);
  else update_cursor(ROWS, 0);        /* off the screen */
}

static void view_set(int v)
{
  int r;
  if (on_alternate) v = 0;
  if (v > sb_count) v = sb_count;
  if (v < 0) v = 0;
  if (v == view) return;
  if (view == 0) kmemcpy(live, (char *)BASE_VIDEO, sizeof(live));
  view = v;
  if (v == 0) {
    kmemcpy((char *)BASE_VIDEO, live, sizeof(live));
    show_cursor();
    return;
  }
  for (r = 0; r < ROWS; r++) {
    int k = r - v;                    /* < 0: k lines above the live screen */
    kmemcpy(CELL(r, 0),
	    k >= 0 ? live + 2 * COLUMNS * k : sb[(sb_next + k + SB_LINES) % SB_LINES],
	    2 * COLUMNS);
  }
  {                                   /* where we are, top right */
    char tag[12];
    int n = 0, c, x = v;
    char digits[8];
    int nd = 0;
    tag[n++] = '[';
    tag[n++] = '-';
    do { digits[nd++] = '0' + x % 10; x /= 10; } while (x && nd < 7);
    while (nd) tag[n++] = digits[--nd];
    tag[n++] = ']';
    for (c = 0; c < n; c++) {
      *CELL(0, COLUMNS - n + c) = tag[c];
      *(CELL(0, COLUMNS - n + c) + 1) = 0x70;
    }
  }
  update_cursor(ROWS, 0);             /* no cursor while looking back */
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
  if (top == 0 && !on_alternate)
    for (r = 0; r < n && r < ROWS; r++) sb_push(r);
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
  if (private_mark && final == 'v') {  /* consoled: the scrollback */
    switch (param(0, 0)) {
    case 1: view_set(view + ROWS - 1); break;
    case 2: view_set(view - (ROWS - 1)); break;
    default: view_set(0);
    }
    return;
  }
  if (view) view_set(0);
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
  if (c == 0x1B) { utf8_left = 0; esc_state = 1; return; }
  if (c == 0) return;                 /* NUL: nothing to show */
  if (view) view_set(0);
  {
    unsigned char b = (unsigned char)c;
    if (utf8_left > 0) {
      if ((b & 0xC0) == 0x80) {
	utf8_char = (utf8_char << 6) | (b & 0x3F);
	if (--utf8_left == 0) put((char)glyph_of(utf8_char), attr);
	return;
      }
      utf8_left = 0;                  /* a cut character */
      put('?', attr);
    }
    if (b >= 0x80) {
      if ((b & 0xE0) == 0xC0) { utf8_char = b & 0x1F; utf8_left = 1; }
      else if ((b & 0xF0) == 0xE0) { utf8_char = b & 0x0F; utf8_left = 2; }
      else if ((b & 0xF8) == 0xF0) { utf8_char = b & 0x07; utf8_left = 3; }
      else put('?', attr);            /* not UTF-8 */
      return;
    }
  }
  if (!control(c) && (unsigned char)c >= ' ') put(c, attr);
}

/* ---- the kernel's log: its messages (printk, the log call), kept in a
   ring for programs to read (native call 35: log, the Log window). A
   position counts every byte ever logged; the ring holds the last
   KLOG_SIZE of them. */
#define KLOG_SIZE 65536
static char klog[KLOG_SIZE];
static uint32_t klog_total = 0;

/* klog(from, buf, max): buf NULL, the position now; otherwise the logged
   bytes from position `from` (or the oldest kept, if `from` is older),
   at most max: how many */
int _mynos_syscall_klog(uint32_t from, char * buf, uint32_t max) {
  uint32_t oldest = klog_total > KLOG_SIZE ? klog_total - KLOG_SIZE : 0, n, i;
  if (buf == NULL) return (int)klog_total;
  if (from < oldest) from = oldest;
  if (from >= klog_total) return 0;
  n = klog_total - from;
  if (n > max) n = max;
  if (!__mem_userArea(buf, n)) return MYNOS_ERR_INVALID;
  for (i = 0; i < n; i++) buf[i] = klog[(from + i) % KLOG_SIZE];
  return (int)n;
}

void _print_char(char c, char attrib) {
  log_char(c);
  if (attrib == CHAR_KERNEL_ATTRIB) {
    klog[klog_total % KLOG_SIZE] = c;
    klog_total++;
    if (!kernel_on_screen)
      return;
    if (view) view_set(0);
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
