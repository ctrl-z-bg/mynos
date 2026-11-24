# MyNOS: the virtio drivers (doc/decisions/virtio.md), in C over
# mynos-lib's virtio transport (mynos_virtio.h)

include ../../mynos.mk
CC = $(MYNOS_CC)

CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

.PHONY: all clean

all: vblkd

vblkd: vblkd.o ../../mynos-lib/lib/libmynos.a
	$(CC) vblkd.o -o $@ $(LDFLAGS)

%.o: %.c ../../mynos-lib/include/mynos_virtio.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *~ *.o vblkd
