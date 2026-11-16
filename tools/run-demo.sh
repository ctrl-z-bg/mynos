#!/bin/sh
# Boot MyNOS in QEMU. Build it first with tools/build-all.sh.
#
# With the dev toolchain, it boots MyNOS with the system RAM disk (system/):
# ocamlrun runs init, which starts the services (console, tmpfs, the ATA
# driver and fatfs, which mounts system/disk.img at /disk) and the shell,
# the OCaml toplevel. Type OCaml phrases ended by ;; for instance help ();;
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
    MEM=${MEM:-256} exec tools/run-qemu.sh \
        "$ocamlrun" \
        services/registry/registry \
        services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        "$@"
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
