# Kernel stress test, built like the services (libmynos, 0x40000000), with
# a RAM disk holding itself: it starts copies of itself as clients
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O1 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: stress ramdisk.dsk

stress: stress.o ../../mynos-lib/lib/libmynos.a
	$(CC) stress.o -o stress $(LDFLAGS)

ramdisk.dsk: stress
	../../services/fs/memrofs/tool/createDisk stress >/dev/null

clean:
	rm -f *~ *.o stress ramdisk.dsk
