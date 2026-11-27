# imaged: the picture service (JPEG, PNG, GIF, BMP with stb_image, SVG with
# NanoSVG; doc/decisions/browser.md, M4), and picture, its decoding as a
# command for the host's tools (built with the host's cc: make picture).
# Built by tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: imaged

picture.o: picture.c picture.h ../../third_party/stb/stb_image.h ../../third_party/nanosvg/nanosvg.h \
	../../third_party/nanosvg/nanosvgrast.h
	$(CC) $(CFLAGS) -Wno-unused-function -c picture.c -o $@

imaged: imaged.c picture.o ../../mynos-lib/lib/libmynos.a
	$(CC) $(CFLAGS) -c imaged.c -o imaged.o
	$(CC) imaged.o picture.o -o $@ -lm $(LDFLAGS)

# the host's: for ariadne/tests/render.ml
picture: picture_tool.c picture.c picture.h
	cc -O2 -Wall -Wno-unused-function -o $@ picture_tool.c picture.c -lm

clean:
	rm -f *.o imaged picture
