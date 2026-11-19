#!/bin/sh
# A bootable ISO of MyNOS (mynos-sc9): GRUB for PC BIOS, the kernel, and
# the modules in the order tools/run-demo.sh gives them (the runtime, the
# registry, memrofs, the system RAM disk). Build first (tools/build-all.sh).
# Beside it, a clean disk for /disk, made anew every time with
# system/Makefile's recipe (an empty FAT32 and a README): never the
# developer's system/disk.img, which holds llm.env and their files.
# Both go to tmp/ (not kept by git).
#
# Usage: tools/make-iso.sh [OUT]   (default: tmp/mynos.iso; the disk:
#                                   OUT without .iso, then -disk.img)
#   qemu-system-i386 -boot d -cdrom tmp/mynos.iso -m 256 \
#     -drive file=tmp/mynos-disk.img,format=raw,if=ide,index=0 \
#     -netdev user,id=n0 -device ne2k_isa,netdev=n0,iobase=0x300,irq=9
#   (-boot d: the BIOS would try the disk first, which is not bootable)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out=${1:-tmp/mynos.iso}
case "$out" in   # the container sees the repository only
    /*|../*) echo "make-iso.sh: OUT must be a path inside the repository" >&2; exit 1 ;;
esac
for f in mynos-core/kernel/kernel.elf mynos-runtime/ocamlrun \
         services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk; do
    [ -f "$f" ] || { echo "make-iso.sh: no $f: build first (tools/build-all.sh)" >&2; exit 1; }
done
tree=tmp/iso
rm -rf "$tree"
mkdir -p "$tree/boot/grub" "$(dirname "$out")"
cp mynos-core/kernel/kernel.elf mynos-runtime/ocamlrun services/registry/registry \
   services/fs/memrofs/memrofsd system/ramdisk.dsk "$tree/boot/"
# a module's command line is its argv, after the file's name (GRUB 2):
# argv[0] is the program's name, as with QEMU's -initrd
version=$(cat VERSION 2>/dev/null || tools/version.sh)
cat > "$tree/boot/grub/grub.cfg" <<CFG
set timeout=0
set default=0
menuentry "MyNOS $version" {
    multiboot /boot/kernel.elf
    module /boot/ocamlrun ocamlrun
    module /boot/registry registry
    module /boot/memrofsd memrofsd
    module /boot/ramdisk.dsk ramdisk.dsk
    boot
}
CFG
# BIOS only: the kernel writes to the VGA text screen, which UEFI lacks
tools/in-container.sh dev grub-mkrescue -d /usr/lib/grub/i386-pc -o "$out" "$tree" 2>&1 |
    grep -v "^xorriso\|^Drive current\|^Media current\|^Media status\|^Media summary\|^Added to ISO\|^Written to medium\|^Writing to\|^ISO image produced\|^$" || true
rm -rf "$tree"
[ -f "$out" ] && echo "make-iso.sh: $out ($(du -h "$out" | cut -f1))"
# the clean disk
disk=${out%.iso}-disk.img
rm -f "$disk"
tools/in-container.sh dev make -s -C system DISK="../$disk" "../$disk"
[ -f "$disk" ] && echo "make-iso.sh: $disk ($(du -h --apparent-size "$disk" | cut -f1), empty but for README.TXT)"
