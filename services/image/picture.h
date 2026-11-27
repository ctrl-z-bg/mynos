/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Pictures decoded (picture.c): JPEG, PNG, GIF, BMP, SVG. */

#ifndef __PICTURE_H__
#define __PICTURE_H__

struct picture {
  int natural_width, natural_height;   /* the picture's own size */
  int width, height;                   /* the pixels' */
  unsigned char * pixels;              /* width x height x 4: blue, green, red, alpha (malloc'd) */
};

/* [data] decoded, at want_w x want_h (0 x 0: its own size): 0, or -1 and
   *err says why */
int picture_decode(const unsigned char * data, int len, int want_w, int want_h, struct picture * out,
                   const char ** err);

/* [data]'s own size, without decoding it: 0, or -1 and *err says why */
int picture_size(const unsigned char * data, int len, int * w, int * h, const char ** err);

#endif
