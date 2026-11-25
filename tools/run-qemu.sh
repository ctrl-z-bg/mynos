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
#   ARCH     i386 (default) or x86_64 (QEMU, processor, kernel); x86_64
#            runs in build/x86_64/tree, its build (tools/build-x86_64.sh)
#   KERNEL   kernel image (default: mynos-core/kernel/kernel.elf; for
#            x86_64 build/x86_64/kernel.elf)
#   MEM      RAM in MB (default 32)
#   CPU      QEMU's processor (default qemu32 with RDRAND and RDSEED, which
#            seed the kernel's random numbers)
#   DISK     a raw disk image, attached as the first IDE disk
#   NET      if set, an NE2000 card (I/O 0x300) on QEMU's user network:
#            MyNOS gets 10.0.2.15 by DHCP, the host is 10.0.2.2
#   HTTP     with NET, a host port forwarded to MyNOS's port 80 (httpd)
#   UDP      with NET, a UDP port of the host forwarded to the same port of
#            MyNOS, from any address (GavML's network game: UDP=7145)
#   VIRTIO   if set, DISK and NET are virtio devices (virtio-blk-pci,
#            virtio-net-pci: vblkd and netd's virtio driver) instead of
#            an IDE disk and an NE2000 (doc/decisions/virtio.md)
#   KVM      if set, the host's processor runs MyNOS's (KVM: /dev/kvm),
#            far faster than emulating it; run-demo.sh sets it if it can
#   SOUND    a Sound Blaster 16 (soundd), heard through this audio backend
#            of QEMU's (pipewire, pa, alsa, coreaudio...), or wav:FILE to
#            record it; run-demo.sh picks one
#   VERBOSE  if set, kernel messages stay on screen after boot (they always
#            go to the second serial port)
#   SHOT     if set, run headless, save a PNG of the screen to $SHOT after
#            $WAIT seconds (default 3), then stop QEMU
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# x86_64 is built apart, in build/x86_64/tree (tools/build-x86_64.sh), with
# its own programs, RAM disk and disk: from the sources, run there
if [ "${ARCH:-i386}" = x86_64 ] && [ -d "$root/build/x86_64/tree/tools" ]; then
    cd "$root/build/x86_64/tree" && exec tools/run-qemu.sh "$@"
fi
# the architecture: i386 (the default) or x86_64, whose kernel
# tools/build-x86_64.sh makes in build/x86_64
case ${ARCH:-i386} in
    x86_64) qemu=qemu-system-x86_64 cpu=qemu64,+rdrand,+rdseed
            kernel=${KERNEL:-$root/build/x86_64/kernel.elf} ;;
    *)      qemu=qemu-system-i386 cpu=qemu32,+rdrand,+rdseed
            kernel=${KERNEL:-$root/mynos-core/kernel/kernel.elf} ;;
esac

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

audio=
case ${SOUND:-} in
    "") ;;
    wav:*) audio="-audiodev wav,id=snd,path=${SOUND#wav:} -device sb16,audiodev=snd" ;;
    *) audio="-audiodev $SOUND,id=snd -device sb16,audiodev=snd" ;;
esac

# the disk and the network card: virtio devices, or the PC's IDE and NE2000
if [ -n "${VIRTIO:-}" ]; then
    disk_if=none,id=vd disk_dev="-device virtio-blk-pci,drive=vd"
    net_dev=virtio-net-pci,netdev=n0
else
    disk_if=ide,index=0 disk_dev=
    net_dev=ne2k_isa,netdev=n0,iobase=0x300,irq=9
fi

# shellcheck disable=SC2086
set -- -kernel "$kernel" ${modules:+-initrd "$modules"} -m "${MEM:-32}" \
    -cpu "${CPU:-$cpu}" \
    ${VERBOSE:+-append verbose} ${KVM:+-accel kvm} ${SMP:+-smp $SMP} \
    ${DISK:+-drive file=$DISK,format=raw,if=$disk_if} ${DISK:+$disk_dev} \
    ${NET:+-netdev user,id=n0${HTTP:+,hostfwd=tcp:127.0.0.1:$HTTP-:80}${UDP:+,hostfwd=udp::$UDP-:$UDP}} \
    ${NET:+-device $net_dev} $audio "$@"

if [ -z "${SHOT:-}" ]; then
    exec $qemu "$@"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
$qemu "$@" -display none \
    -monitor "unix:$tmp/mon,server,nowait" &
pid=$!
sleep "${WAIT:-3}"
printf 'screendump %s/screen.ppm\nquit\n' "$tmp" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
wait "$pid" || true
convert "$tmp/screen.ppm" "$SHOT"
echo "screenshot: $SHOT"
