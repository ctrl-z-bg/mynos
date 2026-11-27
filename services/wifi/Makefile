# MyNOS: the Wi-Fi of a Raspberry Pi 4 or 400 (btq.9): SDIO, a Cypress
# FullMAC chip's firmware and its commands

include ../../mynos.mk
CC = $(MYNOS_CC)

CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

.PHONY: all clean

all: wifid

wifid: wifid.o sdio.o ../../mynos-lib/lib/libmynos.a
	$(CC) wifid.o sdio.o -o $@ $(LDFLAGS)

%.o: %.c sdio.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *~ *.o wifid
