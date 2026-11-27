# MyNOS: the Wi-Fi of a Raspberry Pi 4 or 400 (btq.9): SDIO, a Cypress
# FullMAC chip's firmware and its commands, WPA2's handshakes (SHA-1 and
# AES from mbedTLS, with netd's configuration)

include ../../mynos.mk
CC = $(MYNOS_CC)

MBEDTLS = ../../third_party/mbedtls
MBEDTLS_SRC = sha1.c aes.c aesce.c aesni.c padlock.c platform_util.c
MBEDTLS_OBJ = $(patsubst %.c,mbedtls/%.o,$(MBEDTLS_SRC))
MBEDTLS_CFLAGS = -I$(MBEDTLS)/include -I../net -DMBEDTLS_USER_CONFIG_FILE='"mbedtls_mynos.h"'

CFLAGS = -Wall -O2 -I../../mynos-lib/include $(MBEDTLS_CFLAGS)
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

.PHONY: all clean

all: wifid

wifid: wifid.o sdio.o wpa.o $(MBEDTLS_OBJ) ../../mynos-lib/lib/libmynos.a
	$(CC) wifid.o sdio.o wpa.o $(MBEDTLS_OBJ) -o $@ -lpthread $(LDFLAGS)

mbedtls/%.o: $(MBEDTLS)/library/%.c
	@mkdir -p mbedtls
	$(CC) -O2 -w $(MBEDTLS_CFLAGS) -c $< -o $@

%.o: %.c sdio.h wpa.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf *~ *.o mbedtls wifid
