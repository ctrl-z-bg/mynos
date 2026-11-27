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
#   ARCH     i386 (default), x86_64 or aarch64 (QEMU, processor, kernel);
#            x86_64 runs in build/x86_64/tree, its build
#            (tools/build-x86_64.sh), aarch64 in build/aarch64/tree
#            (tools/build-aarch64.sh) on QEMU's virt machine: the modules
#            in one archive (tools/mkmodules.py), virtio devices only
#            (disk, network card, keyboard, tablet, GPU), one
#            UART (a caller's two -serial: the second, COM2's, is kept),
#            RAM 128 MB to 1 GB; the host's qemu-system-aarch64, or the
#            dev-aarch64 container's (no window from there)
#   MACHINE  aarch64: virt (the default) or raspi3b, QEMU's Raspberry Pi 3
#            (btq.7: build/aarch64/kernel8.img, the archive at 64 MB, its
#            1 GB, its four processors; DISK its SD card; no network,
#            keyboard or mouse yet)
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
#   POINTER  aarch64: tablet (the default: absolute, no grab in a window)
#            or mouse (relative, as the PC's PS/2 mouse: QEMU's monitor's
#            mouse_move, which the graphical tests use)
#   SHOT     if set, run headless, save a PNG of the screen to $SHOT after
#            $WAIT seconds (default 3), then stop QEMU
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# x86_64 is built apart, in build/x86_64/tree (tools/build-x86_64.sh), with
# its own programs, RAM disk and disk: from the sources, run there
if [ "${ARCH:-i386}" = x86_64 ] && [ -d "$root/build/x86_64/tree/tools" ]; then
    cd "$root/build/x86_64/tree" && exec tools/run-qemu.sh "$@"
fi
if [ "${ARCH:-i386}" = aarch64 ] && [ -d "$root/build/aarch64/tree/tools" ]; then
    cd "$root/build/aarch64/tree" && exec tools/run-qemu.sh "$@"
fi
# the architecture: i386 (the default) or x86_64, whose kernel
# tools/build-x86_64.sh makes in build/x86_64
case ${ARCH:-i386} in
    x86_64) qemu=qemu-system-x86_64 cpu=qemu64,+rdrand,+rdseed smp=${SMP:-4}   # four processors (mynos-btq.5)
            kernel=${KERNEL:-$root/build/x86_64/kernel.elf} ;;
    aarch64) qemu=qemu-system-aarch64 cpu=cortex-a72 smp=${SMP:-4}  # four processors, as x86-64
            kernel=${KERNEL:-$root/build/aarch64/kernel.elf}
            if [ "${MACHINE:-virt}" = raspi3b ]; then   # its own processors (four A53)
                cpu= smp= kernel=${KERNEL:-$root/build/aarch64/kernel8.img}
            fi ;;
    *)      qemu=qemu-system-i386 cpu=qemu32,+rdrand,+rdseed smp=      # one processor
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

# AArch64 (QEMU virt, doc/decisions/aarch64.md): virtio devices only, no
# sound card, no KVM (the host is a PC); one UART, COM2's part: of a
# caller's two -serial (COM1's, COM2's) the second is kept. A caller's
# PC options go (-machine, -vga: the machine is virt), and the devices
# virt always has here (keyboard, tablet, GPU) are not added twice
if [ "${ARCH:-i386}" = aarch64 ]; then
    VIRTIO=1 audio= KVM= rom=,romfile=     # (no network boot ROM: no firmware)
    [ "${MACHINE:-virt}" = raspi3b ] && NET=    # (a Pi 3's network is USB's: not yet)
    n=0
    for a; do [ "$a" = -serial ] && n=$((n + 1)); done
    drop=$((n >= 2)) skip= prev=
    for a; do
        shift
        if [ -n "$skip" ]; then skip= prev=; continue; fi
        case $prev$a in
            -serial) if [ "$drop" = 1 ]; then drop=0 skip=1; continue; fi ;;
            -machine|-vga) skip=1; continue ;;
            -device) prev=-device; continue ;;
            -devicevirtio-keyboard-pci|-devicevirtio-gpu-pci|-devicevirtio-${POINTER:-tablet}-pci)
                prev=; continue ;;
            -device*) set -- "$@" -device ;;
        esac
        prev=
        set -- "$@" "$a"
    done
fi

# the disk and the network card: virtio devices, or the PC's IDE and NE2000;
# a Raspberry Pi's disk is its SD card (sdhcid; QEMU wants its size a
# power of 2)
if [ "${ARCH:-i386}" = aarch64 ] && [ "${MACHINE:-virt}" = raspi3b ]; then
    disk_if=sd disk_dev=
elif [ -n "${VIRTIO:-}" ]; then
    disk_if=none,id=vd disk_dev="-device virtio-blk-pci,drive=vd"
    net_dev=virtio-net-pci,netdev=n0${rom:-}
else
    disk_if=ide,index=0 disk_dev=
    net_dev=ne2k_isa,netdev=n0,iobase=0x300,irq=9
fi

# how the kernel and its modules are loaded: multiboot (-kernel, -initrd,
# -append), or on AArch64 the kernel's ELF image and one archive of the
# modules that QEMU puts at 64 MB into RAM (tools/mkmodules.py: the
# kernel's command line in it); RAM from 128 MB (the archive's place) to
# 1 GB (the kernel's physical numbering, choice 3)
# shellcheck disable=SC2086
set -- ${cpu:+-cpu "${CPU:-$cpu}"} \
    ${KVM:+-accel kvm} ${smp:+-smp $smp} \
    ${DISK:+-drive file=$DISK,format=raw,if=$disk_if} ${DISK:+$disk_dev} \
    ${NET:+-netdev user,id=n0${HTTP:+,hostfwd=tcp:127.0.0.1:$HTTP-:80}${UDP:+,hostfwd=udp::$UDP-:$UDP}} \
    ${NET:+-device $net_dev} $audio "$@"
mem=${MEM:-32} archive=
if [ "${ARCH:-i386}" = aarch64 ]; then
    [ "$mem" -lt 128 ] && mem=128
    [ "$mem" -gt 1024 ] && mem=1024
    mkdir -p "$root/tmp"
    archive=$(mktemp "$root/tmp/modules-XXXXXX")
    old_ifs=$IFS; IFS=,
    # shellcheck disable=SC2086
    python3 "$root/tools/mkmodules.py" ${VERBOSE:+-c verbose} "$archive" $modules
    IFS=$old_ifs
    # (virt's own network card, without NET, would want a boot ROM)
    nonic=; [ -z "${NET:-}" ] && nonic="-nic none"
    if [ "${MACHINE:-virt}" = raspi3b ]; then
        # (its RAM at 0: the archive at 64 MB, where kernel8.img looks)
        set -- -M raspi3b -kernel "$kernel" -m 1G \
            -device "loader,file=$archive,addr=0x04000000,force-raw=on" "$@"
    else
    # shellcheck disable=SC2086
    set -- -M virt -kernel "$kernel" -m "$mem" $nonic \
        -device "loader,file=$archive,addr=0x44000000,force-raw=on" \
        -device virtio-keyboard-pci -device "virtio-${POINTER:-tablet}-pci" \
        -device virtio-gpu-pci "$@"
    fi
else
    set -- -kernel "$kernel" ${modules:+-initrd "$modules"} -m "$mem" \
        ${VERBOSE:+-append verbose} "$@"
fi

# QEMU: the host's, or (qemu-system-aarch64, which a PC may not have) the
# dev-aarch64 container's, with this tree, /tmp and the disk's folder at
# their own paths, the host's network (HTTP's forwarding), no window
run=$qemu
if ! command -v "$qemu" >/dev/null 2>&1 && [ "${ARCH:-i386}" = aarch64 ]; then
    tty=; [ -t 0 ] && tty=-it
    disk_dir=; [ -n "${DISK:-}" ] && disk_dir=$(cd "$(dirname "$DISK")" && pwd)
    case $disk_dir in "$root"|"$root"/*|/tmp|/tmp/*) disk_dir= ;; esac
    run="podman run --rm $tty --platform linux/amd64 --network host -v $root:$root:Z -v /tmp:/tmp ${disk_dir:+-v $disk_dir:$disk_dir} -w $root mynos-dev-aarch64 $qemu"
    case " $* " in *" -display "*|*" -nographic "*) ;; *) [ -n "${SHOT:-}" ] || set -- "$@" -display none ;; esac
fi

if [ -z "${SHOT:-}" ]; then
    if [ -z "$archive" ]; then exec $run "$@"; fi
    trap 'rm -f "$archive"' EXIT
    trap 'exit 143' TERM INT
    status=0
    $run "$@" || status=$?
    exit $status
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp" ${archive:+"$archive"}' EXIT
$run "$@" -display none \
    -monitor "unix:$tmp/mon,server,nowait" &
pid=$!
sleep "${WAIT:-3}"
printf 'screendump %s/screen.ppm\nquit\n' "$tmp" | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
wait "$pid" || true
convert "$tmp/screen.ppm" "$SHOT"
echo "screenshot: $SHOT"
