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

/* the clip: every primitive draws only inside it (and the buffer).
   Gfx.with_clip sets it, nested ones intersected on the OCaml side. One
   per thread, so each domain has its own (the OCaml side keeps its list
   per domain): a domain's clip does not cut another's drawing */
static __thread int clip_on = 0, clip_x0, clip_y0, clip_x1, clip_y1;

CAMLprim value caml_gfx_set_clip(value x, value y, value w, value h)
{
  clip_on = 1;
  clip_x0 = Long_val(x); clip_y0 = Long_val(y);
  clip_x1 = clip_x0 + Long_val(w); clip_y1 = clip_y0 + Long_val(h);
  return Val_unit;
}

CAMLprim value caml_gfx_no_clip(value unit)
{
  (void)unit;
  clip_on = 0;
  return Val_unit;
}

/* where t may be drawn on */
static void bounds(value t, int * x0, int * y0, int * x1, int * y1)
{
  *x0 = 0; *y0 = 0; *x1 = BW(t); *y1 = BH(t);
  if (clip_on) {
    if (clip_x0 > *x0) *x0 = clip_x0;
    if (clip_y0 > *y0) *y0 = clip_y0;
    if (clip_x1 < *x1) *x1 = clip_x1;
    if (clip_y1 < *y1) *y1 = clip_y1;
  }
}

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
  int bw = BW(t), i, j, bx0, by0, bx1, by1;
  unsigned int col = Long_val(c), * p = PIX(t);
  bounds(t, &bx0, &by0, &bx1, &by1);
  if (x0 < bx0) x0 = bx0;
  if (y0 < by0) y0 = by0;
  if (x1 > bx1) x1 = bx1;
  if (y1 > by1) y1 = by1;
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
  int x0, y0, x1, y1;
  bounds(t, &x0, &y0, &x1, &y1);
  if (x >= x0 && y >= y0 && x < x1 && y < y1) PIX(t)[y * BW(t) + x] = c;
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
  if (clip_on) {                       /* the destination, within the clip */
    if (dx < clip_x0) { w -= clip_x0 - dx; sx += clip_x0 - dx; dx = clip_x0; }
    if (dy < clip_y0) { h -= clip_y0 - dy; sy += clip_y0 - dy; dy = clip_y0; }
    if (dx + w > clip_x1) w = clip_x1 - dx;
    if (dy + h > clip_y1) h = clip_y1 - dy;
  }
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

/* ---- masks: an image as ink of one colour (Gfx.draw_mask) ---- */

/* the mask is a string of grey levels, w x h, 0 the ink and 255 the paper;
   each pixel takes colour as much as there is ink, times opacity/255 */
CAMLprim value caml_gfx_draw_mask(value t, value vx, value vy, value ink, value vw,
				  value vh, value c, value vopacity)
{
  int x = Long_val(vx), y = Long_val(vy), w = Long_val(vw), h = Long_val(vh);
  int opacity = Long_val(vopacity), bw = BW(t), bx0, by0, bx1, by1, i, j;
  unsigned int col = Long_val(c), * p = PIX(t);
  const unsigned char * m = (const unsigned char *)String_val(ink);
  int cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255;
  if (caml_string_length(ink) < (mlsize_t)(w * h)) caml_invalid_argument("Gfx.draw_mask");
  bounds(t, &bx0, &by0, &bx1, &by1);
  for (j = 0; j < h; j++) {
    int yy = y + j;
    if (yy < by0 || yy >= by1) continue;
    for (i = 0; i < w; i++) {
      int xx = x + i, a;
      unsigned int d;
      if (xx < bx0 || xx >= bx1) continue;
      a = (255 - m[j * w + i]) * opacity / 255;
      if (a == 0) continue;
      d = p[yy * bw + xx];
      p[yy * bw + xx] =
	((((d >> 16) & 255) * (255 - a) + cr * a) / 255) << 16 |
	((((d >> 8) & 255) * (255 - a) + cg * a) / 255) << 8 |
	(((d & 255) * (255 - a) + cb * a) / 255);
    }
  }
  return Val_unit;
}

CAMLprim value caml_gfx_draw_mask_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_draw_mask(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
			    argv[6], argv[7]);
}

/* ---- pictures: 4 bytes a pixel, blue, green, red, alpha (Gfx.draw_image) ---- */

/* the picture (w x h, in a string) with its top left at (x, y), each pixel
   blended by its alpha times opacity/255; with a tint (>= 0, 0xRRGGBB) its
   alpha only, in that colour (a mask) */
CAMLprim value caml_gfx_draw_image(value t, value vx, value vy, value px, value vw,
				   value vh, value vopacity, value vtint)
{
  int x = Long_val(vx), y = Long_val(vy), w = Long_val(vw), h = Long_val(vh);
  int opacity = Long_val(vopacity), bw = BW(t), bx0, by0, bx1, by1, i, j, i0, i1;
  long tint = Long_val(vtint);
  unsigned char tb = tint & 255, tg = (tint >> 8) & 255, tr = (tint >> 16) & 255;
  unsigned int * p = PIX(t);
  const unsigned char * s = (const unsigned char *)String_val(px);
  if (w < 0 || h < 0 || caml_string_length(px) < (mlsize_t)w * h * 4)
    caml_invalid_argument("Gfx.draw_image");
  bounds(t, &bx0, &by0, &bx1, &by1);
  i0 = bx0 - x > 0 ? bx0 - x : 0;
  i1 = bx1 - x < w ? bx1 - x : w;
  for (j = 0; j < h; j++) {
    int yy = y + j;
    unsigned int * row;
    const unsigned char * q;
    if (yy < by0 || yy >= by1) continue;
    row = p + yy * bw + x;
    q = s + ((size_t)j * w) * 4;
    for (i = i0; i < i1; i++) {
      const unsigned char * c = q + i * 4;
      unsigned char tinted[4];
      int a = opacity == 255 ? c[3] : c[3] * opacity / 255;
      unsigned int d;
      if (a == 0) continue;
      if (tint >= 0) { tinted[0] = tb; tinted[1] = tg; tinted[2] = tr; c = tinted; }
      if (a == 255) { row[i] = (c[2] << 16) | (c[1] << 8) | c[0]; continue; }
      d = row[i];
      row[i] =
	((((d >> 16) & 255) * (255 - a) + c[2] * a) / 255) << 16 |
	((((d >> 8) & 255) * (255 - a) + c[1] * a) / 255) << 8 |
	(((d & 255) * (255 - a) + c[0] * a) / 255);
    }
  }
  return Val_unit;
}

CAMLprim value caml_gfx_draw_image_byte(value * argv, int argn)
{
  (void)argn;
  return caml_gfx_draw_image(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7]);
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
  /* max may be max_int, wider than an int on 64 bits */
  long lmax = Long_val(vmax);
  int x = Long_val(vx), y = Long_val(vy), cells = 0;
  int max = lmax > 0x7FFFFFFF ? 0x7FFFFFFF : (int)lmax;
  int bw = BW(t), b = Bool_val(bold), bx0, by0, bx1, by1;
  unsigned int col = Long_val(c), * p = PIX(t);
  const unsigned char * q = (const unsigned char *)String_val(s);
  const unsigned char * end = q + caml_string_length(s);
  if (!font()) return Val_long(0);
  bounds(t, &bx0, &by0, &bx1, &by1);
  while (q < end && cells < max) {
    unsigned int u = *q++;
    int g, r, k, gx = x + 8 * cells;
    if (u >= 0xC0) {
      int more = u >= 0xF0 ? 3 : u >= 0xE0 ? 2 : 1;
      u &= 0x3F >> more;
      while (more-- && q < end && (*q & 0xC0) == 0x80) u = (u << 6) | (*q++ & 0x3F);
    }
    cells++;
    if (gx >= bx1 || gx + 8 <= bx0 || y >= by1 || y + 16 <= by0) continue;
    g = glyph_index(u);
    for (r = 0; r < 16; r++) {
      unsigned char bits = glyphs[b][g * 16 + r];
      int yy = y + r;
      if (!bits || yy < by0 || yy >= by1) continue;
      for (k = 0; k < 8; k++)
	if ((bits & (0x80 >> k)) && gx + k >= bx0 && gx + k < bx1)
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
