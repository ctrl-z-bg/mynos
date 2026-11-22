#!/bin/sh
# Boot MyNOS in QEMU. Build it first with tools/build-all.sh.
#
# It boots MyNOS with the system RAM disk (system/):
# ocamlrun runs init, which starts the services (console, tmpfs, the ATA
# driver and fatfs, which mounts system/disk.img at /disk, the network with
# an NE2000 card on QEMU's user network, httpd) and sh. Type help; "ocaml"
# opens the OCaml toplevel. NET= (empty) boots without a network card;
# HTTP=PORT forwards another host port to httpd. With /dev/kvm usable,
# KVM runs the processor (KVM= emulates it). A Sound Blaster 16 plays
# through the host's audio (SOUND=BACKEND chooses QEMU's, SOUND= none). llm.env, if there is one
# (see llm.env.example), is copied into the disk as /disk/llm.env, for llmd.
# SERIAL=1 makes this terminal a console of MyNOS too (its second serial
# port: doc/decisions/console.md), with the host's copy and paste,
# scrollback and fonts; QEMU's window shows the same. Ctrl-C goes to MyNOS:
# close the window, or type Ctrl-A then X, to stop QEMU.
# (The system as it was in 2004-2008: git checkout legacy-last, see
# doc/STATUS.md.)
#
# Extra arguments after -- go to QEMU, e.g.:
#   tools/run-demo.sh -- -serial stdio
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ocamlrun=$(tools/ocamlrun-path.sh)

if [ ! -f system/ramdisk.dsk ]; then
    echo "run-demo.sh: no system/ramdisk.dsk: build first (tools/build-all.sh)" >&2
    exit 1
fi
[ -f system/disk.img ] && export DISK=${DISK:-system/disk.img}
# the language models' configuration, into the disk (mtools: on the
# host if it has them, else in the build container)
if [ -f llm.env ] && [ -n "${DISK:-}" ]; then
    if command -v mcopy >/dev/null; then
        mcopy -o -i "$DISK" llm.env ::/llm.env
    else
        tools/in-container.sh dev mcopy -o -i "$DISK" llm.env ::/llm.env
    fi && echo "run-demo.sh: llm.env copied to /disk/llm.env" >&2
fi
# the network, and the host's port 8080 to httpd if it is free
export NET=${NET-1}
if [ -n "$NET" ] && [ -z "${HTTP+set}" ]; then
    if python3 -c 'import socket; socket.socket().bind(("127.0.0.1", 8080))' 2>/dev/null
    then export HTTP=8080; echo "run-demo.sh: http://localhost:8080/ is MyNOS's httpd" >&2
    else echo "run-demo.sh: port 8080 is busy, no web server forwarding" >&2
    fi
fi
# sound: a Sound Blaster 16, through the host's audio, by a backend this
# QEMU has
if [ -z "${SOUND+set}" ]; then
    backends=$(qemu-system-i386 -audiodev help 2>/dev/null)
    has() { printf '%s\n' "$backends" | grep -qx "$1"; }
    run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    if [ -S "$run/pipewire-0" ] && has pipewire; then SOUND=pipewire
    elif [ -S "$run/pulse/native" ] && has pa; then SOUND=pa
    elif [ "$(uname)" = Darwin ] && has coreaudio; then SOUND=coreaudio
    elif [ -d /dev/snd ] && has alsa; then SOUND=alsa
    else SOUND=
    fi
    export SOUND
    if [ -n "$SOUND" ]; then echo "run-demo.sh: sound through $SOUND (SOUND= for none)" >&2
    else echo "run-demo.sh: no audio backend found: no sound" >&2
    fi
fi
# KVM: the host's processor, if /dev/kvm is there and ours
if [ -z "${KVM+set}" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        export KVM=1; echo "run-demo.sh: KVM on (KVM= to emulate the processor)" >&2
    else
        echo "run-demo.sh: no /dev/kvm to use: the processor is emulated (slower)" >&2
    fi
fi
[ "${1:-}" = "--" ] && shift
if [ -n "${SERIAL:-}" ]; then
    set -- -chardev stdio,id=term,signal=off,mux=on -serial null \
        -serial chardev:term -mon chardev=term,mode=readline "$@"
    echo "run-demo.sh: this terminal is MyNOS's console (Ctrl-A X stops QEMU)" >&2
fi
MEM=${MEM:-256} exec tools/run-qemu.sh \
    "$ocamlrun" \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    system/ramdisk.dsk \
    -- "$@"
