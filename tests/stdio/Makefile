# C stdio over libmynos (mynos-d6k), built like the services (musl, libmynos, 0x40000000)
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: stdio

stdio: stdio.o ../../mynos-lib/lib/libmynos.a
	$(CC) stdio.o -o stdio $(LDFLAGS)

clean:
	rm -f *~ *.o stdio
