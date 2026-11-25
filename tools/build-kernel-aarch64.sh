#!/bin/sh
# The AArch64 kernel (doc/decisions/aarch64.md), built apart from the
# others: its objects in build/aarch64/kernel, its image
# build/aarch64/kernel.elf, from the sources as they are (no copy).
# Runs in the dev-aarch64 container (it calls itself there).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -d /opt/musl-aarch64 ] || [ ! -d /mynos ]; then
    mkdir -p "$root/build/aarch64"
    "$root/tools/version.sh" > "$root/build/aarch64/VERSION"   # git is here, not there
    exec "$root/tools/in-container.sh" dev-aarch64 sh /mynos/tools/build-kernel-aarch64.sh "$@"
fi
k=/mynos/mynos-core/kernel
a=$k/arch/aarch64
out=/mynos/build/aarch64/kernel
mkdir -p "$out"
version=$(cat /mynos/build/aarch64/VERSION 2>/dev/null || cat /mynos/VERSION 2>/dev/null || echo unknown)
CC=aarch64-linux-gnu-gcc
CFLAGS="-DMYNOS -nostdinc -Wall -fno-stack-protector -fno-pie -g -mgeneral-regs-only \
  -ffreestanding -O0 -fno-common -mno-outline-atomics -fsigned-char \
  -I$k -I$a -I/mynos/mynos-lib/include -DMYNOS_VERSION=\"$version\""
objs=
fails=
for src in $k/*.c $k/mem/*.c $k/ipc/*.c $k/3parts/*.c $a/*.c; do
    case $src in */boot_test.c) continue ;; esac
    o=$out/$(echo "${src#$k/}" | tr / _ | sed 's/\.c$/.o/')
    $CC $CFLAGS -c "$src" -o "$o" || fails="$fails $src"
    objs="$objs $o"
done
[ -z "$fails" ] || { echo "failed:$fails"; exit 1; }
for s in start entry; do
    $CC $CFLAGS -c $a/$s.S -o $out/$s.o
done
aarch64-linux-gnu-ld -nostdlib -T $a/kernel.ld $out/start.o $out/entry.o $objs \
    -o $out/../kernel.elf
echo "build/aarch64/kernel.elf"
