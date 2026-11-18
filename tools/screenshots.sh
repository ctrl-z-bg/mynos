#!/bin/sh
# The README's screenshots (doc/screenshots): the text console, the
# graphical session as it starts (the welcome window), the System window.
# Build first with tools/build-all.sh; QEMU runs headless, driven through
# its monitor, as tools/run-tests.sh does.
#
# Usage: tools/screenshots.sh [DIR]          (default: doc/screenshots)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out=${1:-doc/screenshots}
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'kill $qemu 2>/dev/null; rm -rf "$tmp"' EXIT

# a copy of the disk, and the network: the System window shows their
# drivers
[ -f system/disk.img ] && cp system/disk.img "$tmp/disk.img"
NET=1 DISK=$([ -f "$tmp/disk.img" ] && echo "$tmp/disk.img") MEM=256 \
tools/run-qemu.sh "$(tools/ocamlrun-path.sh)" \
    services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk \
    -- -machine vmport=off -display none -serial null -serial "file:$tmp/log" \
       -monitor "unix:$tmp/mon,server,nowait" >/dev/null 2>&1 &
qemu=$!
i=0
while [ $i -lt 60 ] && ! grep -aq 'mynos:/' "$tmp/log" 2>/dev/null; do
    sleep 1; i=$((i + 1))
done
mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null; sleep 0.12; }
gx=512 gy=384                              # the pointer starts in the middle
to() {
    dx=$(($1 - gx)) dy=$(($2 - gy)); gx=$1 gy=$2
    while [ $dx -ne 0 ] || [ $dy -ne 0 ]; do
        sx=$dx sy=$dy
        [ $sx -gt 40 ] && sx=40; [ $sx -lt -40 ] && sx=-40
        [ $sy -gt 40 ] && sy=40; [ $sy -lt -40 ] && sy=-40
        mon "mouse_move $sx $sy"; dx=$((dx - sx)) dy=$((dy - sy))
    done
}
click() { to "$1" "$2"; mon "mouse_button 1"; mon "mouse_button 0"; }
shot() { mon "screendump $tmp/$1.ppm"; sleep 1
         python3 tools/ppm2png.py "$tmp/$1.ppm" "$out/$1.png"; echo "$out/$1.png"; }

# the text console: the shell, and the processes
tools/type-keys.py "$tmp/mon" 'clear\n'; sleep 1
tools/type-keys.py "$tmp/mon" 'free\n'; sleep 1
tools/type-keys.py "$tmp/mon" 'ps\n'; sleep 3
shot shell
# the graphical session, as it starts
tools/type-keys.py "$tmp/mon" 'gui\n'; sleep 10
to 900 700; sleep 2
shot welcome
# the System window (the MyNOS menu's seventh item)
click 20 10; sleep 1; click 40 171; sleep 12
to 1000 740; sleep 2
shot system
