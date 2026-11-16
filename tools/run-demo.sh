#!/bin/sh
# Boot the whole system as it was in 2004-2008: the OCaml runtime with a test
# bytecode, the registry, keyboard and serial drivers, and memrofs with a RAM
# disk. Build it first with tools/build-all.sh.
#
# Module order matters: the kernel treats module 1 as the OCaml bytecode.
# Extra arguments after -- go to QEMU, e.g.:
#   tools/run-demo.sh -- -serial stdio
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ocamlrun=$(tools/ocamlrun-path.sh)

exec tools/run-qemu.sh \
    "$ocamlrun" \
    tests/hello/hello.byte \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    services/keyboard/keyboardd \
    services/serial/seriald \
    tests/ramdisk/ramdisk.dsk \
    "$@"
