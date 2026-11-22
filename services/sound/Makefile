# soundd: the sound server, a Sound Blaster 16's driver and a mixer
# (mynos-7jn). Needs pthreads: dev toolchain only (musl), built by
# tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: soundd

soundd: soundd.c ../../mynos-lib/lib/libmynos.a
	$(CC) $(CFLAGS) -c soundd.c -o soundd.o
	$(CC) soundd.o -o $@ -lpthread $(LDFLAGS)

clean:
	rm -f *.o soundd
