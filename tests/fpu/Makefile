# FPU state per thread (mynos-t6p), built like the services (musl, libmynos, 0x40000000)
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -lpthread -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: fpu

fpu: fpu.o ../../mynos-lib/lib/libmynos.a
	$(CC) fpu.o -o fpu $(LDFLAGS)

clean:
	rm -f *~ *.o fpu
