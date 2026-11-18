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
 * displayd: the display server (doc/decisions/gui.md).
 *
 * It waits in text mode until a client starts the graphical session
 * ("display/1": start, which the gui command sends). Then it sets QEMU's
 * VGA card to 1024 x 768 x 32 (the Bochs extension, BGA), and composes the
 * screen: the desktop with its top bar and menu, the windows with their
 * title bars, and the pointer. A window's pixels are a buffer of its
 * program, shared over IPC (MYNOS_IPC_SHARED): the program draws in it and
 * says what changed (damage); displayd copies it to the screen. Events
 * (keys, the mouse, close, ticks) wait in a queue per window for the
 * program's next_event.
 *
 * The visible picture starts 256 KB into the card's memory (its Y offset):
 * the first 256 KB are VGA's text-mode memory, the text console and its
 * font, which stay as they were for when the session ends.
 *
 * Input: the PS/2 mouse (IRQ 12), with QEMU's vmmouse for absolute
 * coordinates when it is there (no pointer capture); keys from the console
 * service, read in raw mode while the session lasts.
 *
 * Threads: requests (listener), the mouse, the keys, a timer (ticks, the
 * clock, windows of programs that ended); one lock for the state.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <time.h>
#include <mynos.h>
#include <mynos_wire.h>

#define SERVICE  "display"
#define PROTOCOL "display/1"
#define W 1024
#define H 768
#define TOP 24                         /* the top bar */
#define TITLE 22                       /* a window's title bar */
#define MAXWIN 32
#define MAXEV 64
#define FB_SKIP (256 * 1024)           /* VGA's text-mode memory: kept */
#define FONT "/terminus16.psf"
#define FONT_BOLD "/terminus16-bold.psf"

#define ARG(i) ((void *)(long)(i))
#define IDX(p) ((int)(long)(p))

/* ---- port I/O ---- */

static inline void outw(unsigned short port, unsigned short v)
{ __asm__ volatile ("outw %0, %1" : : "a"(v), "Nd"(port)); }
static inline unsigned short inw(unsigned short port)
{ unsigned short v; __asm__ volatile ("inw %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static inline void outl(unsigned short port, unsigned int v)
{ __asm__ volatile ("outl %0, %1" : : "a"(v), "Nd"(port)); }
static inline unsigned int inl(unsigned short port)
{ unsigned int v; __asm__ volatile ("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }

/* ---- the card ---- */

static unsigned int pci_read(int bus, int dev, int fn, int reg)
{
  outl(0xCF8, 0x80000000u | (bus << 16) | (dev << 11) | (fn << 8) | (reg & 0xFC));
  return inl(0xCFC);
}

/* QEMU's standard VGA (1234:1111): its frame buffer, the first BAR */
static unsigned long find_lfb(void)
{
  int dev;
  for (dev = 0; dev < 32; dev++)
    if (pci_read(0, dev, 0, 0) == 0x11111234)
      return pci_read(0, dev, 0, 0x10) & 0xFFFFFFF0;
  return 0;
}

static void bga(int index, int value) { outw(0x1CE, index); outw(0x1CF, value); }
static int bga_get(int index) { outw(0x1CE, index); return inw(0x1CF); }

static unsigned int * fb;              /* the visible picture */
static unsigned int * back;            /* composed here, then copied */

/* VGA's registers in text mode: saved before the graphical mode, put back
   after it (turning the Bochs extension off leaves them as it set them, a
   BIOS would set the text mode again) */
static unsigned char misc, seq[5], crtc[25], gc[9], ac[21];

static void vga_save(void)
{
  int i;
  misc = inportb(0x3CC);
  for (i = 0; i < 5; i++) { outportb(0x3C4, i); seq[i] = inportb(0x3C5); }
  for (i = 0; i < 25; i++) { outportb(0x3D4, i); crtc[i] = inportb(0x3D5); }
  for (i = 0; i < 9; i++) { outportb(0x3CE, i); gc[i] = inportb(0x3CF); }
  for (i = 0; i < 21; i++) {
    (void)inportb(0x3DA);
    outportb(0x3C0, i);
    ac[i] = inportb(0x3C1);
  }
  (void)inportb(0x3DA);
  outportb(0x3C0, 0x20);               /* the display on again */
}

static void vga_restore(void)
{
  int i;
  outportb(0x3C2, misc);
  for (i = 0; i < 5; i++) { outportb(0x3C4, i); outportb(0x3C5, seq[i]); }
  outportb(0x3D4, 0x11);               /* CRTC registers 0-7 writable */
  outportb(0x3D5, crtc[0x11] & 0x7F);
  for (i = 0; i < 25; i++) {
    outportb(0x3D4, i);
    outportb(0x3D5, i == 0x11 ? (crtc[i] & 0x7F) : crtc[i]);
  }
  outportb(0x3D4, 0x11);
  outportb(0x3D5, crtc[0x11]);
  for (i = 0; i < 9; i++) { outportb(0x3CE, i); outportb(0x3CF, gc[i]); }
  for (i = 0; i < 21; i++) {
    (void)inportb(0x3DA);
    outportb(0x3C0, i);
    outportb(0x3C0, ac[i]);
  }
  (void)inportb(0x3DA);
  outportb(0x3C0, 0x20);
}

static void mode_graphics(void)
{
  vga_save();
  bga(4, 0);                           /* disabled while it changes */
  bga(1, W);
  bga(2, H);
  bga(3, 32);
  bga(4, 0x01 | 0x40 | 0x80);          /* enabled, linear, memory kept */
  bga(8, 0);
  bga(9, FB_SKIP / (W * 4));           /* the picture starts past 256 KB */
}

static void mode_text(void) { bga(4, 0); vga_restore(); }

/* ---- the font (PSF 1, with a Unicode table) ---- */

static unsigned char glyphs[2][512 * 16];
static unsigned short glyph_of[65536];   /* 0xFFFF: none */
static int font_ok = 0;

static void load_font(int which, const char * path)
{
  static unsigned char data[16384];
  int fd = open(path, O_RDONLY), n, i, g, nglyphs, height;
  if (fd < 0) { mynos_log("displayd: no font %s\n", path); return; }
  n = read(fd, data, sizeof data);
  close(fd);
  if (n < 4 || data[0] != 0x36 || data[1] != 0x04) return;
  nglyphs = (data[2] & 1) ? 512 : 256;
  height = data[3];
  if (height != 16 || n < 4 + nglyphs * 16) return;
  memcpy(glyphs[which], data + 4, nglyphs * 16);
  if (which == 0 && (data[2] & 2)) {
    i = 4 + nglyphs * 16;
    for (g = 0; g < nglyphs && i + 1 < n; g++) {
      for (;;) {
	unsigned int u = data[i] | (data[i + 1] << 8);
	i += 2;
	if (u == 0xFFFF || i + 1 >= n) break;
	if (u == 0xFFFE) {                /* sequences: skipped */
	  while (i + 1 < n && (data[i] | (data[i + 1] << 8)) != 0xFFFF) i += 2;
	  continue;
	}
	if (glyph_of[u] == 0xFFFF) glyph_of[u] = g;
      }
    }
  }
  if (which == 0) font_ok = 1;
}

/* ---- the logo: a grey PGM (0 the ink), drawn faint on the desktop ---- */

#define LOGO "/mynos-logo-2x.pgm"
static unsigned char * logo;           /* NULL: none */
static int logo_w, logo_h;

static void load_logo(void)
{
  static char data[80000];
  int fd = open(LOGO, O_RDONLY), n, pos = 2, field[3], k;
  if (fd < 0) return;
  n = read(fd, data, sizeof data);
  close(fd);
  if (n < 2 || data[0] != 'P' || data[1] != '5') return;
  for (k = 0; k < 3; k++) {             /* width, height, maximum */
    while (pos < n && (data[pos] == ' ' || data[pos] == '\n' || data[pos] == '\r' ||
		       data[pos] == '\t' || data[pos] == '#'))
      if (data[pos] == '#') while (pos < n && data[pos] != '\n') pos++;
      else pos++;
    field[k] = 0;
    while (pos < n && data[pos] >= '0' && data[pos] <= '9') field[k] = field[k] * 10 + data[pos++] - '0';
  }
  pos++;
  if (field[2] != 255 || n - pos < field[0] * field[1]) return;
  logo_w = field[0];
  logo_h = field[1];
  logo = (unsigned char *)data + pos;
}

/* ---- drawing, in the back buffer, within the clip ---- */

static int cx0, cy0, cx1, cy1;          /* the clip: the damaged rectangle */

static void fill(int x0, int y0, int x1, int y1, unsigned int c)
{
  int x, y;
  if (x0 < cx0) x0 = cx0;
  if (y0 < cy0) y0 = cy0;
  if (x1 > cx1) x1 = cx1;
  if (y1 > cy1) y1 = cy1;
  for (y = y0; y < y1; y++) {
    unsigned int * p = back + y * W;
    for (x = x0; x < x1; x++) p[x] = c;
  }
}

static int glyph_index(unsigned int u)
{
  if (u < 65536 && glyph_of[u] != 0xFFFF) return glyph_of[u];
  if (glyph_of[0xFFFD] != 0xFFFF) return glyph_of[0xFFFD];
  return glyph_of['?'] != 0xFFFF ? glyph_of['?'] : '?';
}

static void draw_glyph(int x, int y, int g, unsigned int c, int bold)
{
  int r, b;
  if (x + 8 <= cx0 || x >= cx1 || y + 16 <= cy0 || y >= cy1) return;
  for (r = 0; r < 16; r++) {
    unsigned char bits = glyphs[bold][g * 16 + r];
    int yy = y + r;
    if (yy < cy0 || yy >= cy1 || !bits) continue;
    for (b = 0; b < 8; b++)
      if (bits & (0x80 >> b)) {
	int xx = x + b;
	if (xx >= cx0 && xx < cx1) back[yy * W + xx] = c;
      }
  }
}

/* UTF-8 text, at most max cells: the cells drawn */
static int text(int x, int y, const char * s, int max, unsigned int c, int bold)
{
  int cells = 0;
  const unsigned char * p = (const unsigned char *)s;
  if (!font_ok) return 0;
  while (*p && cells < max) {
    unsigned int u = *p++;
    if (u >= 0xC0) {
      int more = u >= 0xF0 ? 3 : u >= 0xE0 ? 2 : 1;
      u &= 0x3F >> more;
      while (more-- && (*p & 0xC0) == 0x80) u = (u << 6) | (*p++ & 0x3F);
    }
    draw_glyph(x + 8 * cells, y, glyph_index(u), c, bold);
    cells++;
  }
  return cells;
}

/* ---- windows, events ---- */

enum { EV_KEY, EV_MOUSE, EV_CLOSE, EV_TICK, EV_FOCUS, EV_WHEEL };

struct event {
  int kind;
  char text[32];                       /* EV_KEY */
  int x, y, buttons;                   /* EV_MOUSE; x: EV_FOCUS's bool */
};

struct window {
  int used, id, owner, shown;
  int x, y, w, h;                      /* the content, on screen */
  char title[64];
  unsigned int * pix;                  /* the program's buffer, shared */
  mynos_msg_t * msg;
  struct event q[MAXEV];
  int qh, qn;
  int waiting;                         /* a next_event's channel, or -1 */
  long deadline;                       /* its timeout, in ms (0: none) */
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct window win[MAXWIN];
static int order[MAXWIN], norder = 0;  /* bottom to top */
static int next_id = 1;
static int focus = -1;                 /* a window's slot */
static int active = 0;                 /* the graphical session */
static int px = W / 2, py = H / 2, pbuttons = 0;
static int dragging = -1, drag_dx, drag_dy;
static int menu_open = 0;
static int waiters[16], nwaiters = 0;  /* wait_session's channels */

static long now_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static struct window * find(int id)
{
  int i;
  for (i = 0; i < MAXWIN; i++)
    if (win[i].used && win[i].id == id) return &win[i];
  return NULL;
}

/* ---- composition ---- */

#define C_DESK_TOP   0x1B3A57
#define C_DESK_BOT   0x0E1B2A
#define C_BAR        0x111820
#define C_BAR_TEXT   0xE8EEF2
#define C_ACCENT     0xF29B38
#define C_TITLE_ON   0x2D6CA2
#define C_TITLE_OFF  0x4A5560
#define C_BORDER     0x0A0F14
#define C_MENU       0xF4F6F8
#define C_MENU_TEXT  0x1A2228

struct menu_item { const char * label; const char * program; };
static const struct menu_item menu[] = {
  { "Terminal", "/terminal.byte" },
  { "Welcome", "/welcome.byte" },
  { "Clock", "/clock.byte" },
  { "Services", "/services.byte" },
  { NULL, NULL },
  { "Exit", NULL },
  { "Shut down", "/shutdown.byte" },
};
#define NMENU ((int)(sizeof menu / sizeof menu[0]))
#define MENU_X 4
#define MENU_W 160
#define MENU_ITEM 22

static const char * pointer_shape[] = {
  "X           ", "XX          ", "X.X         ", "X..X        ",
  "X...X       ", "X....X      ", "X.....X     ", "X......X    ",
  "X.......X   ", "X........X  ", "X.........X ", "X......XXXXX",
  "X...X..X    ", "X..XX..X    ", "X.X  X..X   ", "XX   X..X   ",
  "X     X..X  ", "      XXX   ",
};
#define PW 12
#define PH 18

static void draw_desktop(void)
{
  int y;
  for (y = cy0; y < cy1; y++) {
    /* a vertical gradient */
    int t = y * 256 / H;
    int r = (((C_DESK_TOP >> 16) & 255) * (256 - t) + ((C_DESK_BOT >> 16) & 255) * t) >> 8;
    int g = (((C_DESK_TOP >> 8) & 255) * (256 - t) + ((C_DESK_BOT >> 8) & 255) * t) >> 8;
    int b = ((C_DESK_TOP & 255) * (256 - t) + (C_DESK_BOT & 255) * t) >> 8;
    unsigned int c = (r << 16) | (g << 8) | b;
    unsigned int * p = back + y * W;
    int x;
    for (x = cx0; x < cx1; x++) p[x] = c;
  }
  if (logo) {                          /* the logo, faint, above the line */
    int lx = W - logo_w - 24, ly = H - logo_h - 36, x;
    for (y = (ly > cy0 ? ly : cy0); y < ly + logo_h && y < cy1; y++)
      for (x = (lx > cx0 ? lx : cx0); x < lx + logo_w && x < cx1; x++) {
	int a = (255 - logo[(y - ly) * logo_w + (x - lx)]) * 40 / 255;
	unsigned int d = back[y * W + x];
	if (!a) continue;
	back[y * W + x] =
	  ((((d >> 16) & 255) * (255 - a) + 0xD8 * a) / 255) << 16 |
	  ((((d >> 8) & 255) * (255 - a) + 0xE6 * a) / 255) << 8 |
	  (((d & 255) * (255 - a) + 0xF0 * a) / 255);
      }
  }
  text(W - 8 * 30 - 16, H - 28, "MyNOS \xc2\xb7 OCaml on a microkernel", 40, 0x5F7A90, 0);
  /* the top bar */
  fill(0, 0, W, TOP, C_BAR);
  fill(0, TOP - 1, W, TOP, 0x000000);
  fill(8, 6, 12, 18, C_ACCENT);
  text(18, 4, "MyNOS", 10, C_BAR_TEXT, 1);
  {
    char clock[16];
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(clock, sizeof clock, "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
    text(W - 8 * 8 - 12, 4, clock, 8, C_BAR_TEXT, 0);
  }
}

static void draw_window(struct window * w, int focused)
{
  int fx0 = w->x - 1, fy0 = w->y - TITLE - 1, fx1 = w->x + w->w + 1, fy1 = w->y + w->h + 1;
  int y, ix0, ix1;
  if (fx1 <= cx0 || fx0 >= cx1 || fy1 <= cy0 || fy0 >= cy1) return;
  /* a shadow, the border, the title bar, the close box */
  fill(fx0 + 4, fy1, fx1 + 4, fy1 + 4, 0x05080B);
  fill(fx1, fy0 + 4, fx1 + 4, fy1, 0x05080B);
  fill(fx0, fy0, fx1, fy1, C_BORDER);
  fill(w->x, w->y - TITLE, w->x + w->w, w->y, focused ? C_TITLE_ON : C_TITLE_OFF);
  text(w->x + 8, w->y - TITLE + 3, w->title, (w->w - 40) / 8, 0xFFFFFF, focused);
  fill(w->x + w->w - 20, w->y - TITLE + 4, w->x + w->w - 6, w->y - 4,
       focused ? 0xD9534F : 0x7A8590);
  {                                    /* × */
    int i, bx = w->x + w->w - 17, by = w->y - TITLE + 7;
    for (i = 0; i < 8; i++) {
      fill(bx + i, by + i, bx + i + 2, by + i + 1, 0xFFFFFF);
      fill(bx + 7 - i, by + i, bx + 9 - i, by + i + 1, 0xFFFFFF);
    }
  }
  /* the content */
  ix0 = w->x > cx0 ? w->x : cx0;
  ix1 = w->x + w->w < cx1 ? w->x + w->w : cx1;
  if (ix1 <= ix0) return;
  for (y = (w->y > cy0 ? w->y : cy0); y < w->y + w->h && y < cy1; y++) {
    if (w->pix)
      memcpy(back + y * W + ix0, w->pix + (y - w->y) * w->w + (ix0 - w->x),
	     (ix1 - ix0) * 4);
    else {
      int x;
      for (x = ix0; x < ix1; x++) back[y * W + x] = 0xFFFFFF;
    }
  }
}

static void draw_menu(void)
{
  int i, y = TOP;
  fill(MENU_X, y, MENU_X + MENU_W, y + NMENU * MENU_ITEM + 8, C_MENU);
  fill(MENU_X, y + NMENU * MENU_ITEM + 8, MENU_X + MENU_W, y + NMENU * MENU_ITEM + 9, C_BORDER);
  for (i = 0; i < NMENU; i++) {
    int iy = y + 4 + i * MENU_ITEM;
    if (!menu[i].label) {
      fill(MENU_X + 8, iy + MENU_ITEM / 2, MENU_X + MENU_W - 8, iy + MENU_ITEM / 2 + 1, 0xC0C8D0);
      continue;
    }
    if (px >= MENU_X && px < MENU_X + MENU_W && py >= iy && py < iy + MENU_ITEM)
      fill(MENU_X + 2, iy, MENU_X + MENU_W - 2, iy + MENU_ITEM, 0xD8E6F2);
    text(MENU_X + 14, iy + 3, menu[i].label, 18, C_MENU_TEXT, 0);
  }
}

static void draw_pointer(void)
{
  int r, c;
  for (r = 0; r < PH; r++)
    for (c = 0; c < PW; c++) {
      char k = pointer_shape[r][c];
      int x = px + c, y = py + r;
      if (k == ' ' || x < cx0 || x >= cx1 || y < cy0 || y >= cy1) continue;
      back[y * W + x] = k == 'X' ? 0x000000 : 0xFFFFFF;
    }
}

/* compose a rectangle of the screen, and show it (under the lock) */
static void compose(int x0, int y0, int x1, int y1)
{
  int i, y;
  if (!active) return;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > W) x1 = W;
  if (y1 > H) y1 = H;
  if (x0 >= x1 || y0 >= y1) return;
  cx0 = x0; cy0 = y0; cx1 = x1; cy1 = y1;
  draw_desktop();
  for (i = 0; i < norder; i++) {
    struct window * w = &win[order[i]];
    if (w->used && w->shown) draw_window(w, order[i] == focus);
  }
  if (menu_open) draw_menu();
  draw_pointer();
  for (y = y0; y < y1; y++)
    memcpy(fb + y * W + x0, back + y * W + x0, (x1 - x0) * 4);
}

static void compose_window(struct window * w)
{
  compose(w->x - 1, w->y - TITLE - 1, w->x + w->w + 5, w->y + w->h + 5);
}

/* ---- replies ---- */

static void send_reply(int ch, wire_writer * w)
{
  if (w->error) {
    wire_writer_free(w);
    wire_writer_init(w);
    wire_reply_error(w, "displayd: out of memory");
  }
  mynos_send(ch, w->buf, w->len, 0);
  mynos_freeChannel(ch);
  wire_writer_free(w);
}

static void reply_error(int ch, const char * m)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_error(&w, m);
  send_reply(ch, &w);
}

static void reply_unit(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  send_reply(ch, &w);
}

static void reply_int(int ch, int v)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, v);
  send_reply(ch, &w);
}

static void reply_event(int ch, const struct event * e)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, e->kind);
  switch (e->kind) {
  case EV_KEY: wire_put_cstring(&w, e->text); break;
  case EV_MOUSE:
    wire_put_int(&w, e->x);
    wire_put_int(&w, e->y);
    wire_put_int(&w, e->buttons);
    break;
  case EV_FOCUS: wire_put_bool(&w, e->x); break;
  case EV_WHEEL: wire_put_int(&w, e->x); break;
  }
  send_reply(ch, &w);
}

/* an event for a window: to its waiting next_event, or queued */
static void post(struct window * w, const struct event * e)
{
  if (w->waiting >= 0) {
    reply_event(w->waiting, e);
    w->waiting = -1;
    return;
  }
  if (e->kind == EV_MOUSE && w->qn > 0) {   /* moves: only the last one */
    struct event * last = &w->q[(w->qh + w->qn - 1) % MAXEV];
    if (last->kind == EV_MOUSE && last->buttons == e->buttons) { *last = *e; return; }
  }
  if (w->qn == MAXEV) {                /* full: a key or a click lost */
    if (e->kind == EV_MOUSE) return;
    w->qh = (w->qh + 1) % MAXEV;
    w->qn--;
  }
  w->q[(w->qh + w->qn) % MAXEV] = *e;
  w->qn++;
}

static void post_kind(struct window * w, int kind, int x)
{
  struct event e;
  memset(&e, 0, sizeof e);
  e.kind = kind;
  e.x = x;
  post(w, &e);
}

/* ---- the window stack ---- */

static void raise_window(int slot)
{
  int i, j;
  for (i = 0; i < norder && order[i] != slot; i++) ;
  if (i == norder) return;
  for (j = i; j < norder - 1; j++) order[j] = order[j + 1];
  order[norder - 1] = slot;
}

static void set_focus(int slot)
{
  int old = focus;
  if (slot == focus) return;
  focus = slot;                        /* first: the old one is drawn without */
  if (old >= 0 && win[old].used) {
    post_kind(&win[old], EV_FOCUS, 0);
    compose_window(&win[old]);
  }
  if (slot >= 0) {
    raise_window(slot);
    post_kind(&win[slot], EV_FOCUS, 1);
    compose_window(&win[slot]);
  }
}

static void remove_window(int slot)
{
  struct window * w = &win[slot];
  int i, j;
  if (!w->used) return;
  if (w->waiting >= 0) {
    struct event e;
    memset(&e, 0, sizeof e);
    e.kind = EV_CLOSE;
    reply_event(w->waiting, &e);
  }
  w->used = 0;
  if (w->msg) mynos_freeMsg(&w->msg);
  w->msg = NULL;
  w->pix = NULL;
  for (i = j = 0; i < norder; i++) if (order[i] != slot) order[j++] = order[i];
  norder = j;
  if (focus == slot) {
    focus = -1;
    if (norder > 0) set_focus(order[norder - 1]);
  }
  if (dragging == slot) dragging = -1;
  compose(w->x - 1, w->y - TITLE - 1, w->x + w->w + 5, w->y + w->h + 5);
}

/* the topmost window under a point: its slot, or -1 */
static int window_at(int x, int y)
{
  int i;
  for (i = norder - 1; i >= 0; i--) {
    struct window * w = &win[order[i]];
    if (w->used && w->shown && x >= w->x - 1 && x < w->x + w->w + 1 &&
	y >= w->y - TITLE - 1 && y < w->y + w->h + 1)
      return order[i];
  }
  return -1;
}

/* ---- the session ---- */

static void spawn_program(const char * path)
{
  static char * envp[] = { "PATH=/disk/bin:/", "HOME=/disk", "OCAMLLIB=/", NULL };
  char * argv[] = { "ocamlrun", (char *)path, NULL };
  if (mynos_spawnPriv("/ocamlrun", argv, envp, 0) < 0)
    mynos_log("displayd: cannot start %s\n", path);
}

static void * keys_thread(void * arg);

static void start_session(void)
{
  pthread_t t;
  if (active) return;
  mode_graphics();
  active = 1;
  menu_open = 0;
  compose(0, 0, W, H);
  pthread_create(&t, NULL, keys_thread, NULL);
}

static void end_session(void)
{
  int i;
  if (!active) return;
  for (i = 0; i < MAXWIN; i++) if (win[i].used) remove_window(i);
  active = 0;
  mode_text();
  for (i = 0; i < nwaiters; i++) reply_unit(waiters[i]);
  nwaiters = 0;
}

/* ---- the pointer ---- */

static void pointer_to(int x, int y, int buttons)
{
  int ox = px, oy = py, changed = buttons ^ pbuttons, slot;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > W - 1) x = W - 1;
  if (y > H - 1) y = H - 1;
  px = x; py = y; pbuttons = buttons;
  if (!active) return;

  if (dragging >= 0 && (buttons & 1)) {           /* moving a window */
    struct window * w = &win[dragging];
    int nx = x - drag_dx, ny = y - drag_dy;
    if (ny < TOP + TITLE) ny = TOP + TITLE;
    if (nx != w->x || ny != w->y) {
      int ax0 = w->x, ay0 = w->y;
      w->x = nx; w->y = ny;
      compose((ax0 < nx ? ax0 : nx) - 1, (ay0 < ny ? ay0 : ny) - TITLE - 1,
	      (ax0 > nx ? ax0 : nx) + w->w + 5, (ay0 > ny ? ay0 : ny) + w->h + 5);
    }
  } else if (dragging >= 0)
    dragging = -1;

  if ((changed & 1) && (buttons & 1)) {           /* a click */
    if (menu_open) {
      int i = (y - TOP - 4) / MENU_ITEM;
      menu_open = 0;
      compose(MENU_X, TOP, MENU_X + MENU_W, TOP + NMENU * MENU_ITEM + 10);
      if (x >= MENU_X && x < MENU_X + MENU_W && y >= TOP + 4 && i >= 0 && i < NMENU &&
	  menu[i].label) {
	if (menu[i].program) spawn_program(menu[i].program);
	else end_session();
	return;
      }
    } else if (y < TOP && x < 80) {
      menu_open = 1;
      compose(MENU_X, TOP, MENU_X + MENU_W, TOP + NMENU * MENU_ITEM + 10);
    }
    slot = window_at(x, y);
    if (slot >= 0) {
      struct window * w = &win[slot];
      set_focus(slot);
      if (y < w->y) {                              /* the title bar */
	if (x >= w->x + w->w - 20) post_kind(w, EV_CLOSE, 0);
	else { dragging = slot; drag_dx = x - w->x; drag_dy = y - w->y; }
      }
    }
  }
  /* the focused window's: clicks in it, and moves over it (and the one
     that leaves it, so that it stops showing what is under the pointer) */
  if (focus >= 0 && dragging < 0) {
    static int was_inside = 0;
    struct window * w = &win[focus];
    int inside = x >= w->x && y >= w->y && x < w->x + w->w && y < w->y + w->h;
    if ((changed && inside) || (!changed && (inside || was_inside)) ||
	(changed && !(buttons & 1) && was_inside)) {
      struct event e;
      memset(&e, 0, sizeof e);
      e.kind = EV_MOUSE;
      e.x = x - w->x;
      e.y = y - w->y;
      e.buttons = buttons;
      post(w, &e);
    }
    was_inside = inside;
  }
  if (menu_open) compose(MENU_X, TOP, MENU_X + MENU_W, TOP + NMENU * MENU_ITEM + 10);
  compose(ox, oy, ox + PW, oy + PH);
  compose(px, py, px + PW, py + PH);
}

/* the wheel: to the window under the pointer (positive: down) */
static void wheel(int dz)
{
  int slot;
  if (!active || dz == 0) return;
  slot = window_at(px, py);
  if (slot >= 0) {
    struct event e;
    memset(&e, 0, sizeof e);
    e.kind = EV_WHEEL;
    e.x = dz;
    post(&win[slot], &e);
  }
}

/* QEMU's vmmouse: absolute coordinates, through the VMware port */
static void vmport(unsigned int cmd, unsigned int arg, unsigned int r[4])
{
  unsigned int a = 0x564D5868, b = arg, c = cmd, d = 0x5658;
  __asm__ volatile ("inl %%dx, %%eax" : "+a"(a), "+b"(b), "+c"(c), "+d"(d));
  r[0] = a; r[1] = b; r[2] = c; r[3] = d;
}

static int vmmouse = 0;

static void vmmouse_init(void)
{
  unsigned int r[4];
  vmport(10, ~0u, r);                            /* GETVERSION */
  if (r[1] != 0x564D5868) return;
  vmport(41, 0x45414552, r);                     /* ENABLE */
  vmport(40, 0, r);                              /* STATUS */
  if ((r[0] & 0xFFFF0000) == 0xFFFF0000 || (r[0] & 0xFFFF) == 0) return;
  vmport(39, 1, r);                              /* DATA: the version */
  if (r[0] != 0x3442554A) return;
  vmport(41, 0x53424152, r);                     /* REQUEST_ABSOLUTE */
  vmmouse = 1;
}

static void vmmouse_read(void)
{
  unsigned int r[4], n;
  vmport(40, 0, r);
  if ((r[0] & 0xFFFF0000) == 0xFFFF0000) { vmmouse = 0; return; }
  for (n = r[0] & 0xFFFF; n >= 4; n -= 4) {
    int buttons;
    vmport(39, 4, r);
    buttons = ((r[0] & 0x20) ? 1 : 0) | ((r[0] & 0x10) ? 2 : 0) | ((r[0] & 0x08) ? 4 : 0);
    pointer_to((int)(r[1] * W / 65536), (int)(r[2] * H / 65536), buttons);
    wheel((signed char)(r[3] & 0xFF));
  }
}

static void kbc_wait(void)
{
  int i;
  for (i = 0; i < 100000 && (inportb(0x64) & 2); i++) ;
}

/* a byte from the mouse, waited for a while (before its IRQ is on); -1 */
static int aux_read(void)
{
  int i;
  for (i = 0; i < 200000; i++) {
    unsigned char st = inportb(0x64);
    if ((st & 0x21) == 0x21) return inportb(0x60);
  }
  return -1;
}

/* a command to the mouse, its acknowledgement read */
static void mouse_cmd(unsigned char c)
{
  kbc_wait(); outportb(0x64, 0xD4);
  kbc_wait(); outportb(0x60, c);
  aux_read();
}

static int packet = 3;               /* 4: IntelliMouse, with the wheel */

static void * mouse_thread(void * arg)
{
  int sem = IDX(arg);
  unsigned char pkt[4];
  int n = 0;
  for (;;) {
    unsigned char st;
    if (mynos_P(sem) < 0) return NULL;
    pthread_mutex_lock(&lock);
    while (((st = inportb(0x64)) & 1) && (st & 0x20)) {
      unsigned char b = inportb(0x60);
      /* not a packet's start: the commands' acknowledgements (0xFA, whose
	 bit 3 looks like a packet's first byte), or out of step */
      if (n == 0 && (!(b & 0x08) || b == 0xFA)) continue;
      pkt[n++] = b;
      if (n < packet) continue;
      n = 0;
      if (vmmouse) continue;                     /* its coordinates instead */
      {
	int dx = pkt[1] - ((pkt[0] & 0x10) ? 256 : 0);
	int dy = pkt[2] - ((pkt[0] & 0x20) ? 256 : 0);
	pointer_to(px + dx, py - dy, pkt[0] & 7);
	if (packet == 4) wheel((signed char)pkt[3]);
      }
    }
    if (vmmouse) vmmouse_read();
    pthread_mutex_unlock(&lock);
  }
  return NULL;
}

/* ---- the keys: the console, raw, while the session lasts ---- */

static void * keys_thread(void * arg)
{
  struct termios saved, t;
  char buf[32];
  (void)arg;
  tcgetattr(0, &saved);
  t = saved;
  t.c_lflag &= ~(ICANON | ECHO);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 1;                               /* 0.1 s: then look again */
  tcsetattr(0, TCSANOW, &t);
  for (;;) {
    int n = read(0, buf, sizeof buf - 1);
    pthread_mutex_lock(&lock);
    if (!active) { pthread_mutex_unlock(&lock); break; }
    if (n > 0 && focus >= 0) {
      struct event e;
      memset(&e, 0, sizeof e);
      e.kind = EV_KEY;
      memcpy(e.text, buf, n);
      post(&win[focus], &e);
    }
    pthread_mutex_unlock(&lock);
  }
  saved.c_lflag |= ICANON | ECHO;
  tcsetattr(0, TCSANOW, &saved);
  return NULL;
}

/* ---- the timer: ticks, the clock, windows of programs that ended ---- */

static void * timer_thread(void * arg)
{
  int last_second = -1;
  (void)arg;
  for (;;) {
    int i;
    long now;
    mynos_sleep(100000);
    pthread_mutex_lock(&lock);
    now = now_ms();
    for (i = 0; i < MAXWIN; i++) {
      struct window * w = &win[i];
      if (w->used && w->waiting >= 0 && w->deadline && now >= w->deadline) {
	struct event e;
	memset(&e, 0, sizeof e);
	e.kind = EV_TICK;
	reply_event(w->waiting, &e);
	w->waiting = -1;
      }
    }
    if (time(NULL) % 60 != last_second) {
      last_second = time(NULL) % 60;
      for (i = 0; i < MAXWIN; i++) {
	int info;
	if (!win[i].used) continue;
	info = mynos_processInfo(win[i].owner);
	if (info < 0 || !(info & MYNOS_PROC_ALIVE)) remove_window(i);
      }
      compose(W - 8 * 8 - 12, 0, W, TOP);          /* the clock */
    }
    pthread_mutex_unlock(&lock);
  }
  return NULL;
}

/* ---- requests ---- */

static const wire_request_doc requests[] = {
  { 1, "info", "U", "(width:I,height:I)", "The screen's size, in pixels." },
  { 0, "create", "(title:S,width:I,height:I)", "I",
    "A window, of this size (its content): its number. It shows once attached." },
  { 0, "attach", "window:I", "U",
    "Give a window its pixels: the same connection then carries a shared message "
    "of width x height 32-bit pixels (0xRRGGBB), which stays shared with the display." },
  { 0, "damage", "((window:I,x:I,y:I),(width:I,height:I))", "U",
    "A part of the window's pixels changed: it is shown again." },
  { 0, "next_event", "(window:I,timeout_ms:I)",
    "V(0:key=S,1:mouse=(x:I,y:I,buttons:I),2:close=U,3:tick=U,4:focus=B,5:wheel=I)",
    "The window's next event: keys (UTF-8, VT100 sequences for the others), the "
    "mouse in the window (buttons: 1 left, 2 right, 4 middle), close, focus, the "
    "wheel over it (its notches, positive towards the user: down); tick when none "
    "came within timeout_ms (0: wait forever). Waits." },
  { 0, "destroy", "window:I", "U", "Close a window." },
  { 0, "set_title", "(window:I,title:S)", "U", "A window's title." },
  { 0, "start", "U", "U", "Start the graphical session: the screen leaves text mode." },
  { 0, "wait_session", "U", "U", "Wait until the graphical session ends. Waits." },
  { 0, "stop", "U", "U", "End the graphical session: windows get close, text mode is back." },
  { 0, "move", "(window:I,x:I,y:I)", "U", "Move a window (its content's top left corner)." },
};

static void describe(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, PROTOCOL,
    "The display (displayd, in C): the graphical session, windows whose pixels are "
    "shared with it, their events.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(ch, &w);
}

static struct window * owned(int ch, int id, int caller)
{
  struct window * w = find(id);
  if (!w) { reply_error(ch, "no such window"); return NULL; }
  if (w->owner != caller) { reply_error(ch, "not your window"); return NULL; }
  return w;
}

/* a request (under the lock); deferred ones keep their channel */
static void handle(int ch, int caller, const char * msg, unsigned int len)
{
  wire_reader r;
  unsigned int n;
  const char * id;
  int kind;
  struct window * w;
  char title[64];

  wire_reader_init(&r, msg, len);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n) &&
      wire_at_end(&r)) { describe(ch); return; }
  if (r.error || n != strlen(PROTOCOL) || memcmp(id, PROTOCOL, n)) {
    reply_error(ch, "protocol: displayd speaks " PROTOCOL);
    return;
  }
#define END() if (!wire_at_end(&r) || r.error) { reply_error(ch, "malformed request"); return; }
  kind = wire_get_int(&r);
  switch (kind) {
  case 0: {                                        /* info */
    wire_writer o;
    END();
    wire_writer_init(&o);
    wire_reply_ok(&o);
    wire_put_int(&o, W);
    wire_put_int(&o, H);
    send_reply(ch, &o);
    break;
  }
  case 1: {                                        /* create */
    int i, ww, hh;
    wire_get_cstring(&r, title, sizeof title);
    ww = wire_get_int(&r);
    hh = wire_get_int(&r);
    END();
    if (ww < 16 || hh < 16 || ww > W - 2 || hh > H - TOP - TITLE - 2) {
      reply_error(ch, "bad size"); return;
    }
    for (i = 0; i < MAXWIN && win[i].used; i++) ;
    if (i == MAXWIN) { reply_error(ch, "too many windows"); return; }
    w = &win[i];
    memset(w, 0, sizeof *w);
    w->used = 1;
    w->id = next_id++;
    w->owner = caller;
    w->w = ww; w->h = hh;
    /* a cascade from the top left */
    w->x = 40 + (w->id % 8) * 32;
    w->y = TOP + TITLE + 24 + (w->id % 8) * 28;
    if (w->x + ww > W - 4) w->x = W - 4 - ww;
    if (w->y + hh > H - 4) w->y = H - 4 - hh;
    if (w->x < 1) w->x = 1;
    if (w->y < TOP + TITLE + 1) w->y = TOP + TITLE + 1;
    strcpy(w->title, title);
    w->waiting = -1;
    order[norder++] = i;
    reply_int(ch, w->id);
    break;
  }
  case 2: {                                        /* attach */
    mynos_msg_t * m = NULL;
    int wid = wire_get_int(&r);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    /* the pixels: the next message, shared */
    pthread_mutex_unlock(&lock);
    n = mynos_recv(ch, &m, 0, 2000);
    pthread_mutex_lock(&lock);
    if ((int)n < 0 || !m) { reply_error(ch, "attach: no pixels"); return; }
    if (!(w = find(wid)) || m->size < (unsigned)(w->w * w->h * 4)) {
      mynos_freeMsg(&m);
      reply_error(ch, "attach: not the window's size");
      return;
    }
    if (w->msg) mynos_freeMsg(&w->msg);
    w->msg = m;
    w->pix = (unsigned int *)m->start;
    w->shown = 1;
    reply_unit(ch);
    set_focus(w - win);
    compose_window(w);
    break;
  }
  case 3: {                                        /* damage */
    int wid = wire_get_int(&r), x = wire_get_int(&r), y = wire_get_int(&r);
    int dw = wire_get_int(&r), dh = wire_get_int(&r);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    reply_unit(ch);
    compose(w->x + x, w->y + y, w->x + x + dw, w->y + y + dh);
    break;
  }
  case 4: {                                        /* next_event */
    int wid = wire_get_int(&r), timeout = wire_get_int(&r);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    if (w->waiting >= 0) { reply_error(ch, "already waiting"); return; }
    if (w->qn > 0) {
      struct event e = w->q[w->qh];
      w->qh = (w->qh + 1) % MAXEV;
      w->qn--;
      reply_event(ch, &e);
    } else {
      w->waiting = ch;
      w->deadline = timeout > 0 ? now_ms() + timeout : 0;
    }
    break;
  }
  case 5: {                                        /* destroy */
    int wid = wire_get_int(&r);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    reply_unit(ch);
    remove_window(w - win);
    break;
  }
  case 6: {                                        /* set_title */
    int wid = wire_get_int(&r);
    wire_get_cstring(&r, title, sizeof title);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    strcpy(w->title, title);
    reply_unit(ch);
    compose(w->x, w->y - TITLE, w->x + w->w, w->y);
    break;
  }
  case 7: END(); start_session(); reply_unit(ch); break;   /* start */
  case 8:                                          /* wait_session */
    END();
    if (!active || nwaiters == 16) { reply_unit(ch); break; }
    waiters[nwaiters++] = ch;
    break;
  case 9: END(); reply_unit(ch); end_session(); break;     /* stop */
  case 10: {                                       /* move */
    int wid = wire_get_int(&r), x = wire_get_int(&r), y = wire_get_int(&r);
    int ox, oy;
    END();
    if (!(w = owned(ch, wid, caller))) return;
    ox = w->x; oy = w->y;
    w->x = x;
    w->y = y < TOP + TITLE ? TOP + TITLE : y;
    reply_unit(ch);
    compose(ox - 1, oy - TITLE - 1, ox + w->w + 5, oy + w->h + 5);
    compose_window(w);
    break;
  }
  default:
    reply_error(ch, "unknown request");
  }
}

int main(void)
{
  unsigned long lfb;
  void * base;
  int port, sem, i;
  pthread_t t;

  for (i = 0; i < 65536; i++) glyph_of[i] = 0xFFFF;
  load_font(0, FONT);
  load_font(1, FONT_BOLD);
  load_logo();

  if (bga_get(0) < 0xB0C0 || bga_get(0) > 0xB0CF || !(lfb = find_lfb())) {
    mynos_log("displayd: no Bochs VGA (QEMU's standard VGA): no graphics\n");
    return 1;
  }
  base = mynos_mapPhysical(lfb, (FB_SKIP + W * H * 4) / 4096);
  back = malloc(W * H * 4);
  if (!base || !back) {
    mynos_log("displayd: cannot map the frame buffer\n");
    return 1;
  }
  fb = (unsigned int *)((char *)base + FB_SKIP);

  /* the mouse: PS/2 on IRQ 12, and vmmouse if there is one */
  sem = mynos_driverRegister("mouse", 12, NULL, NULL);
  if (sem >= 0) {
    kbc_wait(); outportb(0x64, 0xA8);              /* the auxiliary port on */
    kbc_wait(); outportb(0x64, 0x60);              /* command byte: both IRQs */
    kbc_wait(); outportb(0x60, 0x47);
    mouse_cmd(0xF6);                                /* defaults */
    /* IntelliMouse: sample rates 200, 100, 80, then its ID says 3: packets
       of 4 bytes, the wheel in the fourth */
    mouse_cmd(0xF3); mouse_cmd(200);
    mouse_cmd(0xF3); mouse_cmd(100);
    mouse_cmd(0xF3); mouse_cmd(80);
    kbc_wait(); outportb(0x64, 0xD4);
    kbc_wait(); outportb(0x60, 0xF2);               /* its ID */
    if (aux_read() == 0xFA && aux_read() == 3) packet = 4;
    mouse_cmd(0xF4);                                /* reporting on */
    vmmouse_init();
    mynos_enableIrq(12);
    pthread_create(&t, NULL, mouse_thread, ARG(sem));
  } else
    mynos_log("displayd: no mouse (%d)\n", sem);

  pthread_create(&t, NULL, timer_thread, NULL);

  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("displayd: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("displayd: %dx%d, frame buffer at 0x%lx, %s%s\n", W, H, lfb,
	    vmmouse ? "vmmouse (absolute)" : "PS/2 mouse",
	    packet == 4 ? ", wheel" : "");

  for (;;) {
    mynos_msg_t * m;
    int caller;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    if (mynos_recv(ch, &m, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    caller = mynos_channelPeer(ch);
    pthread_mutex_lock(&lock);
    handle(ch, caller, m->start, m->size);
    pthread_mutex_unlock(&lock);
    mynos_freeMsg(&m);
  }
  return 0;
}
