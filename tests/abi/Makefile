# ABI checks, built like the services (dietlibc, libmynos, 0x40000000)
CC = diet gcc
CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos -static -Xlinker -Ttext -Xlinker 0x40000000 -Wl,--build-id=none -Wl,-N

all: abi

abi: abi.o
	$(CC) abi.o -o abi $(LDFLAGS)

clean:
	rm -f *~ *.o abi
