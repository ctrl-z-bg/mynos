# Toolchain for MyNOS user-space programs (static Linux i386 binaries loaded
# by the kernel at 0x40000000). Included by the user-space Makefiles.
#
# musl (the build container, tools/containers/dev, sets the same in the
# environment). -Ttext-segment moves the whole image: musl's crti has an
# .init section that -Ttext would leave at the default address.
MYNOS_CC      ?= musl-gcc
MYNOS_LDFLAGS ?= -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code \
                 -Wl,--build-id=none
