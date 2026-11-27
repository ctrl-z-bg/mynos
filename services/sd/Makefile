# MyNOS: the SD card's driver of the Raspberry Pis (btq.7.3), in C

include ../../mynos.mk
CC = $(MYNOS_CC)

CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

.PHONY: all clean

all: sdhcid

sdhcid: sdhcid.o ../../mynos-lib/lib/libmynos.a
	$(CC) sdhcid.o -o $@ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *~ *.o sdhcid
