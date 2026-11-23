#!/bin/sh
# Try NetSurf (ports/netsurf) in MyNOS: a clean disk of its own (never
# system/disk.img) with build/netsurf/stage as /disk/ns, MyNOS in a QEMU
# window. In MyNOS, start the graphical session (gui), open a Terminal,
# and type:
#   /disk/ns/netsurf [URL]
# KVM=1 by default; MEM in MB (2048).
set -eu
cd "$(dirname "$0")/../.."
w=build/netsurf/vm
s=build/netsurf/stage
[ -x $s/nsfb ] || { echo "try.sh: build it first (ports/netsurf/build.sh)" >&2; exit 1; }
rm -rf $w; mkdir -p $w
# a script that starts it with its resources and home
printf '%s\n' '#!sh' 'NETSURFRES=/disk/ns/res HOME=/disk/ns/home /disk/ns/nsfb -f mynos -w 880 -h 600 $1' > $w/netsurf
tools/in-container.sh dev sh -c "make -s -C system DISK=../$w/disk.img ../$w/disk.img && mmd -i $w/disk.img ::/ns && mcopy -s -i $w/disk.img $s/* ::/ns/ && mcopy -i $w/disk.img $w/netsurf ::/ns/netsurf"
KVM=${KVM-1} NET=1 DISK=$w/disk.img MEM=${MEM:-2048} tools/run-qemu.sh "$(tools/ocamlrun-path.sh)" \
    services/registry/registry services/fs/memrofs/memrofsd system/ramdisk.dsk
