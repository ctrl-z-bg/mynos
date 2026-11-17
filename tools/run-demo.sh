#!/bin/sh
# Boot MyNOS in QEMU. Build it first with tools/build-all.sh.
#
# With the dev toolchain, it boots MyNOS with the system RAM disk (system/):
# ocamlrun runs init, which starts the services (console, tmpfs, the ATA
# driver and fatfs, which mounts system/disk.img at /disk, the network with
# an NE2000 card on QEMU's user network, httpd) and sh. Type help; "ocaml"
# opens the OCaml toplevel. NET= (empty) boots without a network card;
# HTTP=PORT forwards another host port to httpd. llm.env, if there is one
# (see llm.env.example), is copied into the disk as /disk/llm.env, for llmd.
# SERIAL=1 makes this terminal a console of MyNOS too (its second serial
# port: doc/decisions/console.md), with the host's copy and paste,
# scrollback and fonts; QEMU's window shows the same. Ctrl-C goes to MyNOS:
# close the window, or type Ctrl-A then X, to stop QEMU.
#
# Otherwise (legacy toolchain, or DEMO=2008) it boots the system as it was in
# 2004-2008: the OCaml runtime with a test bytecode, the registry, keyboard
# and serial drivers, and memrofs with a RAM disk. Module order matters: the
# kernel treats module 1 as the OCaml bytecode.
#
# Extra arguments after -- go to QEMU, e.g.:
#   tools/run-demo.sh -- -serial stdio
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ocamlrun=$(tools/ocamlrun-path.sh)

if [ "${DEMO:-}" != 2008 ] && [ -f system/ramdisk.dsk ]; then
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
fi

keyboard=services/keyboard/keyboardd
[ -f services/console/consoled ] && keyboard=services/console/consoled

exec tools/run-qemu.sh \
    "$ocamlrun" \
    tests/hello/hello.byte \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    "$keyboard" \
    services/serial/seriald \
    tests/ramdisk/ramdisk.dsk \
    "$@"
