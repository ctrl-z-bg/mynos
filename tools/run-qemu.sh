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
#   CPU      QEMU's processor (default qemu32 with RDRAND and RDSEED, which
#            seed the kernel's random numbers)
#   DISK     a raw disk image, attached as the first IDE disk
#   NET      if set, an NE2000 card (I/O 0x300) on QEMU's user network:
#            MyNOS gets 10.0.2.15 by DHCP, the host is 10.0.2.2
#   HTTP     with NET, a host port forwarded to MyNOS's port 80 (httpd)
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
    -cpu "${CPU:-qemu32,+rdrand,+rdseed}" \
    ${VERBOSE:+-append verbose} \
    ${DISK:+-drive file=$DISK,format=raw,if=ide,index=0} \
    ${NET:+-netdev user,id=n0${HTTP:+,hostfwd=tcp:127.0.0.1:$HTTP-:80}} \
    ${NET:+-device ne2k_isa,netdev=n0,iobase=0x300,irq=9} "$@"

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
