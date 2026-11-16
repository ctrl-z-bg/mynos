#!/bin/sh
# Boot the whole system headless in QEMU, capture the kernel console (mirrored
# to COM2) and check the expected output. Build first with tools/build-all.sh.
#
# Usage: tools/run-tests.sh            exit status 0 if all checks pass
# Environment: WAIT seconds to let the system run (default 8)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

timeout "${WAIT:-8}" tools/run-qemu.sh \
    mynos-byterun/src/ocamlrun \
    tests/hello/hello.byte \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    services/keyboard/keyboardd \
    services/serial/seriald \
    tests/abi/abi \
    tests/ramdisk/ramdisk.dsk \
    -- -display none -serial null -serial "file:$log" || true

fail=0
expect() {
    if grep -qF -- "$1" "$log"; then
        echo "ok    $1"
    else
        echo "FAIL  $1"; fail=1
    fi
}
reject() {
    if grep -qF -- "$1" "$log"; then
        echo "FAIL  unexpected: $1"; fail=1
    fi
}

expect "Hello from OCaml on MyNOS!"
expect "5 * 5 = 25"
expect "Service keyboard registered"
expect "Service serial registered"
expect "Hello from memrofs!"
expect "abi: all checks passed"
reject "PANIC"
reject "page fault (?)"
reject "FAIL"

if [ $fail -ne 0 ]; then
    echo "--- console log ---"
    cat "$log"
    exit 1
fi
echo "all tests passed"
