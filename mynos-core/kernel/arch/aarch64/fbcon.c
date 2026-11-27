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
 * The text console on a Raspberry Pi's screen (MYNOS_RASPI, btq.7): no
 * text mode there, only a framebuffer, which the VideoCore's firmware
 * gives through the mailbox (raspi.c). The kernel's terminal (video.c)
 * writes its cells (a character, an attribute: VGA's text memory, in
 * RAM) as on the PC; after each change (video.c's cursor update) the
 * cells that changed are drawn here, with Terminus's 8x16 glyphs
 * (third_party/fonts, in the kernel's image: font.S), each slot's
 * glyph the character video.c gives it, in VGA's 16 colours. The text
 * screen is 640 x 400 pixels, 80 x 25 cells: the firmware scales it to
 * the display.
 *
 * The graphical session (displayd) asks for the screen with native call
 * 104: a framebuffer of its size, whose address it maps; meanwhile the
 * text is kept in the cells, not drawn, and drawn again when it gives
 * the screen back.
 */

#ifdef MYNOS_RASPI

#include "global.h"
#include "layout.h"
#include "video.h"
#include "kutils.h"
#include "process.h"
#include "mynos.h"
#include "mem/mem.h"

int raspi_mbox(volatile uint32_t * buf);
ulong32_t video_glyph_char(unsigned char slot);

#define TEXT_W (COLUMNS * 8)
#define TEXT_H (ROWS * 16)

extern const unsigned char font_psf[], font_psf_end[];
static unsigned char glyphs[256][16];

static volatile uint32_t * fb;          /* NULL: no screen */
static uint32_t fb_w, fb_h, fb_pitch;   /* (the pitch in pixels) */
static paddr_t fb_phys;
static uint32_t fb_bytes;
static int text_on = 0;                 /* the console is drawn */
static unsigned short shadow[ROWS * COLUMNS];
static int shadow_ok = 0;
static int cur_r = ROWS, cur_c = 0;     /* the cursor drawn */

static const uint32_t palette[16] = {
  0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
  0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF
};

static volatile uint32_t mb[64] __attribute__((aligned(16)));

/* a framebuffer of w x h, 32 bits a pixel (0x00RRGGBB): 0 if given */
static int fb_set(uint32_t w, uint32_t h)
{
  int i = 0;
  mb[i++] = 0;                    /* the size, below */
  mb[i++] = 0;
  mb[i++] = 0x48003; mb[i++] = 8; mb[i++] = 0; mb[i++] = w; mb[i++] = h;  /* physical */
  mb[i++] = 0x48004; mb[i++] = 8; mb[i++] = 0; mb[i++] = w; mb[i++] = h;  /* virtual */
  mb[i++] = 0x48009; mb[i++] = 8; mb[i++] = 0; mb[i++] = 0; mb[i++] = 0;  /* offset */
  mb[i++] = 0x48005; mb[i++] = 4; mb[i++] = 0; mb[i++] = 32;             /* depth */
  mb[i++] = 0x48006; mb[i++] = 4; mb[i++] = 0; mb[i++] = 0;              /* BGR in memory */
  mb[i++] = 0x40001; mb[i++] = 8; mb[i++] = 0; mb[i++] = 4096; mb[i++] = 0;  /* allocate */
  mb[i++] = 0x40008; mb[i++] = 4; mb[i++] = 0; mb[i++] = 0;              /* pitch */
  mb[i++] = 0;
  mb[0] = i * 4;
  if (raspi_mbox(mb) != 0) return -1;
  /* the answers: the size (5, 6), the depth (20), the buffer (28, 29),
     the pitch (33) */
  if (mb[28] == 0 || mb[20] != 32) return -1;
  fb_w = mb[5];
  fb_h = mb[6];
  fb_phys = mb[28] & 0x3FFFFFFF;          /* a bus address: the ARM's */
  fb_bytes = mb[29];
  fb_pitch = mb[33] / 4;
  fb = DEVICE(fb_phys);
  return 0;
}

static void draw_cell(int r, int c, unsigned short v)
{
  const unsigned char * g = glyphs[v & 0xFF];
  uint32_t fg = palette[(v >> 8) & 15], bg = palette[(v >> 12) & 7];
  volatile uint32_t * p = fb + (uint32_t)r * 16 * fb_pitch + (uint32_t)c * 8;
  int y, x;
  for (y = 0; y < 16; y++, p += fb_pitch) {
    unsigned char bits = g[y];
    for (x = 0; x < 8; x++) p[x] = (bits & (0x80 >> x)) ? fg : bg;
  }
}

static void draw_cursor(int r, int c, unsigned short v)
{
  uint32_t fg = palette[(v >> 8) & 15];
  volatile uint32_t * p = fb + ((uint32_t)r * 16 + 14) * fb_pitch + (uint32_t)c * 8;
  int y, x;
  for (y = 0; y < 2; y++, p += fb_pitch)
    for (x = 0; x < 8; x++) p[x] = fg;
}

/* after a change of the cells (video.c): those that changed, drawn; the
   cursor (at row, col; row ROWS: none) */
void arch_text_sync(const unsigned char * cells, int row, int col)
{
  int i;
  if (!fb || !text_on) return;
  for (i = 0; i < ROWS * COLUMNS; i++) {
    unsigned short v = cells[2 * i] | (unsigned short)cells[2 * i + 1] << 8;
    if (!shadow_ok || v != shadow[i] ||
        (i == cur_r * COLUMNS + cur_c && (row != cur_r || col != cur_c))) {
      shadow[i] = v;
      draw_cell(i / COLUMNS, i % COLUMNS, v);
      if (i == cur_r * COLUMNS + cur_c) cur_r = ROWS;   /* drawn over */
    }
  }
  shadow_ok = 1;
  if (row < ROWS && col < COLUMNS && (row != cur_r || col != cur_c)) {
    draw_cursor(row, col, shadow[row * COLUMNS + col]);
  }
  cur_r = row;
  cur_c = col;
}

/* the glyphs of the 256 slots, from the PSF's Unicode table */
static void glyphs_init(void)
{
  const unsigned char * f = font_psf;
  unsigned int n = (f[2] & 1) ? 512 : 256, size = f[3], g, s;
  const unsigned char * table = f + 4 + n * size;
  for (s = 0; s < 256; s++) {
    ulong32_t u = video_glyph_char((unsigned char)s);
    const unsigned char * t = table;
    if (s == 0 || s == ' ') { kbzero(glyphs[s], 16); continue; }
    kbzero(glyphs[s], 16);
    for (g = 0; g < n && t + 1 < font_psf_end; g++) {
      int found = 0;
      for (;;) {
        unsigned int v = t[0] | t[1] << 8;
        t += 2;
        if (v == 0xFFFF) break;
        if (v == u) found = 1;
      }
      if (found) {
        int y;
        for (y = 0; y < 16 && y < (int)size; y++) glyphs[s][y] = f[4 + g * size + y];
        break;
      }
    }
  }
}

/* at boot (dtb.c): the text screen, if the firmware gives one */
void raspi_fb_init(void)
{
  glyphs_init();
  if (fb_set(TEXT_W, TEXT_H) == 0) text_on = 1;
}

/* native call 104 (displayd, the io privilege): op 0, the screen for
   the graphical session at w x h: its address, size and pitch (bytes)
   in out[0..2] (a user's three longs), the console no more drawn; op 1,
   the screen back to the console, drawn again; op 2, 0 if there is a
   screen */
long raspi_fb_call(long op, long w, long h, unsigned long * out)
{
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO)) return MYNOS_ERR_DENY;
  if (op == 0) {
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return MYNOS_ERR_INVALID;
    if (!__mem_userArea(out, 3 * sizeof *out)) return MYNOS_ERR_INVALID;
    text_on = 0;
    if (fb_set((uint32_t)w, (uint32_t)h) != 0) {
      if (fb_set(TEXT_W, TEXT_H) == 0) { text_on = 1; shadow_ok = 0; }
      return MYNOS_ERR_INVALID;
    }
    out[0] = fb_phys;
    out[1] = fb_bytes;
    out[2] = fb_pitch * 4;
    return 0;
  }
  if (op == 2) return fb ? 0 : MYNOS_ERR_INVALID;     /* is there a screen */
  if (op == 1) {
    if (fb_set(TEXT_W, TEXT_H) != 0) return MYNOS_ERR_INVALID;
    text_on = 1;
    shadow_ok = 0;
    cur_r = ROWS;
    return 0;
  }
  return MYNOS_ERR_INVALID;
}

#endif
