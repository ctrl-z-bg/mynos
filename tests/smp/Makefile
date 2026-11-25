# Several processors at once (mynos-btq.5), built like the services (musl, libmynos, 0x40000000)
include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -lpthread -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: smp

smp: smp.o ../../mynos-lib/lib/libmynos.a
	$(CC) smp.o -o smp $(LDFLAGS)

clean:
	rm -f *~ *.o smp
