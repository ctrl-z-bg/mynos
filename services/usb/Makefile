# MyNOS: the USB's driver (btq.8.2): xHCI, keyboards and mice (HID boot)

include ../../mynos.mk
CC = $(MYNOS_CC)

CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

.PHONY: all clean

all: usbd

usbd: usbd.o ../../mynos-lib/lib/libmynos.a
	$(CC) usbd.o -o $@ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *~ *.o usbd
