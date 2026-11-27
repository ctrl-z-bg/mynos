#!/bin/sh
# The AArch64 kernel (doc/decisions/aarch64.md), built apart from the
# others: its objects in build/aarch64/kernel, its image
# build/aarch64/kernel.elf, from the sources as they are (no copy).
# Then the Raspberry Pi's (MYNOS_RASPI, btq.7): its objects in
# build/aarch64/kernel-raspi, its images kernel-raspi.elf and
# kernel8.img (the bytes the Pi's firmware loads). An argument, virt or
# raspi, builds one only.
# Runs in the dev-aarch64 container (it calls itself there).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -d /opt/musl-aarch64 ] || [ ! -d /mynos ]; then
    mkdir -p "$root/build/aarch64"
    "$root/tools/version.sh" > "$root/build/aarch64/VERSION"   # git is here, not there
    # (a Pi has no clock: its time starts at the last commit's, io.c)
    git -C "$root" log -1 --format=%ct > "$root/build/aarch64/EPOCH" 2>/dev/null || true
    exec "$root/tools/in-container.sh" dev-aarch64 sh /mynos/tools/build-kernel-aarch64.sh "$@"
fi
k=/mynos/mynos-core/kernel
a=$k/arch/aarch64
version=$(cat /mynos/build/aarch64/VERSION 2>/dev/null || cat /mynos/VERSION 2>/dev/null || echo unknown)
CC=aarch64-linux-gnu-gcc
CFLAGS0="-DMYNOS -nostdinc -Wall -fno-stack-protector -fno-pie -g -mgeneral-regs-only \
  -ffreestanding -O0 -fno-common -mno-outline-atomics -fsigned-char \
  -I$k -I$a -I/mynos/mynos-lib/include -DMYNOS_VERSION=\"$version\""
build() {   # build OUT ELF RAM_BASE [CFLAGS]
out=$1 elf=$2 ram=$3
CFLAGS="$CFLAGS0 ${4:-}"
mkdir -p "$out"
objs=
fails=
for src in $k/*.c $k/mem/*.c $k/ipc/*.c $k/3parts/*.c $a/*.c; do
    case $src in */boot_test.c) continue ;; esac
    o=$out/$(echo "${src#$k/}" | tr / _ | sed 's/\.c$/.o/')
    $CC $CFLAGS -c "$src" -o "$o" || fails="$fails $src"
    objs="$objs $o"
done
[ -z "$fails" ] || { echo "failed:$fails"; exit 1; }
for s in start entry font; do
    $CC $CFLAGS -Wa,-I/mynos/third_party/fonts -c $a/$s.S -o $out/$s.o
done
aarch64-linux-gnu-ld -nostdlib -T $a/kernel.ld --defsym=RAM_BASE=$ram \
    $out/start.o $out/entry.o $out/font.o $objs -o "$elf"
}
if [ "${1:-virt}" = virt ]; then
    build /mynos/build/aarch64/kernel /mynos/build/aarch64/kernel.elf 0x40000000
    echo "build/aarch64/kernel.elf"
fi
if [ "${1:-raspi}" = raspi ]; then
    epoch=$(cat /mynos/build/aarch64/EPOCH 2>/dev/null || cat /mynos/EPOCH 2>/dev/null || echo 0)
    build /mynos/build/aarch64/kernel-raspi /mynos/build/aarch64/kernel-raspi.elf 0 \
        "-DMYNOS_RASPI -DMYNOS_EPOCH=${epoch:-0}"
    aarch64-linux-gnu-objcopy -O binary /mynos/build/aarch64/kernel-raspi.elf \
        /mynos/build/aarch64/kernel8.img
    echo "build/aarch64/kernel8.img"
fi
