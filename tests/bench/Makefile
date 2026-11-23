# Measures for the external pager (mynos-0ho), built like the services (musl, libmynos, 0x40000000)
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: bench

bench: bench.o ../../mynos-lib/lib/libmynos.a
	$(CC) bench.o -o bench $(LDFLAGS)

clean:
	rm -f *~ *.o bench
