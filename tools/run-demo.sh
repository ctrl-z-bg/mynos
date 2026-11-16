#!/bin/sh
# Boot MyNOS in QEMU. Build it first with tools/build-all.sh.
#
# With the dev toolchain, it boots the shell: the OCaml toplevel, with the
# registry, memrofs, the console service and a RAM disk (shell/). Type OCaml
# phrases ended by ;; for instance help ();;
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

if [ "${DEMO:-}" != 2008 ] && [ -f shell/ramdisk.dsk ] &&
   [ -f services/console/consoled ]; then
    MEM=${MEM:-256} exec tools/run-qemu.sh \
        "$ocamlrun" \
        services/registry/registry \
        services/fs/memrofs/memrofsd \
        services/console/consoled \
        shell/ramdisk.dsk \
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
