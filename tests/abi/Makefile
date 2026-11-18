# ABI checks, built like the services (musl, libmynos, 0x40000000)
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: abi

abi: abi.o ../../mynos-lib/lib/libmynos.a
	$(CC) abi.o -o abi $(LDFLAGS)

clean:
	rm -f *~ *.o abi
