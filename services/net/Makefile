# netd: the network service, lwIP (third_party/lwip) and the NE2000
# driver in one process. Needs pthreads: dev toolchain only (musl), built
# by tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)

LWIP = ../../third_party/lwip/src
LWIP_SRC = $(wildcard $(LWIP)/core/*.c) $(wildcard $(LWIP)/core/ipv4/*.c) \
	$(LWIP)/netif/ethernet.c
LWIP_OBJ = $(patsubst $(LWIP)/%.c,lwip/%.o,$(LWIP_SRC))

CFLAGS = -Wall -O2 -I. -I$(LWIP)/include -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: netd

lwip/%.o: $(LWIP)/%.c lwipopts.h arch/cc.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -w -c $< -o $@

%.o: %.c ne2k.h lwipopts.h
	$(CC) $(CFLAGS) -c $< -o $@

netd: netd.o ne2k.o $(LWIP_OBJ) ../../mynos-lib/lib/libmynos.a
	$(CC) netd.o ne2k.o $(LWIP_OBJ) -o $@ -lpthread $(LDFLAGS)

clean:
	rm -rf *~ *.o lwip netd
