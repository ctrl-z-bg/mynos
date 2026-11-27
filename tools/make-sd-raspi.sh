#!/bin/sh
# An SD card image of MyNOS for a Raspberry Pi 3, Zero 2 W, 4 or 400
# (btq.7.4, btq.8, doc/decisions/aarch64.md, choice 11): one kernel8.img,
# which finds out which Pi it is on. One FAT32 partition (an MBR: the
# Pi's boot ROM wants one), which is also MyNOS's /disk (sdhcid, fatfs):
#   - the Pi's firmware: bootcode.bin, start.elf, fixup.dat (the Pi 3's
#     and Zero 2 W's), start4.elf, fixup4.dat (the Pi 4's and 400's, whose
#     boot loader is in their EEPROM), the device trees of the Pi 3 B,
#     3 B+, Zero 2 W, 4 B and 400, the disable-bt overlay
#     (the PL011 on GPIO 14 and 15, Bluetooth off), from
#     github.com/raspberrypi/firmware at FW_TAG, checked against the
#     sums below, kept in build/raspi-firmware/FW_TAG;
#   - config.txt: 64 bits, kernel8.img, the modules' archive (mynos.mod,
#     tools/mkmodules.py: the modules run-demo.sh gives) at 64 MB, where
#     the kernel looks, the UART on;
#   - kernel8.img (tools/build-aarch64.sh), README.TXT;
#   - wifi/: the Pi 400's Wi-Fi chip's (CYW43456) firmware, its CLM and
#     its board's NVRAM, for wifid (btq.9), from github.com/RPi-Distro/
#     firmware-nonfree at WIFI_COMMIT, checked against the sums below,
#     kept in build/raspi-firmware/wifi-WIFI_COMMIT. Synaptics's licence
#     (that repository's debian/copyright, "Synaptics"): reproduced and
#     distributed in object code only, for use with its chips: on this
#     card, for the Pi's own chip; never in MyNOS's repository.
# Never the developer's system/disk.img (it holds llm.env): /disk starts
# empty but for these files.
#
# Usage: [SIZE_MB=N] [VERBOSE=1] tools/make-sd-raspi.sh [OUT]
#   (VERBOSE: the kernel's and the services' messages stay on the screen
#   after boot, for a board without its serial port wired)
#   (default tmp/mynos-raspi.img, 2048 MB: a card of 2 GB or more)
#   then, e.g.: dd if=tmp/mynos-raspi.img of=/dev/sdX bs=4M conv=fsync
# Or OUT a directory: a card made so once, its partition mounted (the
# desktop mounts it at /run/media/$USER/MYNOS): only what changed is
# copied there (kernel8.img, mynos.mod, config.txt; the firmware if
# missing), in seconds, and /disk's other files are kept.
# The console: the screen (HDMI), and the UART (GPIO 14 TX, 15 RX,
# 115200 8N1, 3.3 V). The keyboard: the UART's terminal; on a Pi 4 or 400
# also a USB keyboard and mouse (usbd, behind the kernel's PCIe: btq.8.1-3,
# .8.5), the 400's own keyboard too. A Pi 3's USB (DWC2) is not driven.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tree=$root/build/aarch64/tree
out=${1:-$root/tmp/mynos-raspi.img}
FW_TAG=1.20260915
fw=$root/build/raspi-firmware/$FW_TAG
WIFI_COMMIT=b1833f18a816cf8fd73ca86e27f9eecea11bf991
wifi=$root/build/raspi-firmware/wifi-$WIFI_COMMIT
wifi_files="brcmfmac43456-sdio.bin brcmfmac43456-sdio.txt brcmfmac43456-sdio.clm_blob"
files="bootcode.bin start.elf fixup.dat bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb
bcm2710-rpi-zero-2-w.dtb start4.elf fixup4.dat bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb
overlays/disable-bt.dtbo"

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
560ead37044d849325755d3684ac1f74654b3ce6450604a42df6dd832cda9ede  start4.elf
d181d5055daebac22513d6904fa9ce21d1e99b852cc391af095ade6f0b45c400  fixup4.dat
75761b73c284e26623e4d1624bff13e67bce2ae620880efd81d6571a3739fcfb  bcm2711-rpi-4-b.dtb
d750046f964db97ded3bffccafcc30f96336da7cf9f2e8b6575aef45c73ee3d2  bcm2711-rpi-400.dtb
ea69d22dedc607fee75eec57d8a4cc0f0eab93cd75393e61a64c49fbac912d02  overlays/disable-bt.dtbo
SUMS
mkdir -p "$wifi"
for f in $wifi_files; do
    [ -s "$wifi/$f" ] && continue
    echo "make-sd-raspi.sh: downloading $f (RPi-Distro firmware-nonfree)" >&2
    curl -fsSL -o "$wifi/$f.part" \
        "https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/$WIFI_COMMIT/debian/added-firmware/brcm/$f"
    mv "$wifi/$f.part" "$wifi/$f"
done
(cd "$wifi" && sha256sum -c --quiet) <<'SUMS'
dc4429f13b59f8c271e940c28b2a197455a8e02270fcc7a2f9036aa1e4c739fb  brcmfmac43456-sdio.bin
44e0bb322dc1f39a4b0a89f30ffdd28bc93f7d7aaf534d06d229fe56f6198194  brcmfmac43456-sdio.txt
2dbd7d22fc9af0eb560ceab45b19646d211bc7b34a1dd00c6bfac5dd6ba25e8a  brcmfmac43456-sdio.clm_blob
SUMS

# (the work in the repository's tmp/: the build container sees it)
mkdir -p "$root/tmp"
w=$(mktemp -d "$root/tmp/sd-XXXXXX")
trap 'rm -rf "$w"' EXIT
# the modules' archive, as run-qemu.sh makes it for run-demo.sh's modules
(cd "$tree" && python3 tools/mkmodules.py ${VERBOSE:+-c verbose} "$w/mynos.mod" "$(tools/ocamlrun-path.sh)" \
    services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk)
cat > "$w/config.txt" <<'CFG'
# MyNOS on a Raspberry Pi 3, Zero 2 W, 4 or 400 (tools/make-sd-raspi.sh)
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

# a card already made, mounted: its files brought up to date
if [ -d "$out" ]; then
    [ -f "$out/start4.elf" ] || [ -f "$out/kernel8.img" ] ||
        { echo "make-sd-raspi.sh: $out is not a MyNOS card's partition" >&2; exit 1; }
    mkdir -p "$out/overlays"
    for f in $files; do [ -f "$out/$f" ] || cp "$fw/$f" "$out/$f"; done
    mkdir -p "$out/wifi"
    for f in $wifi_files; do cmp -s "$wifi/$f" "$out/wifi/$f" || cp "$wifi/$f" "$out/wifi/$f"; done
    cp "$tree/build/aarch64/kernel8.img" "$out/kernel8.img"
    cp "$w/mynos.mod" "$w/config.txt" "$w/README.TXT" "$out/"
    sync
    echo "make-sd-raspi.sh: $out updated: $(cat "$tree/VERSION")${VERBOSE:+, verbose}; unmount it before taking the card out"
    exit 0
fi

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
mt mmd -i "$img" ::/wifi
for f in $wifi_files; do mt mcopy -i "$img" "$wifi/$f" "::/wifi/$f"; done
for f in $files; do mt mcopy -i "$img" "$fw/$f" "::/$f"; done
mt mcopy -i "$img" "$tree/build/aarch64/kernel8.img" ::/kernel8.img
mt mcopy -i "$img" "$w/mynos.mod" "$w/config.txt" "$w/README.TXT" ::/
echo "make-sd-raspi.sh: $out ($(du -h --apparent-size "$out" | cut -f1)): firmware $FW_TAG, $(cat "$tree/VERSION")"
