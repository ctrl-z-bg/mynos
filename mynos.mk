# Toolchain for MyNOS user-space programs (static Linux i386 binaries loaded
# by the kernel at 0x40000000). Included by the user-space Makefiles.
#
# The defaults are the legacy toolchain: dietlibc and the old linker, where
# -N puts everything in one segment at 0x40000000. The dev container sets
# MYNOS_CC=musl-gcc and its own MYNOS_LDFLAGS in the environment.
MYNOS_CC      ?= diet gcc
MYNOS_LDFLAGS ?= -static -Xlinker -Ttext -Xlinker 0x40000000 \
                 -Wl,--build-id=none -Wl,-N
