# Toolchain for MyNOS user-space programs (static Linux i386 binaries loaded
# by the kernel at 0x40000000). Included by the user-space Makefiles.
#
# musl (the build container, tools/containers/dev, sets the same in the
# environment). -Ttext-segment moves the whole image: musl's crti has an
# .init section that -Ttext would leave at the default address.
MYNOS_CC      ?= musl-gcc
MYNOS_LDFLAGS ?= -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code \
                 -Wl,--build-id=none

# stdio over libmynos (mynos-lib/src/stdio.c): musl's internal I/O
# functions, taken from libmynos instead of the C library
MYNOS_LDFLAGS += -Wl,-u,__stdio_read -Wl,-u,__stdio_write \
                 -Wl,-u,__stdout_write -Wl,-u,__stdio_seek -Wl,-u,__stdio_close
