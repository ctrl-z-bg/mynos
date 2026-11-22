#!/bin/sh
# A package's screenshots, for its documentation: MyNOS runs headless in
# QEMU (driven through its monitor, as tools/screenshots.sh does), the
# package is installed from the host's copy of the repository
# (tmp/packages: tools/build-all.sh first), then the package's own
# script, packages/NAME/shots.sh, drives it with the functions below and
# writes its pictures in packages/NAME/images (commit them, after a look).
#
# The disk is a clean one made here, never system/disk.img; the files of
# packages/NAME/shots/ are copied to it, in /disk/NAME/. A script that sets
# AGENT=1 gets a copy of llm.env on that disk (if there is one) for the
# agent's pictures: the work directory, disk included, is removed at the
# end in any case.
#
# The script's functions:
#   keys TEXT             typed ('\n' for Enter)
#   key NAME              one key, QEMU's name (esc, ret, ctrl-s...)
#   click X Y, to X Y     the pointer (1024x768)
#   menu N                the MyNOS menu's item N (0 Terminal...)
#   shot FILE [X Y W H]   the screen, or a rectangle of it, as images/FILE.png
#   terminal CMD          a Terminal window, CMD typed in it
#
# Usage: tools/pkg-shots.sh NAME
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
name=${1:?usage: tools/pkg-shots.sh NAME}
src=packages/$name
[ -f "$src/shots.sh" ] || { echo "pkg-shots.sh: no $src/shots.sh" >&2; exit 2; }
[ -f tmp/packages/index.json ] || { echo "pkg-shots.sh: no tmp/packages (tools/build-all.sh)" >&2; exit 2; }
out=$src/images
mkdir -p "$out"
w=tmp/pkg-shots-work                     # inside the repository: the container sees it
rm -rf "$w"; mkdir -p "$w"
qemu= files=
trap '[ -n "$qemu" ] && kill $qemu 2>/dev/null; [ -n "$files" ] && kill $files 2>/dev/null; rm -rf "$w"; true' EXIT

AGENT=0
# shellcheck disable=SC2016
grep -q '^AGENT=1' "$src/shots.sh" && AGENT=1

# a clean disk: the package's files, where pkg finds the repository, and
# llm.env if the agent is in the pictures
port=47110
printf 'http://10.0.2.2:%s/\n' $port > "$w/url"
copy="mmd -i $w/disk.img ::/pkg && mcopy -i $w/disk.img $w/url ::/pkg/url"
if [ -d "$src/shots" ]; then
    copy="$copy && mmd -i $w/disk.img ::/$name && mcopy -s -i $w/disk.img $src/shots/* ::/$name/"
fi
if [ $AGENT = 1 ] && [ -f llm.env ]; then
    cp llm.env "$w/llm.env"
    copy="$copy && mcopy -i $w/disk.img $w/llm.env ::/llm.env"
fi
tools/in-container.sh dev sh -c "make -s -C system DISK=../$w/disk.img ../$w/disk.img && $copy"
rm -f "$w/llm.env"

tools/net-peer.py files $port tmp/packages >/dev/null 2>&1 & files=$!
# the host's processor when it can (the builds inside MyNOS are faster)
KVM=
[ -r /dev/kvm ] && [ -w /dev/kvm ] && KVM=1
KVM=$KVM NET=1 DISK=$w/disk.img MEM=256 SOUND=wav:$w/sound.wav \
tools/run-qemu.sh "$(tools/ocamlrun-path.sh)" \
    services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk \
    -- -machine vmport=off -display none -serial null -serial "file:$w/log" \
       -monitor "unix:$w/mon,server,nowait" >/dev/null 2>&1 &
qemu=$!
i=0
while [ $i -lt 60 ] && ! grep -aq 'mynos:/' "$w/log" 2>/dev/null; do sleep 1; i=$((i + 1)); done
gx=512 gy=384                              # the pointer starts in the middle

mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$w/mon" >/dev/null; sleep 0.12; }
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
keys() { tools/type-keys.py "$w/mon" "$1"; }
key() { mon "sendkey $1"; }
menu() { click 20 10; sleep 1; click 40 $((28 + $1 * 22 + 11)); }
shot() {
    f=$1; shift
    mon "screendump $w/$f.ppm"; sleep 1
    python3 tools/ppm2png.py "$w/$f.ppm" "$out/$f.png" "$@"; echo "$out/$f.png"
}
terminal() { menu 0; sleep 5; keys "$1\\n"; }

# the package, from the host's copy, then the graphical session
keys "pkg install $name\\n"; sleep 15
keys 'gui\n'; sleep 12
. "./$src/shots.sh"
mon quit; sleep 2; qemu=
