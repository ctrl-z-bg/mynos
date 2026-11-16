#!/bin/sh
# Build the whole system and the test files in a build container.
#
# Usage: tools/build-all.sh [dev|legacy]     (default: dev)
#
# Produces:
#   mynos-core/kernel/kernel.elf     the kernel
#   mynos-lib/lib/libmynos.a         user-space library
#   services/...                     registry, keyboardd, seriald, memrofsd
#   mynos-byterun/src/ocamlrun       the OCaml bytecode runtime
#   tests/hello/hello.byte           OCaml test program (ocamlc 3.06)
#   tests/ramdisk/ramdisk.dsk        RAM disk image for memrofs
set -eu

name=${1:-dev}
root=$(cd "$(dirname "$0")/.." && pwd)

exec "$root/tools/in-container.sh" "$name" sh -euc '
mkdir -p mynos-lib/lib
make -C mynos-core/kernel
make -C mynos-lib
make -C services
make -C mynos-byterun/src
(cd tests/hello && ocamlc -o hello.byte hello.ml)
(cd tests/ramdisk && ../../services/fs/memrofs/tool/createDisk AUTOEXEC.BAT)
'
