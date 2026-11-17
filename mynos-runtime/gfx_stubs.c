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
 * The primitives of module Gfx (mynos-lib/ocaml/gfx.mli;
 * doc/decisions/gui.md): drawing on buffers of 32-bit pixels (0xRRGGBB),
 * in C because OCaml bytecode is too slow for loops over pixels. A buffer
 * is the OCaml record { pixels : int32 Bigarray; width; height }, its
 * pixels page aligned so that they can be shared with the display server.
 * Text uses the Terminus 8x16 font of the RAM disk.
 */

#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/signals.h>
#include <mynos.h>

#define FONT "/terminus16.psf"
#define FONT_BOLD "/terminus16-bold.psf"

/* ---- buffers ---- */

#define PIX(t) ((unsigned int *)Caml_ba_data_val(Field(t, 0)))
#define BW(t) Long_val(Field(t, 1))
#define BH(t) Long_val(Field(t, 2))

CAMLprim value caml_gfx_alloc(value w, value h)
{
  long n = Long_val(w) * Long_val(h), size;
  void * p;
  if (Long_val(w) <= 0 || Long_val(h) <= 0 || n > 4096L * 4096L)
    caml_invalid_argument("Gfx.create");
  size = (n * 4 + 4095) & ~4095L;
  if (posix_memalign(&p, 4096, size)) caml_raise_out_of_memory();
  memset(p, 0xFF, size);
  return caml_ba_alloc_dims(CAML_BA_INT32 | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 1, p, n);
}

CAMLprim value caml_gfx_fill(value t, value x, value y, value w, value h, value c)
{
  int x0 = Long_val(x), y0 = Long_val(y), x1 = x0 + Long_val(w), y1 = y0 + Long_val(h);
  int bw = BW(t), bh = BH(t), i, j;
  unsigned int col = Long_val(c), * p = PIX(t);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > bw) x1 = bw;
  if (y1 > bh) y1 = bh;
  for (j = y0; j < y1; j++)
    for (i = x0; i < x1; i++) p[j * bw + i] = col;
  return Val_unit;
}

CAMLprim value caml_gfx_fill_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_fill(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}

CAMLprim value caml_gfx_get(value t, value x, value y)
{
  int bx = Long_val(x), by = Long_val(y);
  if (bx < 0 || by < 0 || bx >= BW(t) || by >= BH(t)) return Val_long(-1);
  return Val_long(PIX(t)[by * BW(t) + bx] & 0xFFFFFF);
}

static void plot(value t, int x, int y, unsigned int c)
{
  if (x >= 0 && y >= 0 && x < BW(t) && y < BH(t)) PIX(t)[y * BW(t) + x] = c;
}

/* a line, Bresenham's */
CAMLprim value caml_gfx_line(value t, value vx0, value vy0, value vx1, value vy1, value c)
{
  int x0 = Long_val(vx0), y0 = Long_val(vy0), x1 = Long_val(vx1), y1 = Long_val(vy1);
  int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
  int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
  int err = dx + dy;
  unsigned int col = Long_val(c);
  for (;;) {
    int e2;
    plot(t, x0, y0, col);
    if (x0 == x1 && y0 == y1) break;
    e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
  return Val_unit;
}

CAMLprim value caml_gfx_line_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_line(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
}

/* copy a rectangle from src to dst (the same buffer too: overlapping rows
   are moved in the right order) */
CAMLprim value caml_gfx_blit(value src, value vsx, value vsy, value dst, value vdx,
			     value vdy, value vw, value vh)
{
  int sx = Long_val(vsx), sy = Long_val(vsy), dx = Long_val(vdx), dy = Long_val(vdy);
  int w = Long_val(vw), h = Long_val(vh), r;
  int sw = BW(src), sh = BH(src), dw = BW(dst), dh = BH(dst);
  unsigned int * s = PIX(src), * d = PIX(dst);
  if (sx < 0) { w += sx; dx -= sx; sx = 0; }
  if (sy < 0) { h += sy; dy -= sy; sy = 0; }
  if (dx < 0) { w += dx; sx -= dx; dx = 0; }
  if (dy < 0) { h += dy; sy -= dy; dy = 0; }
  if (sx + w > sw) w = sw - sx;
  if (dx + w > dw) w = dw - dx;
  if (sy + h > sh) h = sh - sy;
  if (dy + h > dh) h = dh - dy;
  if (w <= 0 || h <= 0) return Val_unit;
  if (s == d && dy > sy)
    for (r = h - 1; r >= 0; r--)
      memmove(d + (dy + r) * dw + dx, s + (sy + r) * sw + sx, w * 4);
  else
    for (r = 0; r < h; r++)
      memmove(d + (dy + r) * dw + dx, s + (sy + r) * sw + sx, w * 4);
  return Val_unit;
}

CAMLprim value caml_gfx_blit_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_blit(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
		       argv[6], argv[7]);
}

/* ---- text ---- */

static unsigned char glyphs[2][512 * 16];
static unsigned short * glyph_of;      /* 65536 entries; 0xFFFF: none */
static int font_state = 0;             /* 0: not read, 1: ok, -1: none */

static int load_one(int which, const char * path)
{
  static unsigned char data[16384];
  int fd = open(path, O_RDONLY), n, i, g, nglyphs;
  if (fd < 0) return -1;
  n = read(fd, data, sizeof data);
  close(fd);
  if (n < 4 || data[0] != 0x36 || data[1] != 0x04 || data[3] != 16) return -1;
  nglyphs = (data[2] & 1) ? 512 : 256;
  if (n < 4 + nglyphs * 16) return -1;
  memcpy(glyphs[which], data + 4, nglyphs * 16);
  if (which == 0 && (data[2] & 2)) {
    i = 4 + nglyphs * 16;
    for (g = 0; g < nglyphs && i + 1 < n; g++)
      for (;;) {
	unsigned int u = data[i] | (data[i + 1] << 8);
	i += 2;
	if (u == 0xFFFF || i + 1 >= n) break;
	if (u == 0xFFFE) {
	  while (i + 1 < n && (data[i] | (data[i + 1] << 8)) != 0xFFFF) i += 2;
	  continue;
	}
	if (glyph_of[u] == 0xFFFF) glyph_of[u] = g;
      }
  }
  return 0;
}

static int font(void)
{
  if (font_state == 0) {
    int i;
    glyph_of = malloc(65536 * sizeof *glyph_of);
    if (!glyph_of) return 0;
    for (i = 0; i < 65536; i++) glyph_of[i] = 0xFFFF;
    font_state = load_one(0, FONT) == 0 ? 1 : -1;
    if (font_state == 1 && load_one(1, FONT_BOLD) != 0)
      memcpy(glyphs[1], glyphs[0], sizeof glyphs[0]);
  }
  return font_state == 1;
}

static int glyph_index(unsigned int u)
{
  if (u < 65536 && glyph_of[u] != 0xFFFF) return glyph_of[u];
  if (glyph_of[0xFFFD] != 0xFFFF) return glyph_of[0xFFFD];
  return glyph_of['?'] != 0xFFFF ? glyph_of['?'] : '?';
}

/* UTF-8 text at (x, y) (its top left), at most max cells: the cells */
CAMLprim value caml_gfx_text(value t, value vx, value vy, value s, value c,
			     value bold, value vmax)
{
  int x = Long_val(vx), y = Long_val(vy), max = Long_val(vmax), cells = 0;
  int bw = BW(t), bh = BH(t), b = Bool_val(bold);
  unsigned int col = Long_val(c), * p = PIX(t);
  const unsigned char * q = (const unsigned char *)String_val(s);
  const unsigned char * end = q + caml_string_length(s);
  if (!font()) return Val_long(0);
  while (q < end && cells < max) {
    unsigned int u = *q++;
    int g, r, k, gx = x + 8 * cells;
    if (u >= 0xC0) {
      int more = u >= 0xF0 ? 3 : u >= 0xE0 ? 2 : 1;
      u &= 0x3F >> more;
      while (more-- && q < end && (*q & 0xC0) == 0x80) u = (u << 6) | (*q++ & 0x3F);
    }
    cells++;
    if (gx >= bw || gx + 8 <= 0 || y >= bh || y + 16 <= 0) continue;
    g = glyph_index(u);
    for (r = 0; r < 16; r++) {
      unsigned char bits = glyphs[b][g * 16 + r];
      int yy = y + r;
      if (!bits || yy < 0 || yy >= bh) continue;
      for (k = 0; k < 8; k++)
	if ((bits & (0x80 >> k)) && gx + k >= 0 && gx + k < bw)
	  p[yy * bw + gx + k] = col;
    }
  }
  return Val_long(cells);
}

CAMLprim value caml_gfx_text_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_text(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
}

/* ---- sharing ---- */

/* send the buffer's pixels on a channel, shared (MYNOS_IPC_SHARED): the
   receiver sees the same memory from then on */
CAMLprim value caml_gfx_send_shared(value ch, value t)
{
  CAMLparam2(ch, t);
  int ret;
  void * p = PIX(t);
  unsigned int n = BW(t) * BH(t) * 4;
  caml_enter_blocking_section();
  ret = mynos_send(Int_val(ch), p, n, MYNOS_IPC_SHARED);
  caml_leave_blocking_section();
  if (ret < 0) caml_failwith("Gfx: cannot share the buffer");
  CAMLreturn(Val_unit);
}
