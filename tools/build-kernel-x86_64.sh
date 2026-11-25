#!/bin/sh
# The x86-64 kernel (doc/decisions/x86-64.md), built apart from the i386
# one: its objects in build/x86_64/kernel, its image build/x86_64/kernel.elf,
# so that the two architectures' files never mix in the source tree.
# Runs in the dev-x86_64 container (it calls itself there).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -m)" != x86_64 ] || [ ! -d /mynos ]; then
    exec "$root/tools/in-container.sh" dev-x86_64 sh /mynos/tools/build-kernel-x86_64.sh "$@"
fi
k=/mynos/mynos-core/kernel
out=/mynos/build/x86_64/kernel
mkdir -p "$out"
version=$(cat /mynos/VERSION 2>/dev/null || echo unknown)
CFLAGS="-DMYNOS -nostdinc -Wall -fno-stack-protector -fno-pie -g -mgeneral-regs-only \
  -m64 -mno-red-zone -mcmodel=small -ffreestanding -O0 \
  -I$k -I$k/arch/x86_64 -I/mynos/mynos-lib/include -DMYNOS_VERSION=\"$version\""
objs=
fails=
for src in $k/*.c $k/mem/*.c $k/ipc/*.c $k/3parts/*.c $k/arch/x86_64/*.c; do
    case $src in */boot_test.c) continue ;; esac
    o=$out/$(echo "${src#$k/}" | tr / _ | sed 's/\.c$/.o/')
    gcc $CFLAGS -c "$src" -o "$o" || fails="$fails $src"
    objs="$objs $o"
done
[ -z "$fails" ] || { echo "failed:$fails"; exit 1; }
nasm -f elf64 $k/arch/x86_64/start.asm -o $out/start.o
nasm -f elf64 $k/arch/x86_64/entry.asm -o $out/entry.o
ld -m elf_x86_64 -nostdlib $out/start.o $out/entry.o $objs -Ttext 0x200000 -o $out/../kernel64.elf
objcopy -O elf32-i386 $out/../kernel64.elf $out/../kernel.elf
echo "build/x86_64/kernel.elf"
