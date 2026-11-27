# jsd: the JavaScript service, QuickJS-ng (third_party/quickjs-ng;
# doc/decisions/browser.md, M6). Built by tools/build-all.sh.

include ../../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O2 -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

QJS = ../../third_party/quickjs-ng
QJS_SRC = quickjs.c libregexp.c libunicode.c dtoa.c
QJS_OBJ = $(addprefix qjs-, $(QJS_SRC:.c=.o))

all: jsd

qjs-%.o: $(QJS)/%.c $(wildcard $(QJS)/*.h)
	$(CC) -O2 -w -D_GNU_SOURCE -DQUICKJS_NG_BUILD -I$(QJS) -c $< -o $@

jsd: jsd.c $(QJS_OBJ) ../../mynos-lib/lib/libmynos.a
	$(CC) $(CFLAGS) -c jsd.c -o jsd.o
	$(CC) jsd.o $(QJS_OBJ) -o $@ -lm $(LDFLAGS)

clean:
	rm -f *.o jsd
