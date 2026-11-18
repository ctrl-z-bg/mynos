#!/bin/sh
# The logo of the graphical session, from the 2003 website's drawing
# (doc/website/img/mynos-logo.jpg), as PGM masks (Gfx.load_mask): grey
# levels, 0 the ink, 255 the paper. MyNOS reads no JPEG, and the build
# container has no image tools: run this on the host (ImageMagick) when
# the drawing changes; the .pgm files are kept in the repository.
set -eu
cd "$(dirname "$0")"
src=../doc/website/img/mynos-logo.jpg
# the paper to white and the ink to black, JPEG's noise out
convert "$src" -colorspace Gray -level 20%,80% -depth 8 -strip mynos-logo.pgm
convert "$src" -colorspace Gray -filter Lanczos -resize 200% -level 20%,80% -depth 8 -strip mynos-logo-2x.pgm
