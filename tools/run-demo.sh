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
# through the host's audio (SOUND=BACKEND chooses QEMU's, SOUND= none);
# with sound, QEMU's window is SDL's, not GTK's (QEMU_DISPLAY=gtk chooses
# it again: with a sound card it froze). llm.env, if there is one
# (see llm.env.example), is copied into the disk as /disk/llm.env, for llmd.
# SERIAL=1 makes this terminal a console of MyNOS too (its second serial
# port: doc/decisions/console.md), with the host's copy and paste,
# scrollback and fonts; QEMU's window shows the same. Ctrl-C goes to MyNOS:
# close the window, or type Ctrl-A then X, to stop QEMU.
# VIRTIO=1 gives MyNOS virtio devices (a virtio disk, a virtio network
# card) instead of the PC's IDE disk and NE2000 (doc/decisions/virtio.md).
# PKG=local serves the packages just built (tmp/packages) to MyNOS from
# this machine, and MyNOS upgrades the installed ones at boot: packages
# tried before they are published.
# ARCH=x86_64 runs the x86-64 build (tools/build-x86_64.sh), ARCH=aarch64
# the AArch64 one (tools/build-aarch64.sh) on QEMU's virt machine (with
# MACHINE=raspi3b on QEMU's Raspberry Pi 3, kernel8.img: the console on
# its screen too, its SD card the disk, no network yet): no text
# screen there (a virtio GPU, for the graphical session: type gui), so
# this terminal is its console (SERIAL=1); no sound, no KVM; QEMU from the
# host (with a window), or from the dev-aarch64 container (without).
# (The system as it was in 2004-2008: git checkout legacy-last, see
# doc/STATUS.md.)
#
# Extra arguments after -- go to QEMU, e.g.:
#   tools/run-demo.sh -- -serial stdio
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# x86_64 is built apart, in build/x86_64/tree (tools/build-x86_64.sh), with
# its own programs, RAM disk and disk: from the sources, run there
if [ "${ARCH:-i386}" = x86_64 ] && [ -d "$root/build/x86_64/tree/tools" ]; then
    cd "$root/build/x86_64/tree" && exec tools/run-demo.sh "$@"
fi
if [ "${ARCH:-i386}" = aarch64 ]; then
    if [ ! -d "$root/build/aarch64/tree/tools" ] && [ ! -f "$root/build/aarch64/kernel.elf" ]; then
        echo "run-demo.sh: no AArch64 build: tools/build-aarch64.sh first" >&2
        exit 1
    fi
    [ -d "$root/build/aarch64/tree/tools" ] && cd "$root/build/aarch64/tree" && exec tools/run-demo.sh "$@"
    # AArch64 (doc/decisions/aarch64.md): no text screen: the console on
    # this terminal; no Sound Blaster; the host's processor is not ARM
    export SERIAL=${SERIAL-1} SOUND= KVM=
    # (QEMU's Raspberry Pi 3, MACHINE=raspi3b: no network yet)
    [ "${MACHINE:-virt}" = raspi3b ] && export NET=
fi
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
# PKG=local: the packages just built (tools/build-all.sh, tmp/packages)
# served from this machine, before they are published: /disk/pkg/url
# names them, and /disk/pkg/autoupgrade makes MyNOS upgrade the installed
# ones at boot (pkg boot), the same versions built again too. Without
# PKG=local, those two files are taken away if they name such a server.
# (mtools never read the terminal: mmd on a folder that exists asks
# what to do, and waited there for ever)
mt() { if command -v mcopy >/dev/null; then "$@" </dev/null
       else tools/in-container.sh dev "$@" </dev/null; fi; }
pkg_server=
pkg_port=${PKG_PORT:-47120}
if [ -n "${DISK:-}" ]; then
    tmpd=$(mktemp -d)
    if [ "${PKG:-}" = local ]; then
        if [ ! -f tmp/packages/index.json ]; then
            echo "run-demo.sh: PKG=local: no tmp/packages/index.json (tools/build-all.sh builds it)" >&2
            exit 1
        fi
        printf 'http://10.0.2.2:%s\n' "$pkg_port" > "$tmpd/url"
        printf 'PKG=local tools/run-demo.sh\n' > "$tmpd/autoupgrade"
        mt mdir -i "$DISK" ::/pkg >/dev/null 2>&1 || mt mmd -i "$DISK" ::/pkg
        mt mcopy -o -i "$DISK" "$tmpd/url" ::/pkg/url
        mt mcopy -o -i "$DISK" "$tmpd/autoupgrade" ::/pkg/autoupgrade
        python3 tools/net-peer.py files "$pkg_port" tmp/packages >/dev/null 2>&1 &
        pkg_server=$!
        echo "run-demo.sh: packages from tmp/packages (http://10.0.2.2:$pkg_port), upgraded at boot" >&2
    elif mt mtype -i "$DISK" ::/pkg/url 2>/dev/null | grep -q '^http://10\.0\.2\.2:'; then
        mt mdel -i "$DISK" ::/pkg/url ::/pkg/autoupgrade 2>/dev/null || true
        echo "run-demo.sh: packages from GitHub again (PKG=local for this machine's)" >&2
    fi
    rm -rf "$tmpd"
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
# the window: with a sound card, SDL rather than GTK (QEMU's GTK window
# froze, its main loop spinning, while the sound card played);
# QEMU_DISPLAY=gtk (or another) chooses, a -display among the options too
case " $* " in
    *" -display "*|*" -nographic "*) ;;
    *)
        ui=${QEMU_DISPLAY:-}
        # AArch64: a window if QEMU is the host's (the container's has
        # none); it shows the graphical session (gui), the text console
        # being this terminal's
        if [ "${ARCH:-i386}" = aarch64 ] && ! command -v qemu-system-aarch64 >/dev/null; then
            ui=${ui:-none}
        fi
        if [ -z "$ui" ] && [ -n "${SOUND:-}" ] &&
           qemu-system-i386 -display help 2>/dev/null | grep -qx sdl; then ui=sdl; fi
        [ -n "$ui" ] && set -- -display "$ui" "$@" ;;
esac
if [ -n "${SERIAL:-}" ]; then
    set -- -chardev stdio,id=term,signal=off,mux=on -serial null \
        -serial chardev:term -mon chardev=term,mode=readline "$@"
    echo "run-demo.sh: this terminal is MyNOS's console (Ctrl-A X stops QEMU)" >&2
fi
[ -n "$pkg_server" ] || exec_=exec
status=0
${exec_:-} env MEM=${MEM:-2048} tools/run-qemu.sh \
    "$ocamlrun" \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    system/ramdisk.dsk \
    -- "$@" || status=$?
[ -n "$pkg_server" ] && kill "$pkg_server" 2>/dev/null
exit $status
