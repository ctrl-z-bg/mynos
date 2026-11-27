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
 * Pictures decoded: JPEG (baseline and progressive), PNG, GIF (its first
 * frame) and BMP by stb_image, SVG by NanoSVG (third_party/stb,
 * third_party/nanosvg); scaled to the size asked for (an SVG drawn at it,
 * sharp). The pixels come out as Gfx's buffers hold theirs: 4 bytes a
 * pixel, blue, green, red, alpha (255: opaque), not premultiplied.
 * No MyNOS here: imaged (the service) and picture (the host's tool) use it.
 */

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "picture.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#define STBI_NO_SIMD
#define STBI_MAX_DIMENSIONS 16384
#include "../../third_party/stb/stb_image.h"

#define NANOSVG_IMPLEMENTATION
#include "../../third_party/nanosvg/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "../../third_party/nanosvg/nanosvgrast.h"

/* the most pixels a picture may have, decoded or asked for: 16 M (64 MB) */
#define MAX_PIXELS (16 * 1024 * 1024)

/* an SVG file: its text starts (after a BOM, spaces, an XML declaration,
   comments) with an svg element within its first 4 KB */
static int is_svg(const unsigned char * d, int n)
{
  int i, lim = n < 4096 ? n : 4096;
  for (i = 0; i < lim && (d[i] == ' ' || d[i] == '\t' || d[i] == '\r' || d[i] == '\n' || d[i] >= 0xEF); i++)
    ;
  if (i >= lim || d[i] != '<') return 0;
  for (; i + 4 <= lim; i++)
    if (!memcmp(d + i, "<svg", 4)) return 1;
  return 0;
}

/* RGBA, w x h, to tw x th: the average of the source pixels each covers
   (weighted by their alpha) when smaller, the nearest when larger */
static unsigned char * scale(const unsigned char * src, int w, int h, int tw, int th)
{
  unsigned char * dst = malloc((size_t)tw * th * 4);
  int x, y;
  if (!dst) return NULL;
  for (y = 0; y < th; y++) {
    int y0 = (int)((long long)y * h / th), y1 = (int)((long long)(y + 1) * h / th);
    if (y1 <= y0) y1 = y0 + 1;
    if (y1 > h) y1 = h;
    for (x = 0; x < tw; x++) {
      int x0 = (int)((long long)x * w / tw), x1 = (int)((long long)(x + 1) * w / tw), sx, sy;
      unsigned long r = 0, g = 0, b = 0, a = 0, k = 0;
      unsigned char * o = dst + ((size_t)y * tw + x) * 4;
      if (x1 <= x0) x1 = x0 + 1;
      if (x1 > w) x1 = w;
      for (sy = y0; sy < y1; sy++)
        for (sx = x0; sx < x1; sx++) {
          const unsigned char * p = src + ((size_t)sy * w + sx) * 4;
          r += p[0] * p[3]; g += p[1] * p[3]; b += p[2] * p[3]; a += p[3]; k++;
        }
      if (a) { o[0] = r / a; o[1] = g / a; o[2] = b / a; o[3] = a / k; }
      else o[0] = o[1] = o[2] = o[3] = 0;
    }
  }
  return dst;
}

int picture_decode(const unsigned char * data, int len, int want_w, int want_h, struct picture * out,
                   const char ** err)
{
  unsigned char * rgba;
  int tw, th, i;
  memset(out, 0, sizeof *out);
  if (want_w < 0 || want_h < 0) { *err = "a negative size"; return -1; }
  if (is_svg(data, len)) {
    NSVGimage * img;
    NSVGrasterizer * r;
    float w, h, s, sx, sy;
    char * text = malloc((size_t)len + 1);
    if (!text) { *err = "out of memory"; return -1; }
    memcpy(text, data, len);
    text[len] = 0;
    img = nsvgParse(text, "px", 96.0f);        /* it writes into the text */
    free(text);
    if (!img) { *err = "not an SVG picture NanoSVG reads"; return -1; }
    w = img->width; h = img->height;
    if (w <= 0 || h <= 0) { w = 300; h = 150; }
    out->natural_width = (int)ceilf(w); out->natural_height = (int)ceilf(h);
    tw = want_w > 0 ? want_w : out->natural_width;
    th = want_h > 0 ? want_h : out->natural_height;
    if ((long long)tw * th > MAX_PIXELS) { nsvgDelete(img); *err = "too many pixels"; return -1; }
    /* scaled to fit, centred (SVG's xMidYMid meet) */
    sx = tw / w; sy = th / h;
    s = sx < sy ? sx : sy;
    rgba = calloc((size_t)tw * th, 4);
    r = nsvgCreateRasterizer();
    if (!rgba || !r) { free(rgba); nsvgDelete(img); *err = "out of memory"; return -1; }
    nsvgRasterize(r, img, (tw - w * s) / 2, (th - h * s) / 2, s, rgba, tw, th, tw * 4);
    nsvgDeleteRasterizer(r);
    nsvgDelete(img);
  } else {
    int w, h, n;
    if (!stbi_info_from_memory(data, len, &w, &h, &n)) {
      *err = stbi_failure_reason() ? stbi_failure_reason() : "not a picture";
      return -1;
    }
    if ((long long)w * h > MAX_PIXELS) { *err = "too many pixels"; return -1; }
    rgba = stbi_load_from_memory(data, len, &w, &h, &n, 4);
    if (!rgba) { *err = stbi_failure_reason() ? stbi_failure_reason() : "not a picture"; return -1; }
    out->natural_width = w; out->natural_height = h;
    tw = want_w > 0 ? want_w : w;
    th = want_h > 0 ? want_h : h;
    if ((long long)tw * th > MAX_PIXELS) { stbi_image_free(rgba); *err = "too many pixels"; return -1; }
    if (tw != w || th != h) {
      unsigned char * s2 = scale(rgba, w, h, tw, th);
      stbi_image_free(rgba);
      if (!s2) { *err = "out of memory"; return -1; }
      rgba = s2;
    } else {
      /* stb's buffer, ours to free with free() from now on: a copy */
      unsigned char * c = malloc((size_t)w * h * 4);
      if (!c) { stbi_image_free(rgba); *err = "out of memory"; return -1; }
      memcpy(c, rgba, (size_t)w * h * 4);
      stbi_image_free(rgba);
      rgba = c;
    }
  }
  /* RGBA to BGRA */
  for (i = 0; i < tw * th; i++) {
    unsigned char t = rgba[i * 4];
    rgba[i * 4] = rgba[i * 4 + 2];
    rgba[i * 4 + 2] = t;
  }
  out->width = tw; out->height = th; out->pixels = rgba;
  return 0;
}

int picture_size(const unsigned char * data, int len, int * w, int * h, const char ** err)
{
  int n;
  if (is_svg(data, len)) {
    NSVGimage * img;
    char * text = malloc((size_t)len + 1);
    if (!text) { *err = "out of memory"; return -1; }
    memcpy(text, data, len);
    text[len] = 0;
    img = nsvgParse(text, "px", 96.0f);
    free(text);
    if (!img) { *err = "not an SVG picture NanoSVG reads"; return -1; }
    if (img->width > 0 && img->height > 0) { *w = (int)ceilf(img->width); *h = (int)ceilf(img->height); }
    else { *w = 300; *h = 150; }
    nsvgDelete(img);
    return 0;
  }
  if (!stbi_info_from_memory(data, len, w, h, &n)) {
    *err = stbi_failure_reason() ? stbi_failure_reason() : "not a picture";
    return -1;
  }
  return 0;
}
