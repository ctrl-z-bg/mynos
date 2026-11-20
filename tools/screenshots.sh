#!/bin/sh
# The screenshots of the README and the manual (doc/screenshots). MyNOS
# runs headless in QEMU, driven through its monitor as tools/run-tests.sh
# does: keys typed, the pointer moved and clicked, the screen dumped.
#
# The disk is a clean one made here (never system/disk.img, which holds
# the owner's files), with a few example files: life.ml (chapter 20),
# notes.txt, a folder. The agent's figures need a model: they are taken
# only if llm.env exists, in a second boot whose disk gets a copy of it.
#
# The coordinates follow the windows' cascade, so the order of the steps
# matters; some figures depend on timing (Life's generation, a replay's
# step): look at them before committing. Build first with
# tools/build-all.sh.
#
# Usage: tools/screenshots.sh [DIR]          (default: doc/screenshots)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out=${1:-doc/screenshots}
mkdir -p "$out"
w=tmp/screenshots-work                    # inside the repository: the container sees it
rm -rf "$w"; mkdir -p "$w"
qemu=
trap '[ -n "$qemu" ] && kill $qemu 2>/dev/null; true' EXIT

# a clean disk, with the examples
tools/in-container.sh dev sh -c "
    make -s -C system DISK=../$w/disk.img ../$w/disk.img &&
    printf 'Things to try in MyNOS\n- gui, and the Tour\n- trace ls /disk\n' > $w/notes.txt &&
    mcopy -o -i $w/disk.img doc/manual/examples/20/life.ml ::/life.ml &&
    mcopy -o -i $w/disk.img $w/notes.txt ::/notes.txt &&
    mmd -i $w/disk.img ::/projects &&
    mcopy -o -i $w/disk.img doc/manual/examples/20/counter.ml ::/projects/counter.ml"

boot() {   # DISK
    rm -f "$w/log" "$w/mon"
    NET=1 DISK=$1 MEM=256 \
    tools/run-qemu.sh "$(tools/ocamlrun-path.sh)" \
        services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk \
        -- -machine vmport=off -display none -serial null -serial "file:$w/log" \
           -monitor "unix:$w/mon,server,nowait" >/dev/null 2>&1 &
    qemu=$!
    i=0
    while [ $i -lt 60 ] && ! grep -aq 'mynos:/' "$w/log" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    gx=512 gy=384                          # the pointer starts in the middle
}
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
# the MyNOS menu's items, from displayd.c: 22 pixels each, from y = 28
# 0 Terminal, 1 Welcome, 2 Clock, 3 Services, 4 Agent, 5 Recordings,
# 6 System, 7 Files, 8 Tour, 9 Log, 10 Packages
menu() { click 20 10; sleep 1; click 40 $((28 + $1 * 22 + 11)); }
shot() { mon "screendump $w/$1.ppm"; sleep 1
         python3 tools/ppm2png.py "$w/$1.ppm" "$out/$1.png"; echo "$out/$1.png"; }
quit() { mon quit; sleep 2; qemu=; }

# the README's three, as the system starts: the text console (11-1),
# the welcome window (10-1), the System window (10-7)
boot "$w/disk.img"
keys 'clear\n'; sleep 1
keys 'free\n'; sleep 1
keys 'ps\n'; sleep 3
shot shell
keys 'gui\n'; sleep 12
to 900 700; sleep 2
shot welcome
menu 6; sleep 12
to 1000 740; sleep 2
shot system
quit

# the manual's: one session, window after window
boot "$w/disk.img"
# Life, compiled inside MyNOS (chapter 20)
keys 'ocamlc -use-prims /primitives mynos.cma -o /disk/life.byte /disk/life.ml\n'; sleep 25
keys 'gui\n'; sleep 12
# the menu (10-2): a Terminal first, then the menu open on Files
menu 0; sleep 2
click 20 10; sleep 1; to 70 193; sleep 1
shot menu
click 600 650; sleep 1
# the Terminal (10-4): ls, then the toplevel
click 400 300
keys 'clear\n'; sleep 1
keys 'ls /disk\n'; sleep 2
keys 'ocaml\n'; sleep 15
keys 'List.map (fun x -> x * x) [1; 2; 3];;\n'; sleep 4
keys 'Mynos.version ();;\n'; sleep 3
to 700 600; sleep 1
shot terminal
keys '#quit;;\n'; sleep 3
# Life (20-1), with the glider gun
keys '/disk/life.byte &\n'; sleep 12
click 462 174; sleep 20
to 900 690; sleep 1
shot life
# windows and tabs (10-3): a Clock and Files too
menu 2; sleep 6
menu 7; sleep 8
to 900 700; sleep 1
shot tabs
# Files (10-6): /disk, a program chosen
click 240 332; sleep 3
click 420 335; sleep 2
to 900 720; sleep 1
shot files
# Services (10-5): fatfs's list, called with /
menu 3; sleep 8
click 264 354; sleep 3
click 433 389; sleep 2
click 786 343; sleep 1; keys '/'; sleep 1
click 653 378; sleep 3
to 900 740; sleep 1
shot services
# the Tour (11-3): lesson 2, replayed to its third note
menu 8; sleep 8
click 380 344; sleep 2
click 587 634; sleep 25
for n in 1 2 3; do click 731 118; sleep 3; done
to 1000 750; sleep 1
shot tour
# a service that dies (11-4, 11-5): lesson 6, its third and fourth notes
click 775 11; sleep 2
click 365 440; sleep 2
click 587 634; sleep 30
for n in 1 2 3; do click 731 118; sleep 3; done
to 1000 750; sleep 1
shot service-dies
click 731 118; sleep 3
to 1000 750; sleep 1
shot service-back
# Recordings (11-2): a command recorded, a call chosen
menu 5; sleep 8
click 628 178; sleep 1; keys 'cat /disk/notes.txt'; sleep 1
click 970 178; sleep 15
click 255 276; sleep 3                    # memrofsd's first call: always at the start
to 1000 750; sleep 1
shot recordings
quit

# the agent (12-1, 12-2): a second boot, with a model
if [ -f llm.env ]; then
    cp "$w/disk.img" "$w/disk-agent.img"
    tools/in-container.sh dev mcopy -o -i "$w/disk-agent.img" llm.env ::/llm.env
    boot "$w/disk-agent.img"
    keys 'gui\n'; sleep 12
    menu 4; sleep 10
    click 355 638
    keys 'Read /disk/notes.txt and save it with numbered lines as /disk/numbered.txt\n'
    sleep 60
    to 1000 750; sleep 1
    shot agent-confirm
    click 166 638; sleep 40
    to 1000 750; sleep 1
    shot agent
    quit
else
    echo "screenshots.sh: no llm.env: the agent's figures are not taken" >&2
fi
rm -rf "$w"
