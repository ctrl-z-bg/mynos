#!/bin/sh
# Boot MyNOS in QEMU. QEMU loads multiboot kernels directly, so no GRUB image
# is needed: modules are passed with -initrd, in order (module 0, 1, ...).
# The kernel treats module 1 as the OCaml bytecode and starts every ELF
# module as a process.
#
# Usage: tools/run-qemu.sh [module...] [-- extra qemu options]
#   tools/run-qemu.sh
#   tools/run-qemu.sh services/registry/registry hello.byte
#
# Environment:
#   KERNEL   kernel image (default: mynos-core/kernel/kernel.elf)
#   MEM      RAM in MB (default 32)
#   VERBOSE  if set, kernel messages stay on screen after boot (they always
#            go to the second serial port)
#   SHOT     if set, run headless, save a PNG of the screen to $SHOT after
#            $WAIT seconds (default 3), then stop QEMU
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
kernel=${KERNEL:-$root/mynos-core/kernel/kernel.elf}

modules=
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    modules=${modules:+$modules,}$1
    shift
done
[ "${1:-}" = "--" ] && shift

set -- -kernel "$kernel" ${modules:+-initrd "$modules"} -m "${MEM:-32}" \
    ${VERBOSE:+-append verbose} "$@"

if [ -z "${SHOT:-}" ]; then
    exec qemu-system-i386 "$@"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qemu-system-i386 "$@" -display none \
    -monitor "unix:$tmp/mon,server,nowait" &
pid=$!
sleep "${WAIT:-3}"
printf 'screendump %s/screen.ppm\nquit\n' "$tmp" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
wait "$pid" || true
convert "$tmp/screen.ppm" "$SHOT"
echo "screenshot: $SHOT"
