# a C program for MyNOS, outside the tree
MYNOS = /mynos
include $(MYNOS)/mynos.mk

CC      = $(MYNOS_CC)
CFLAGS  = -Wall -O2 -I$(MYNOS)/mynos-lib/include
LDFLAGS = -L$(MYNOS)/mynos-lib/lib -lmynos $(MYNOS_LDFLAGS)

hello: hello.o
	$(CC) hello.o -o hello $(LDFLAGS)

clean:
	rm -f hello hello.o
