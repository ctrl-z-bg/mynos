# kilo, Salvatore Sanfilippo's small text editor (BSD 2-clause, LICENSE),
# built for MyNOS. Changes for MyNOS are marked "MyNOS:" in kilo.c.

include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -W -O2 -std=c99 -D_DEFAULT_SOURCE -I../../mynos-lib/include
LIBS = -L../../mynos-lib/lib -lmynos

all: kilo

kilo: kilo.c ../../mynos-lib/lib/libmynos.a
	$(CC) $(CFLAGS) $(MYNOS_LDFLAGS) -o $@ kilo.c $(LIBS)

clean:
	rm -f kilo
