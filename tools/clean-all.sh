#!/bin/sh
# Remove all build outputs. Needed when switching between the dev and legacy
# toolchains, since make would otherwise mix objects from both compilers.
#
# Usage: tools/clean-all.sh [dev|legacy]     (default: dev)
set -eu

name=${1:-dev}
root=$(cd "$(dirname "$0")/.." && pwd)

exec "$root/tools/in-container.sh" "$name" sh -euc '
make -C mynos-core/kernel clean
make -C mynos-lib clean
make -C services clean
make -C services/fs/memrofs/tool clean
make -C mynos-byterun/src clean
rm -f tests/hello/hello.byte tests/hello/*.cm[io] tests/ramdisk/ramdisk.dsk
' >/dev/null
