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
 * service, read in raw mode while the session lasts, with their releases
 * (CONSOLE_RELEASES): a key event for each key, a key_up for each release.
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
#include <mynos_virtio.h>

#define SERVICE  "display"
#define PROTOCOL "display/1"
/* the screen's size: chosen when a session starts (gui WxH), 1024x768
   by default, within the video memory */
static int W = 1024, H = 768;
static unsigned long vram = 0;           /* bytes of video memory, mapped */
static unsigned int * vram_base;
static int fb_rows_skipped;              /* rows of FB_SKIP, rounded up */
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

#if defined(__i386__) || defined(__x86_64__)
static inline void outw(unsigned short port, unsigned short v)
{ __asm__ volatile ("outw %0, %1" : : "a"(v), "Nd"(port)); }
static inline unsigned short inw(unsigned short port)
{ unsigned short v; __asm__ volatile ("inw %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static inline void outl(unsigned short port, unsigned int v)
{ __asm__ volatile ("outl %0, %1" : : "a"(v), "Nd"(port)); }
static inline unsigned int inl(unsigned short port)
{ unsigned int v; __asm__ volatile ("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }

#else
/* no I/O ports (AArch64): no Bochs display or VGA on the ports' PCI */
static inline void outw(unsigned short port, unsigned short v) { (void)port; (void)v; }
static inline unsigned short inw(unsigned short port) { (void)port; return 0xFFFF; }
static inline void outl(unsigned short port, unsigned int v) { (void)port; (void)v; }
static inline unsigned int inl(unsigned short port) { (void)port; return 0xFFFFFFFF; }
#endif

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
  fb_rows_skipped = (FB_SKIP + W * 4 - 1) / (W * 4);
  bga(9, fb_rows_skipped);             /* the picture starts past 256 KB */
}

static void mode_text(void) { bga(4, 0); vga_restore(); }

/* ---- a virtio GPU (doc/decisions/virtio.md): the screen of QEMU's
   virt machines, and of -vga none -device virtio-gpu-pci. One 2D
   resource whose backing is the frame buffer here, in DMA memory: what
   is composed there goes to the host with TRANSFER_TO_HOST_2D, then
   RESOURCE_FLUSH, for the rectangle that changed ---- */

static int vgpu = 0;                     /* the screen is a virtio GPU's */
static virtio_dev_t gpu;
static virtq_t gpuq;
static unsigned char * gpu_cmd;          /* a command, then its reply */
static unsigned long gpu_cmd_phys;
static unsigned int * gpu_fb;            /* the resource's backing */
static unsigned long gpu_fb_phys, gpu_fb_bytes;
static int gpu_res = 0;                  /* the resource, 0: none */

#define GPU_GET_DISPLAY_INFO 0x0100
#define GPU_RESOURCE_CREATE_2D 0x0101
#define GPU_RESOURCE_UNREF 0x0102
#define GPU_SET_SCANOUT 0x0103
#define GPU_RESOURCE_FLUSH 0x0104
#define GPU_TRANSFER_TO_HOST_2D 0x0105
#define GPU_RESOURCE_ATTACH_BACKING 0x0106
#define GPU_OK_NODATA 0x1100
#define GPU_FORMAT_B8G8R8X8 2               /* 0x00RRGGBB, little endian */

/* a command of [n] bytes (its header's type first, the rest zero but
   the words given), waited for: 0, or -1 if the device refused it */
static int gpu_command(int n, const unsigned int * words, int nwords)
{
  virtq_buf_t b[2];
  int i;
  memset(gpu_cmd, 0, 512);
  for (i = 0; i < nwords; i++) ((unsigned int *)gpu_cmd)[i] = words[i];
  b[0].phys = gpu_cmd_phys; b[0].len = n; b[0].write = 0;
  b[1].phys = gpu_cmd_phys + 256; b[1].len = 24; b[1].write = 1;
  if (virtq_add(&gpuq, b, 2) < 0) return -1;
  virtq_kick(&gpuq);
  for (i = 0; virtq_get(&gpuq, NULL) < 0; i++)
    if (i > 1000) mynos_sleep(1000);
  return *(unsigned int *)(gpu_cmd + 256) == GPU_OK_NODATA ? 0 : -1;
}

/* the header is 6 words (type, flags, fence: 2, context, ring); the
   command's own fields follow */
static int vgpu_init(void)
{
  if (virtio_find(VIRTIO_GPU, 0, &gpu) < 0) return -1;
  if (virtio_start(&gpu, 0) < 0 || virtq_setup(&gpu, 0, 16, &gpuq) < 0) return -1;
  gpu_cmd = virtio_dma(1, &gpu_cmd_phys);
  if (gpu_cmd == NULL) return -1;
  virtio_ready(&gpu);
  return 0;
}

/* the screen at W x H: a resource as large, its backing, the scanout */
static int vgpu_mode(void)
{
  unsigned long bytes = (unsigned long)W * H * 4;
  if (bytes > gpu_fb_bytes) {           /* a larger screen: more memory
					   (the smaller one stays, unused) */
    gpu_fb = virtio_dma((bytes + 4095) / 4096, &gpu_fb_phys);
    if (gpu_fb == NULL) { gpu_fb_bytes = 0; return -1; }
    gpu_fb_bytes = bytes;
  }
  if (gpu_res) {
    unsigned int unref[] = { GPU_RESOURCE_UNREF, 0, 0, 0, 0, 0, gpu_res };
    gpu_command(32, unref, 7);
  }
  gpu_res++;
  {
    unsigned int create[] = { GPU_RESOURCE_CREATE_2D, 0, 0, 0, 0, 0,
                              gpu_res, GPU_FORMAT_B8G8R8X8, W, H };
    unsigned int attach[] = { GPU_RESOURCE_ATTACH_BACKING, 0, 0, 0, 0, 0,
                              gpu_res, 1, gpu_fb_phys, 0, W * H * 4, 0 };
    unsigned int scanout[] = { GPU_SET_SCANOUT, 0, 0, 0, 0, 0,
                               0, 0, W, H, 0, gpu_res };
    if (gpu_command(40, create, 10) < 0 || gpu_command(48, attach, 12) < 0 ||
        gpu_command(48, scanout, 12) < 0)
      return -1;
  }
  return 0;
}

/* the rectangle, from the frame buffer to the host's screen */
static void vgpu_flush(int x0, int y0, int x1, int y1)
{
  unsigned int w = x1 - x0, h = y1 - y0, off = (y0 * W + x0) * 4;
  unsigned int transfer[] = { GPU_TRANSFER_TO_HOST_2D, 0, 0, 0, 0, 0,
                              x0, y0, w, h, off, 0, gpu_res, 0 };
  unsigned int flush[] = { GPU_RESOURCE_FLUSH, 0, 0, 0, 0, 0,
                           x0, y0, w, h, gpu_res, 0 };
  gpu_command(56, transfer, 14);
  gpu_command(48, flush, 12);
}

/* the session ends: the screen shows nothing of ours */
static void vgpu_off(void)
{
  unsigned int scanout[] = { GPU_SET_SCANOUT, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
  gpu_command(48, scanout, 12);
}

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

enum { EV_KEY, EV_MOUSE, EV_CLOSE, EV_TICK, EV_FOCUS, EV_WHEEL, EV_KEY_UP, EV_RESIZE };

struct event {
  int kind;
  char text[32];                       /* EV_KEY, EV_KEY_UP */
  int x, y, buttons;                   /* EV_MOUSE, EV_RESIZE's size; x: EV_FOCUS's bool */
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
  int resizable, min_w, min_h;         /* a grip, a double click on the title */
  int maximized, rx, ry, rw, rh;       /* maximized: where and how big it was */
  long title_click;                    /* the last click on its title (ms) */
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* the last time a window asked to wait less than the timer's period: the
   timer then checks every 10 ms (the kernel's resolution), for 2 s */
static long fast_until = 0;
static struct window win[MAXWIN];
static int order[MAXWIN], norder = 0;  /* bottom to top */
static int next_id = 1;
static int focus = -1;                 /* a window's slot */
static int active = 0;                 /* the graphical session */
static int px = 512, py = 384, pbuttons = 0;
static int dragging = -1, drag_dx, drag_dy;
static int closing = -1;               /* the window whose close box is held */
/* a window being resized by its grip: the size asked so far (an outline
   shows it), and the pointer's distance from the corner */
static int resizing = -1, rs_w, rs_h, rs_dx, rs_dy;
#define GRIP 12
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
  { "Agent", "/agent_window.byte" },
  { "Recordings", "/recordings.byte" },
  { "System", "/system.byte" },
  { "Files", "/files.byte" },
  { "Tour", "/tour.byte" },
  { "Log", "/log_window.byte" },
  { "Packages", "/packages.byte" },
  { "Applications", "/apps.byte" },
  { "Text", "/text.byte" },
  { "Ask MyNOS", "/ask.byte" },
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

/* the top bar's tabs: the shown windows, in the order they were made */
#define TABS_X 96
/* the volume (soundd's), left of the clock, when there is sound */
#define VOL_W 64
#define VOL_X (W - 8 * 8 - 24 - VOL_W)
#define VP_W 88
#define VP_X (VOL_X + VOL_W / 2 - VP_W / 2)
#define VP_H 176
#define VP_T0 (TOP + 36)                 /* the slider: from 100 at the top */
#define VP_T1 (TOP + VP_H - 28)          /* to 0 at the bottom */
static int volume_level = -1;            /* -1: no sound service */
static int volume_open = 0, volume_drag = 0;
#define TABS_END (volume_level >= 0 ? VOL_X - 8 : W - 8 * 8 - 24)
static int tabs(int * slots)
{
  int n = 0, i, j;
  for (i = 0; i < MAXWIN; i++)
    if (win[i].used && win[i].shown) {
      for (j = n; j > 0 && win[slots[j - 1]].id > win[i].id; j--) slots[j] = slots[j - 1];
      slots[j] = i;
      n++;
    }
  return n;
}

static void tab_rect(int k, int n, int * x0, int * x1)
{
  int w = (TABS_END - TABS_X) / (n > 0 ? n : 1);
  if (w > 170) w = 170;
  *x0 = TABS_X + k * w;
  *x1 = *x0 + w;
}

#define BAR_CHANGED() compose(0, 0, W, TOP)

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
  {                                    /* a tab for each window */
    int slots[MAXWIN], n = tabs(slots), k;
    for (k = 0; k < n; k++) {
      struct window * t = &win[slots[k]];
      int x0, x1;
      tab_rect(k, n, &x0, &x1);
      fill(x0, 3, x1 - 4, TOP - 4, slots[k] == focus ? C_TITLE_ON : 0x26313B);
      text(x0 + 6, 4, t->title, (x1 - x0 - 14) / 8, slots[k] == focus ? 0xFFFFFF : 0xB8C2CC,
	   slots[k] == focus);
    }
  }
  {
    char clock[16];
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(clock, sizeof clock, "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
    text(W - 8 * 8 - 12, 4, clock, 8, C_BAR_TEXT, 0);
  }
  if (volume_level >= 0) {             /* a loudspeaker, and the volume */
    char v[16];
    int i, c = volume_open ? 0xFFFFFF : C_BAR_TEXT, x = VOL_X + 6;
    if (volume_open) fill(VOL_X, 3, VOL_X + VOL_W, TOP - 4, C_TITLE_ON);
    fill(x, 10, x + 4, 15, c);
    for (i = 0; i < 5; i++) fill(x + 4 + i, 10 - i, x + 5 + i, 15 + i, c);
    if (volume_level > 0) fill(x + 11, 11, x + 12, 14, c);
    if (volume_level > 50) fill(x + 13, 9, x + 14, 16, c);
    snprintf(v, sizeof v, "%d%%", volume_level);
    text(VOL_X + 26, 4, v, 4, c, 0);
  }
}

/* the volume's panel, under the bar: a slider */
static void draw_volume(void)
{
  int y = VP_T1 - (VP_T1 - VP_T0) * volume_level / 100, cx = VP_X + VP_W / 2;
  char v[16];
  fill(VP_X, TOP, VP_X + VP_W, TOP + VP_H, C_MENU);
  fill(VP_X, TOP + VP_H, VP_X + VP_W, TOP + VP_H + 1, C_BORDER);
  text(VP_X + 12, TOP + 8, "Volume", 8, C_MENU_TEXT, 1);
  fill(cx - 3, VP_T0, cx + 3, VP_T1, 0xC0C8D0);
  fill(cx - 3, y, cx + 3, VP_T1, C_TITLE_ON);
  fill(cx - 12, y - 4, cx + 12, y + 4, C_ACCENT);
  snprintf(v, sizeof v, "%d%%", volume_level);
  text(cx - 4 * (int)strlen(v), VP_T1 + 6, v, 5, C_MENU_TEXT, 0);
}

/* sound/1's volume (case 6): set it (0 to 100) or ask it (-1); -1 when
   there is no sound service, or it does not answer within half a second */
static int sound_volume(int level)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  int port = mynos_registryLookUp("sound"), ch, res = -1;
  long long v;
  if (port < 0) return -1;
  wire_writer_init(&w);
  wire_put_cstring(&w, "sound/1");
  wire_put_int(&w, 6);
  wire_put_int(&w, level);
  if (w.error || (ch = mynos_connectToPort(port)) < 0) { wire_writer_free(&w); return -1; }
  mynos_send(ch, w.buf, w.len, 0);
  wire_writer_free(&w);
  if (mynos_recv(ch, &msg, 0, 500) < 0) { mynos_freeChannel(ch); return -1; }
  mynos_freeChannel(ch);
  wire_reader_init(&r, msg->start, msg->size);
  if (wire_get_int(&r) == 0) {
    v = wire_get_int(&r);
    if (!r.error) res = (int)v;
  }
  mynos_freeMsg(&msg);
  return res;
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
       closing >= 0 && w == &win[closing] ? 0x9A2A26 : focused ? 0xD9534F : 0x7A8590);
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
  if (w->resizable) {                  /* the grip: three short diagonals */
    int i, gx = w->x + w->w, gy = w->y + w->h;
    for (i = 0; i < GRIP - 2; i++) {
      fill(gx - 2 - i, gy - GRIP + 1 + i, gx - 1 - i, gy - GRIP + 2 + i, 0x7F8C98);
      if (i >= 4) fill(gx - 2 - i + 4, gy - GRIP + 1 + i, gx - 1 - i + 4, gy - GRIP + 2 + i, 0x7F8C98);
      if (i >= 8) fill(gx - 2 - i + 8, gy - GRIP + 1 + i, gx - 1 - i + 8, gy - GRIP + 2 + i, 0x7F8C98);
    }
  }
}

/* the outline of the size a grip asks for */
static void draw_outline(void)
{
  struct window * w = &win[resizing];
  int x0 = w->x - 1, y0 = w->y - TITLE - 1, x1 = w->x + rs_w + 1, y1 = w->y + rs_h + 1;
  fill(x0, y0, x1, y0 + 2, C_ACCENT);
  fill(x0, y1 - 2, x1, y1, C_ACCENT);
  fill(x0, y0, x0 + 2, y1, C_ACCENT);
  fill(x1 - 2, y0, x1, y1, C_ACCENT);
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
  if (resizing >= 0) draw_outline();
  if (menu_open) draw_menu();
  if (volume_open) draw_volume();
  draw_pointer();
  for (y = y0; y < y1; y++)
    memcpy(fb + y * W + x0, back + y * W + x0, (x1 - x0) * 4);
  if (vgpu) vgpu_flush(x0, y0, x1, y1);
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
  case EV_KEY: case EV_KEY_UP: wire_put_cstring(&w, e->text); break;
  case EV_MOUSE:
    wire_put_int(&w, e->x);
    wire_put_int(&w, e->y);
    wire_put_int(&w, e->buttons);
    break;
  case EV_FOCUS: wire_put_bool(&w, e->x); break;
  case EV_RESIZE:
    wire_put_int(&w, e->x);
    wire_put_int(&w, e->y);
    break;
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
  BAR_CHANGED();
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
  if (closing == slot) closing = -1;
  if (resizing == slot) resizing = -1;
  compose(w->x - 1, w->y - TITLE - 1, w->x + w->w + 5, w->y + w->h + 5);
  BAR_CHANGED();
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

/* a size the video memory holds, past the text-mode memory kept: 0 if so */
static const char * size_refused(int w, int h)
{
  unsigned long rows;
  if (w < 800 || h < 600 || w > 4096 || h > 4096 || w % 8) return "from 800x600, a width multiple of 8";
  rows = vgpu ? 0 : (FB_SKIP + w * 4 - 1) / (w * 4);
  if ((rows + h) * (unsigned long)w * 4 > vram) return "more than the video memory holds";
  return NULL;
}

static void start_session(int w, int h)
{
  pthread_t t;
  unsigned int * b;
  if (active) return;
  if (w != W || h != H || !back) {
    b = realloc(back, (size_t)w * h * 4);
    if (!b) return;
    back = b;
    W = w; H = h;
  }
  if (vgpu) {
    if (vgpu_mode() < 0) {
      mynos_log("displayd: the virtio GPU refused %dx%d\n", W, H);
      return;
    }
    fb = gpu_fb;
  } else {
    mode_graphics();
    fb = vram_base + fb_rows_skipped * W;
  }
  if (px > W - 1) px = W - 1;            /* the pointer stays where it was, */
  if (py > H - 1) py = H - 1;            /* on the screen */
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
  if (vgpu) vgpu_off(); else mode_text();
  for (i = 0; i < nwaiters; i++) reply_unit(waiters[i]);
  nwaiters = 0;
}

/* ---- resizing ---- */

/* the largest content a window can have where it stands */
static int max_w(struct window * w) { return W - 1 - w->x; }
static int max_h(struct window * w) { return H - 1 - w->y; }

static void post_resize(struct window * w, int nw, int nh)
{
  struct event e;
  memset(&e, 0, sizeof e);
  e.kind = EV_RESIZE;
  e.x = nw;
  e.y = nh;
  post(w, &e);
}

/* a double click on the title: as big as the screen, or back. The window
   moves at once; its program answers the resize event with new pixels */
static void toggle_maximize(struct window * w)
{
  int ox = w->x, oy = w->y;
  if (!w->maximized) {
    w->rx = w->x; w->ry = w->y; w->rw = w->w; w->rh = w->h;
    w->x = 1;
    w->y = TOP + TITLE + 1;
    w->maximized = 1;
    post_resize(w, W - 2, H - TOP - TITLE - 2);
  } else {
    w->x = w->rx;
    w->y = w->ry;
    w->maximized = 0;
    post_resize(w, w->rw, w->rh);
  }
  compose(ox - 1, oy - TITLE - 1, ox + w->w + 5, oy + w->h + 5);
  compose_window(w);
}

#define VOLUME_CHANGED() compose(VP_X < VOL_X ? VP_X : VOL_X, 0, VP_X + VP_W + 1, TOP + VP_H + 2)

/* the volume from the slider's height */
static void volume_at(int y)
{
  int v = (VP_T1 - y) * 100 / (VP_T1 - VP_T0), got;
  if (v < 0) v = 0;
  if (v > 100) v = 100;
  if ((got = sound_volume(v)) >= 0) volume_level = got;
  VOLUME_CHANGED();
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

  if (resizing >= 0) {                             /* a grip held */
    struct window * w = &win[resizing];
    int ow = rs_w, oh = rs_h;
    if (buttons & 1) {
      rs_w = x - w->x + rs_dx;
      rs_h = y - w->y + rs_dy;
      if (rs_w < w->min_w) rs_w = w->min_w;
      if (rs_h < w->min_h) rs_h = w->min_h;
      if (rs_w > max_w(w)) rs_w = max_w(w);
      if (rs_h > max_h(w)) rs_h = max_h(w);
      if (rs_w != ow || rs_h != oh) {
        int bw = (rs_w > ow ? rs_w : ow), bh = (rs_h > oh ? rs_h : oh);
        compose(w->x - 1, w->y - TITLE - 1, w->x + bw + 5, w->y + bh + 5);
      }
    } else {                                       /* let go: the program is told */
      resizing = -1;
      if (rs_w != w->w || rs_h != w->h) {
        w->maximized = 0;
        post_resize(w, rs_w, rs_h);
      }
      compose(w->x - 1, w->y - TITLE - 1, w->x + (rs_w > w->w ? rs_w : w->w) + 5,
              w->y + (rs_h > w->h ? rs_h : w->h) + 5);
    }
  }

  /* the volume's panel: the slider follows the pointer while held */
  if (volume_drag) {
    if (buttons & 1) { if (y != oy) volume_at(y); }
    else volume_drag = 0;
  }
  if ((changed & 1) && (buttons & 1) && volume_open) {
    if (x >= VP_X && x < VP_X + VP_W && y >= TOP && y < TOP + VP_H) {
      if (y >= VP_T0 - 10 && y <= VP_T1 + 10) { volume_drag = 1; volume_at(y); }
      return;
    }
    volume_open = 0;                               /* a click elsewhere: closed */
    VOLUME_CHANGED();
    if (y < TOP && x >= VOL_X && x < VOL_X + VOL_W) return;
  } else if ((changed & 1) && (buttons & 1) && volume_level >= 0 && !menu_open &&
             y < TOP && x >= VOL_X && x < VOL_X + VOL_W) {
    int got = sound_volume(-1);
    if (got >= 0) volume_level = got;
    volume_open = 1;
    VOLUME_CHANGED();
    return;
  }

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
    } else if (y < TOP) {                          /* a window's tab */
      int slots[MAXWIN], n = tabs(slots), k;
      for (k = 0; k < n; k++) {
	int x0, x1;
	tab_rect(k, n, &x0, &x1);
	if (x >= x0 && x < x1 - 4) set_focus(slots[k]);
      }
    }
    slot = window_at(x, y);
    if (slot >= 0) {
      struct window * w = &win[slot];
      set_focus(slot);
      if (y < w->y) {                              /* the title bar */
	if (x >= w->x + w->w - 20) {               /* the close box: held */
	  closing = slot;
	  compose(w->x + w->w - 20, w->y - TITLE, w->x + w->w, w->y);
	} else if (w->resizable && now_ms() - w->title_click < 400) {
	  w->title_click = 0;                      /* a double click */
	  toggle_maximize(w);
	} else {
	  w->title_click = now_ms();
	  dragging = slot; drag_dx = x - w->x; drag_dy = y - w->y;
	}
      } else if (w->resizable && x >= w->x + w->w - GRIP && y >= w->y + w->h - GRIP &&
		 x < w->x + w->w && y < w->y + w->h) { /* the grip */
	resizing = slot;
	rs_w = w->w; rs_h = w->h;
	rs_dx = w->x + w->w - x;
	rs_dy = w->y + w->h - y;
      }
    }
  }
  if ((changed & 1) && !(buttons & 1) && closing >= 0) {   /* released */
    struct window * w = &win[closing];
    closing = -1;
    compose(w->x + w->w - 20, w->y - TITLE, w->x + w->w, w->y);
    /* closed only if released on the close box: a slip is not a close */
    if (w->used && x >= w->x + w->w - 20 && x < w->x + w->w && y >= w->y - TITLE && y < w->y)
      post_kind(w, EV_CLOSE, 0);
  }
  /* the focused window's: clicks in it, and moves over it (and the one
     that leaves it, so that it stops showing what is under the pointer) */
  if (focus >= 0 && dragging < 0 && resizing < 0) {
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

/* the wheel: to the window under the pointer (positive: down); over the
   volume, or its panel, the volume (5 a notch) */
static void wheel(int dz)
{
  int slot;
  if (!active || dz == 0) return;
  if (volume_level >= 0 && ((py < TOP && px >= VOL_X && px < VOL_X + VOL_W) ||
      (volume_open && px >= VP_X && px < VP_X + VP_W && py < TOP + VP_H))) {
    int v = volume_level - 5 * dz, got;
    if (v < 0) v = 0;
    if (v > 100) v = 100;
    if ((got = sound_volume(v)) >= 0) volume_level = got;
    VOLUME_CHANGED();
    return;
  }
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
#if defined(__i386__) || defined(__x86_64__)
  __asm__ volatile ("inl %%dx, %%eax" : "+a"(a), "+b"(b), "+c"(c), "+d"(d));
#else
  a = b = c = d = 0;                    /* no VMware port: no vmmouse */
#endif
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

/* ---- a virtio tablet (absolute) or mouse (relative) ---- */

static virtio_dev_t vptr;
static virtq_t vptr_q;
static const char * vptr_kind = NULL;
static int vptr_absolute = 0, vptr_max[2] = { 32767, 32767 };

/* virtio-input's event types (Linux's: not displayd's own EV_*) */
#define VEV_SYN 0
#define VEV_KEY 1
#define VEV_REL 2
#define VEV_ABS 3
#define BTN_LEFT 0x110
#define BTN_RIGHT 0x111
#define BTN_MIDDLE 0x112
#define REL_X 0
#define REL_Y 1
#define REL_WHEEL 8
#define CFG_EV_BITS 0x11
#define CFG_ABS_INFO 0x12

static void vptr_select(int sel, int sub)
{
  vptr.device[0] = sel;
  vptr.device[1] = sub;
}

/* does it report events of this type? */
static int vptr_has(virtio_dev_t * d, int type)
{
  d->device[0] = CFG_EV_BITS;
  d->device[1] = type;
  return virtio_config8(d, 2) != 0;
}

#define VPTR_EVENTS 64
struct vev { unsigned short type, code; unsigned int value; };
static struct vev * vev;
static unsigned long vev_phys;

static void * vptr_thread(void * arg)
{
  int sem = IDX(arg), id;
  int x = px, y = py, b = pbuttons, dz = 0;
  for (;;) {
    while ((id = virtq_get(&vptr_q, NULL)) >= 0) {
      struct vev e = vev[id];
      virtq_buf_t buf = { vev_phys + id * sizeof *vev, sizeof *vev, 1 };
      virtq_add(&vptr_q, &buf, 1);
      if (e.type == VEV_ABS && e.code < 2) {
        int v = (int)((long long)e.value * (e.code ? H : W) / (vptr_max[e.code] + 1));
        if (e.code) y = v; else x = v;
      } else if (e.type == VEV_REL && e.code == REL_X) x += (int)e.value;
      else if (e.type == VEV_REL && e.code == REL_Y) y += (int)e.value;
      else if (e.type == VEV_REL && e.code == REL_WHEEL) dz += (int)e.value;
      else if (e.type == VEV_KEY && e.code >= BTN_LEFT && e.code <= BTN_MIDDLE) {
        int bit = e.code == BTN_LEFT ? 1 : e.code == BTN_RIGHT ? 2 : 4;
        b = e.value ? (b | bit) : (b & ~bit);
      } else if (e.type == VEV_SYN) {   /* a report is whole */
        pthread_mutex_lock(&lock);
        pointer_to(x, y, b);
        if (dz) wheel(-dz);
        x = px; y = py; dz = 0;
        pthread_mutex_unlock(&lock);
      }
    }
    virtq_kick(&vptr_q);
    if (sem >= 0) {
      if (mynos_P(sem) < 0) return NULL;
      virtio_isr(&vptr);
      mynos_enableIrq(vptr.irq);
    } else
      mynos_sleep(10000);
  }
  return NULL;
}

/* the first virtio input device with a pointer, if any */
static void vpointer_start(void)
{
  int i, sem;
  pthread_t t;
  for (i = 0; i < 8; i++) {
    if (virtio_find(VIRTIO_INPUT, i, &vptr) < 0) return;
    if (vptr_has(&vptr, VEV_ABS) || vptr_has(&vptr, VEV_REL)) break;
  }
  if (i == 8) return;
  vptr_absolute = vptr_has(&vptr, VEV_ABS);
  if (vptr_absolute) {                 /* the axes' ranges: max at +4 */
    int a;
    for (a = 0; a < 2; a++) {
      vptr_select(CFG_ABS_INFO, a);
      if (virtio_config8(&vptr, 2)) vptr_max[a] = virtio_config32(&vptr, 8 + 4);
      if (vptr_max[a] <= 0) vptr_max[a] = 32767;
    }
  }
  if (virtio_start(&vptr, 0) < 0 || virtq_setup(&vptr, 0, VPTR_EVENTS, &vptr_q) < 0 ||
      (vev = virtio_dma(1, &vev_phys)) == NULL)
    return;
  for (i = 0; i < vptr_q.size; i++) {
    virtq_buf_t b = { vev_phys + i * sizeof *vev, sizeof *vev, 1 };
    virtq_add(&vptr_q, &b, 1);
  }
  virtio_ready(&vptr);
  virtq_kick(&vptr_q);
  sem = mynos_driverRegister("vpointer", vptr.irq | MYNOS_IRQ_PCI, NULL, NULL);
  if (sem >= 0) mynos_enableIrq(vptr.irq);
  vptr_kind = vptr_absolute ? ", virtio tablet" : ", virtio mouse";
  pthread_create(&t, NULL, vptr_thread, ARG(sem));
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

/* the length of the key at s (n bytes left): a UTF-8 character, a
   control character, or a sequence (ESC [ parameters final, ESC O x); a
   read ends with a whole key (consoled queues each at once) */
static int key_length(const unsigned char * s, int n)
{
  int i;
  if (s[0] == 0x1B) {
    if (n >= 3 && s[1] == 'O') return 3;
    if (n < 3 || s[1] != '[') return 1;               /* Escape */
    for (i = 2; i < n && s[i] >= 0x20 && s[i] <= 0x3F; i++) ;
    return i < n ? i + 1 : n;                          /* to the final byte */
  }
  i = s[0] >= 0xF0 ? 4 : s[0] >= 0xE0 ? 3 : s[0] >= 0xC0 ? 2 : 1;
  return i < n ? i : n;
}

static int utf8_put(unsigned int u, char * out)
{
  if (u < 0x80) { out[0] = u; return 1; }
  if (u < 0x800) { out[0] = 0xC0 | (u >> 6); out[1] = 0x80 | (u & 0x3F); return 2; }
  if (u < 0x10000) {
    out[0] = 0xE0 | (u >> 12); out[1] = 0x80 | ((u >> 6) & 0x3F);
    out[2] = 0x80 | (u & 0x3F); return 3;
  }
  out[0] = 0xF0 | (u >> 18); out[1] = 0x80 | ((u >> 12) & 0x3F);
  out[2] = 0x80 | ((u >> 6) & 0x3F); out[3] = 0x80 | (u & 0x3F); return 4;
}

/* a release (ESC [ n ; mod:3 final, CONSOLE_RELEASES): the text its key's
   press sent, into text; 0 if the key is not a release. mod 1: none, 2:
   Shift (an arrow, Home, End: ESC [ 1 ; 2 A...) */
static int release_text(const unsigned char * s, int n, char * text)
{
  unsigned int num = 0;
  int i = 2, mod;
  char final = s[n - 1];
  if (n < 8 || s[0] != 0x1B || s[1] != '[' || s[n - 5] != ';' || s[n - 3] != ':' ||
      s[n - 2] != '3' || s[n - 4] < '1' || s[n - 4] > '9') return 0;
  mod = s[n - 4] - '0';
  for (; i < n - 5; i++) {
    if (s[i] < '0' || s[i] > '9') return 0;
    num = num * 10 + (s[i] - '0');
  }
  if (mod == 1 && final == 'u') text[utf8_put(num, text)] = 0;
  else if (mod == 1 && final == '~') snprintf(text, 32, "\033[%u~", num);
  else if (mod == 1 && final >= 'A' && final <= 'H') snprintf(text, 32, "\033[%c", final);
  else if (final >= 'A' && final <= 'H') snprintf(text, 32, "\033[1;%d%c", mod, final);
  else return 0;
  return 1;
}

static void * keys_thread(void * arg)
{
  struct termios saved, t;
  unsigned char buf[256];
  (void)arg;
  tcgetattr(0, &saved);
  t = saved;
  /* every key goes to the focused window, Ctrl-C too: not an interrupt
     for the program the text console's sh waits for (gui) */
  t.c_lflag &= ~(ICANON | ECHO | ISIG);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 1;                               /* 0.1 s: then look again */
  tcsetattr(0, TCSANOW, &t);
  mynos_consoleKeyReleases(1);
  for (;;) {
    int n = read(0, buf, sizeof buf), i = 0;
    pthread_mutex_lock(&lock);
    if (!active) { pthread_mutex_unlock(&lock); break; }
    while (n > 0 && i < n && focus >= 0) {
      struct event e;
      int len = key_length(buf + i, n - i);
      memset(&e, 0, sizeof e);
      if (release_text(buf + i, len, e.text)) e.kind = EV_KEY_UP;
      else {
        e.kind = EV_KEY;
        memcpy(e.text, buf + i, len < (int)sizeof e.text ? len : (int)sizeof e.text - 1);
      }
      post(&win[focus], &e);
      i += len;
    }
    pthread_mutex_unlock(&lock);
  }
  mynos_consoleKeyReleases(0);
  saved.c_lflag |= ICANON | ECHO;
  tcsetattr(0, TCSANOW, &saved);
  return NULL;
}

/* ---- the timer: ticks, the clock, windows of programs that ended ---- */

/* Every 100 ms; every 10 ms while a window waits for shorter ticks (an
   animation, a game): checked every 100 ms, a tick of 1/60 s came 10
   times a second at most. */
static void * timer_thread(void * arg)
{
  int last_second = -1, ask_volume = 0;
  (void)arg;
  for (;;) {
    int i;
    long now;
    mynos_sleep(now_ms() < fast_until ? 10000 : 100000);
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
      /* the volume, every five seconds: soundd may have come, gone, or
         been changed by another program */
      if (last_second % 5 == 0 && !volume_drag) ask_volume = 1;
    }
    pthread_mutex_unlock(&lock);
    /* asked without the lock: soundd may take its time (up to half a
       second), and the pointer and the windows must not wait for it */
    if (ask_volume) {
      int v = sound_volume(-1);
      ask_volume = 0;
      pthread_mutex_lock(&lock);
      if (v != volume_level && !volume_drag) {
        int was = volume_level;
        volume_level = v;
        if (v < 0) volume_open = 0;
        if ((was < 0) != (v < 0)) compose(0, 0, W, TOP + VP_H + 2);   /* the tabs too */
        else VOLUME_CHANGED();
      }
      pthread_mutex_unlock(&lock);
    }
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
    "V(0:key=S,1:mouse=(x:I,y:I,buttons:I),2:close=U,3:tick=U,4:focus=B,5:wheel=I,"
    "6:key_up=S,7:resize=(width:I,height:I))",
    "The window's next event: keys (UTF-8, VT100 sequences for the others) and their "
    "releases (key_up: the same text), the "
    "mouse in the window (buttons: 1 left, 2 right, 4 middle), close, focus, the "
    "wheel over it (its notches, positive towards the user: down), resize (the size "
    "the user asked for: answer with resize); tick when none "
    "came within timeout_ms (0: wait forever; negative: do not wait). Waits." },
  { 0, "destroy", "window:I", "U", "Close a window." },
  { 0, "set_title", "(window:I,title:S)", "U", "A window's title." },
  { 0, "start", "U", "U", "Start the graphical session: the screen leaves text mode." },
  { 0, "wait_session", "U", "U", "Wait until the graphical session ends. Waits." },
  { 0, "stop", "U", "U", "End the graphical session: windows get close, text mode is back." },
  { 0, "move", "(window:I,x:I,y:I)", "U", "Move a window (its content's top left corner)." },
  { 0, "resize", "(window:I,width:I,height:I)", "U",
    "A window's new size: the same connection then carries a shared message of its "
    "pixels, as attach does, which replaces the old one." },
  { 0, "resizable", "(window:I,min_width:I,min_height:I)", "U",
    "Let the user resize a window (a grip, a double click on the title to maximize), "
    "down to this size; 0: not resizable." },
  { 0, "start_at", "(width:I,height:I)", "U",
    "Start the graphical session with the screen at this size (from 800x600, a width "
    "multiple of 8, within the video memory)." },
  { 1, "sizes", "U", "L<(width:I,height:I)>",
    "The usual screen sizes the video memory holds (start_at takes others too)." },
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
    if (!active) {
      reply_error(ch, "no graphical session: start it with gui"); return;
    }
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
    BAR_CHANGED();
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
    } else if (timeout < 0) {                      /* a poll: tick at once */
      struct event e;
      memset(&e, 0, sizeof e);
      e.kind = EV_TICK;
      reply_event(ch, &e);
    } else {
      w->waiting = ch;
      w->deadline = timeout > 0 ? now_ms() + timeout : 0;
      if (timeout > 0 && timeout < 100) fast_until = now_ms() + 2000;
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
    BAR_CHANGED();
    break;
  }
  case 7: END(); start_session(1024, 768); reply_unit(ch); break;   /* start */
  case 14: {                                       /* sizes */
    static const int usual[][2] = {
      { 800, 600 }, { 1024, 768 }, { 1152, 864 }, { 1280, 720 }, { 1280, 800 },
      { 1280, 960 }, { 1280, 1024 }, { 1360, 768 }, { 1440, 900 }, { 1600, 900 },
      { 1600, 1200 }, { 1680, 1050 }, { 1920, 1080 }, { 1920, 1200 }, { 2560, 1440 },
      { 2560, 1600 }, { 3840, 2160 } };
    int k, n = 0;
    wire_writer o;
    END();
    for (k = 0; k < (int)(sizeof usual / sizeof usual[0]); k++)
      if (!size_refused(usual[k][0], usual[k][1])) n++;
    wire_writer_init(&o);
    wire_reply_ok(&o);
    wire_put_int(&o, n);
    for (k = 0; k < (int)(sizeof usual / sizeof usual[0]); k++)
      if (!size_refused(usual[k][0], usual[k][1])) {
        wire_put_int(&o, usual[k][0]);
        wire_put_int(&o, usual[k][1]);
      }
    send_reply(ch, &o);
    break;
  }
  case 13: {                                       /* start_at */
    int ww = wire_get_int(&r), hh = wire_get_int(&r);
    const char * why;
    END();
    if (active) { reply_unit(ch); break; }
    if ((why = size_refused(ww, hh))) { reply_error(ch, why); break; }
    start_session(ww, hh);
    if (W != ww || H != hh) reply_error(ch, "no memory for the screen");
    else reply_unit(ch);
    break;
  }
  case 8:                                          /* wait_session */
    END();
    if (!active || nwaiters == 16) { reply_unit(ch); break; }
    waiters[nwaiters++] = ch;
    break;
  case 9: END(); reply_unit(ch); end_session(); break;     /* stop */
  case 11: {                                       /* resize */
    mynos_msg_t * m = NULL;
    int wid = wire_get_int(&r), ww = wire_get_int(&r), hh = wire_get_int(&r);
    int ox, oy, ow, oh;
    END();
    if (!(w = owned(ch, wid, caller))) return;
    if (ww < 16 || hh < 16 || ww > W - 2 || hh > H - TOP - TITLE - 2) {
      reply_error(ch, "bad size"); return;
    }
    /* the pixels of the new size: the next message, shared */
    pthread_mutex_unlock(&lock);
    n = mynos_recv(ch, &m, 0, 2000);
    pthread_mutex_lock(&lock);
    if ((int)n < 0 || !m) { reply_error(ch, "resize: no pixels"); return; }
    if (!(w = find(wid)) || m->size < (unsigned)(ww * hh * 4)) {
      mynos_freeMsg(&m);
      reply_error(ch, "resize: not that size");
      return;
    }
    ox = w->x; oy = w->y; ow = w->w; oh = w->h;
    if (w->msg) mynos_freeMsg(&w->msg);
    w->msg = m;
    w->pix = (unsigned int *)m->start;
    w->w = ww; w->h = hh;
    /* on the screen whole: moved up and left if it grew past its edge */
    if (w->x + ww > W - 1) w->x = W - 1 - ww;
    if (w->y + hh > H - 1) w->y = H - 1 - hh;
    if (w->x < 1) w->x = 1;
    if (w->y < TOP + TITLE + 1) w->y = TOP + TITLE + 1;
    reply_unit(ch);
    compose(ox - 1, oy - TITLE - 1, ox + ow + 5, oy + oh + 5);
    compose_window(w);
    BAR_CHANGED();
    break;
  }
  case 12: {                                       /* resizable */
    int wid = wire_get_int(&r), mw = wire_get_int(&r), mh = wire_get_int(&r);
    END();
    if (!(w = owned(ch, wid, caller))) return;
    w->resizable = mw > 0 && mh > 0;
    w->min_w = mw < 16 ? 16 : mw;
    w->min_h = mh < 16 ? 16 : mh;
    reply_unit(ch);
    compose_window(w);
    break;
  }
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

  if (bga_get(0) >= 0xB0C0 && bga_get(0) <= 0xB0CF && (lfb = find_lfb())) {
    /* the video memory, all of it (its size in 64 KB, register 10; 8 MB
       if it does not say), so that any size it holds can be shown */
    vram = (unsigned long)bga_get(10) * 65536;
    if (vram < 4UL << 20 || vram > 64UL << 20) vram = 8UL << 20;
    base = mynos_mapPhysical(lfb, vram / 4096);
    if (!base) {
      mynos_log("displayd: cannot map the frame buffer\n");
      return 1;
    }
    vram_base = (unsigned int *)base;
    fb_rows_skipped = (FB_SKIP + W * 4 - 1) / (W * 4);
    fb = vram_base + fb_rows_skipped * W;
  } else if (vgpu_init() == 0) {
    vgpu = 1;
    lfb = 0;
    vram = 16UL << 20;          /* what dmaAlloc gives in one piece */
  } else {
    mynos_log("displayd: no Bochs VGA (QEMU's standard VGA), no virtio GPU: no graphics\n");
    return 0;                 /* by choice: init does not start it again */
  }
  back = malloc(W * H * 4);
  if (!back) {
    mynos_log("displayd: no memory\n");
    return 1;
  }

  /* the mouse: PS/2 on IRQ 12, and vmmouse if there is one; a virtio
     tablet or mouse too */
  sem = inportb(0x64) == 0xFF ? MYNOS_ERR_INVALID      /* no controller */
                              : mynos_driverRegister("mouse", 12, NULL, NULL);
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
    mynos_log("displayd: no PS/2 mouse (%d)\n", sem);
  vpointer_start();

  pthread_create(&t, NULL, timer_thread, NULL);

  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("displayd: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("displayd: %dx%d (up to %lu MB of video memory), %s, %s%s%s\n",
            W, H, vram >> 20, vgpu ? "virtio GPU" : "Bochs VGA",
	    vmmouse ? "vmmouse (absolute)" : sem >= 0 ? "PS/2 mouse" : "no PS/2 mouse",
	    packet == 4 ? ", wheel" : "", vptr_kind ? vptr_kind : "");

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
