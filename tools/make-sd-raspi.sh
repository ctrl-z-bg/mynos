#!/bin/sh
# An SD card image of MyNOS for a Raspberry Pi 3 or Zero 2 W (btq.7.4,
# doc/decisions/aarch64.md, choice 11). One FAT32 partition (an MBR: the
# Pi's boot ROM wants one), which is also MyNOS's /disk (sdhcid, fatfs):
#   - the Pi's firmware: bootcode.bin, start.elf, fixup.dat, the device
#     trees of the Pi 3 B, 3 B+ and Zero 2 W, the disable-bt overlay
#     (the PL011 on GPIO 14 and 15, Bluetooth off), from
#     github.com/raspberrypi/firmware at FW_TAG, checked against the
#     sums below, kept in build/raspi-firmware/FW_TAG;
#   - config.txt: 64 bits, kernel8.img, the modules' archive (mynos.mod,
#     tools/mkmodules.py: the modules run-demo.sh gives) at 64 MB, where
#     the kernel looks, the UART on;
#   - kernel8.img (tools/build-aarch64.sh), README.TXT.
# Never the developer's system/disk.img (it holds llm.env): /disk starts
# empty but for these files.
#
# Usage: [SIZE_MB=N] tools/make-sd-raspi.sh [OUT]
#   (default tmp/mynos-raspi.img, 2048 MB: a card of 2 GB or more)
#   then, e.g.: dd if=tmp/mynos-raspi.img of=/dev/sdX bs=4M conv=fsync
# The console: the screen (HDMI), and the UART (GPIO 14 TX, 15 RX,
# 115200 8N1, 3.3 V). No keyboard yet (USB: btq.10): the UART's terminal
# is the keyboard.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tree=$root/build/aarch64/tree
out=${1:-$root/tmp/mynos-raspi.img}
FW_TAG=1.20260915
fw=$root/build/raspi-firmware/$FW_TAG
files="bootcode.bin start.elf fixup.dat bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb
bcm2710-rpi-zero-2-w.dtb overlays/disable-bt.dtbo"

for f in build/aarch64/kernel8.img system/ramdisk.dsk services/registry/registry \
         services/fs/memrofs/memrofsd; do
    [ -f "$tree/$f" ] || { echo "make-sd-raspi.sh: no $tree/$f: tools/build-aarch64.sh first" >&2; exit 1; }
done

# the firmware, downloaded once, checked every time
mkdir -p "$fw/overlays"
for f in $files; do
    [ -s "$fw/$f" ] && continue
    echo "make-sd-raspi.sh: downloading $f ($FW_TAG)" >&2
    curl -fsSL -o "$fw/$f.part" "https://raw.githubusercontent.com/raspberrypi/firmware/$FW_TAG/boot/$f"
    mv "$fw/$f.part" "$fw/$f"
done
(cd "$fw" && sha256sum -c --quiet) <<'SUMS'
4245ec23b58158dc3e55f3e065eb4ecc0c0705d76c8db506e9f824941feee32e  bootcode.bin
32f990801e7765bae6fe5cb940ba5eeff02dd0dac8dc5474db5b3fd345281790  start.elf
7853f2b51e4489f8b3ce6f9c52fd0afdda38c7383961524e0883d34afcb4827b  fixup.dat
cd922193672e391b6194d6d94e34ffab6fc154205375fcfb362cad191f7f8aae  bcm2710-rpi-3-b.dtb
d41256bdc25b09dbba0bcdb27592560561d39752ebb09c64e82a449e3271807d  bcm2710-rpi-3-b-plus.dtb
ce3ca3176658cddfad2ef6414d858bad61ce5242382eb0755248ea0edfcb0783  bcm2710-rpi-zero-2-w.dtb
ea69d22dedc607fee75eec57d8a4cc0f0eab93cd75393e61a64c49fbac912d02  overlays/disable-bt.dtbo
SUMS

# (the work in the repository's tmp/: the build container sees it)
mkdir -p "$root/tmp"
w=$(mktemp -d "$root/tmp/sd-XXXXXX")
trap 'rm -rf "$w"' EXIT
# the modules' archive, as run-qemu.sh makes it for run-demo.sh's modules
(cd "$tree" && python3 tools/mkmodules.py "$w/mynos.mod" "$(tools/ocamlrun-path.sh)" \
    services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk)
cat > "$w/config.txt" <<'CFG'
# MyNOS on a Raspberry Pi 3 or Zero 2 W (tools/make-sd-raspi.sh)
arm_64bit=1
kernel=kernel8.img
# the modules' archive where the kernel looks for it: 64 MB
initramfs mynos.mod 0x04000000
# the PL011 on GPIO 14 and 15 (Bluetooth off): MyNOS's console
enable_uart=1
dtoverlay=disable-bt
gpu_mem=64
disable_overscan=1
hdmi_force_hotplug=1
CFG
printf 'This is the MyNOS disk of a Raspberry Pi: a FAT32 partition, mounted at /disk.\nThe Pi boots from its files: leave them.\n' > "$w/README.TXT"

# the card: SIZE_MB (default 2048: written whole to a card, the rest of
# a larger card stays unused), an MBR with one partition (FAT32 LBA,
# 0x0C) from 1 MB to the end, formatted in place (mkfs.fat --offset; the
# image is sparse: nothing of its 2 GB copied); mtools reach it at 1 MB
size_mb=${SIZE_MB:-2048}
mt() { if command -v mcopy >/dev/null && command -v mkfs.fat >/dev/null; then "$@" </dev/null
       else "$root/tools/in-container.sh" dev "$@" </dev/null; fi; }
mkdir -p "$(dirname "$out")"
rm -f "$out"
python3 - "$out" "$size_mb" <<'PY'
import struct, sys
out, size_mb = sys.argv[1], int(sys.argv[2])
start, count = 2048, size_mb * 2048 - 2048
mbr = bytearray(512)
mbr[446:462] = struct.pack('<B3sB3sII', 0x00, b'\xfe\xff\xff', 0x0C, b'\xfe\xff\xff', start, count)
mbr[510:512] = b'\x55\xaa'
with open(out, 'wb') as f:
    f.write(mbr)
    f.truncate(size_mb * 1024 * 1024)
PY
mt mkfs.fat -F 32 -n MYNOS --offset 2048 "$out" $(((size_mb - 1) * 1024)) >/dev/null
img="$out@@1M"
mt mmd -i "$img" ::/overlays
for f in $files; do mt mcopy -i "$img" "$fw/$f" "::/$f"; done
mt mcopy -i "$img" "$tree/build/aarch64/kernel8.img" ::/kernel8.img
mt mcopy -i "$img" "$w/mynos.mod" "$w/config.txt" "$w/README.TXT" ::/
echo "make-sd-raspi.sh: $out ($(du -h --apparent-size "$out" | cut -f1)): firmware $FW_TAG, $(cat "$tree/VERSION")"
