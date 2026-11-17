# displayd: the display server (doc/decisions/gui.md). Needs pthreads:
# dev toolchain only (musl), built by tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: displayd

displayd: displayd.c ../../mynos-lib/lib/libmynos.a
	$(CC) $(CFLAGS) -c displayd.c -o displayd.o
	$(CC) displayd.o -o $@ -lpthread $(LDFLAGS)

clean:
	rm -f *.o displayd
