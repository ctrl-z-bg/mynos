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
 * picture: imaged's decoding, as a command on the host (Linux), for the
 * tools that render pages there (ariadne/tests/render.ml):
 *   picture FILE WIDTH HEIGHT OUT
 * writes OUT: a line "natural_width natural_height width height", then the
 * pixels (4 bytes each: blue, green, red, alpha). Exit 1 and a message if
 * FILE is not a picture.
 */

#include <stdio.h>
#include <stdlib.h>
#include "picture.h"

int main(int argc, char ** argv)
{
  FILE * f;
  long n;
  unsigned char * data;
  struct picture p;
  const char * err = "";
  if (argc != 5) { fprintf(stderr, "usage: picture FILE WIDTH HEIGHT OUT\n"); return 2; }
  f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
  data = malloc(n > 0 ? n : 1);
  if (!data || fread(data, 1, n, f) != (size_t)n) { fprintf(stderr, "picture: cannot read %s\n", argv[1]); return 1; }
  fclose(f);
  if (picture_decode(data, (int)n, atoi(argv[2]), atoi(argv[3]), &p, &err) < 0) {
    fprintf(stderr, "picture: %s: %s\n", argv[1], err);
    return 1;
  }
  f = fopen(argv[4], "wb");
  if (!f) { perror(argv[4]); return 1; }
  fprintf(f, "%d %d %d %d\n", p.natural_width, p.natural_height, p.width, p.height);
  fwrite(p.pixels, 4, (size_t)p.width * p.height, f);
  fclose(f);
  return 0;
}
