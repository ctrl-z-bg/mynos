#!/bin/sh
# Boot MyNOS in QEMU. QEMU loads multiboot kernels directly, so no GRUB image
# is needed: modules are passed with -initrd, in order (module 0, 1, ...).
# The kernel starts every ELF module as a process (a module "path args" gets
# those arguments), maps the module starting with .RAMDISK as the RAM disk,
# and serves module 1 as the OCaml bytecode when there is no RAM disk.
#
# Usage: tools/run-qemu.sh [module...] [-- extra qemu options]
#   tools/run-qemu.sh                       the standard system (run-demo.sh)
#   tools/run-qemu.sh -- -serial stdio      the same, with QEMU options
#   tools/run-qemu.sh services/registry/registry "tests/abi/abi one two"
#
# Environment:
#   KERNEL_ONLY  if set and no module is given, boot the bare kernel
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

# no modules: the kernel alone runs nothing; boot the standard system
if [ -z "$modules" ] && [ -z "${KERNEL_ONLY:-}" ]; then
    echo "run-qemu.sh: no modules given, booting the standard system" \
         "(tools/run-demo.sh; KERNEL_ONLY=1 for the bare kernel)" >&2
    exec "$root/tools/run-demo.sh" -- "$@"
fi

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
