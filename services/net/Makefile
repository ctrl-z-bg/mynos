# netd: the network service, lwIP (third_party/lwip), mbedTLS
# (third_party/mbedtls, for TLS) and the NE2000 driver in one process.
# Needs pthreads: dev toolchain only (musl), built by tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)

LWIP = ../../third_party/lwip/src
LWIP_SRC = $(wildcard $(LWIP)/core/*.c) $(wildcard $(LWIP)/core/ipv4/*.c) \
	$(LWIP)/netif/ethernet.c $(wildcard $(LWIP)/apps/altcp_tls/*.c)
LWIP_OBJ = $(patsubst $(LWIP)/%.c,lwip/%.o,$(LWIP_SRC))

MBEDTLS = ../../third_party/mbedtls
MBEDTLS_SRC = $(wildcard $(MBEDTLS)/library/*.c)
MBEDTLS_OBJ = $(patsubst $(MBEDTLS)/library/%.c,mbedtls/%.o,$(MBEDTLS_SRC))
MBEDTLS_CFLAGS = -I$(MBEDTLS)/include -I. \
	-DMBEDTLS_USER_CONFIG_FILE='"mbedtls_mynos.h"'

CFLAGS = -Wall -O2 -I. -I$(LWIP)/include -I../../mynos-lib/include $(MBEDTLS_CFLAGS)
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: netd

lwip/%.o: $(LWIP)/%.c lwipopts.h arch/cc.h mbedtls_mynos.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -w -c $< -o $@

mbedtls/%.o: $(MBEDTLS)/library/%.c mbedtls_mynos.h
	@mkdir -p $(dir $@)
	$(CC) -O2 -w $(MBEDTLS_CFLAGS) -c $< -o $@

%.o: %.c ne2k.h vnet.h genet.h wifinet.h lwipopts.h mbedtls_mynos.h
	$(CC) $(CFLAGS) -c $< -o $@

netd: netd.o ne2k.o vnet.o genet.o wifinet.o $(LWIP_OBJ) $(MBEDTLS_OBJ) ../../mynos-lib/lib/libmynos.a
	$(CC) netd.o ne2k.o vnet.o genet.o wifinet.o $(LWIP_OBJ) $(MBEDTLS_OBJ) -o $@ -lpthread $(LDFLAGS)

clean:
	rm -rf *~ *.o lwip mbedtls netd
