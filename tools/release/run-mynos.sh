#!/bin/sh
# Run MyNOS, from a release: this directory holds mynos.iso (the system,
# booted by GRUB) and disk-clean.img (an empty disk). The first run copies
# the clean disk to disk.img, MyNOS's /disk, which keeps what you save.
# Only QEMU is needed (qemu-system-i386).
#
# Usage: ./run-mynos.sh [OPTIONS] [-- QEMU OPTIONS]
#   --serial      this terminal is a console of MyNOS too (its second
#                 serial port), with your terminal's copy and paste;
#                 Ctrl-A then X stops QEMU
#   --no-net      no network card
#   --http PORT   the host port forwarded to MyNOS's web server (default
#                 8080, if it is free; 0: none)
#   --mem MB      the memory (default 256)
#   --reset-disk  start /disk again, empty (disk.img is replaced)
#
# A llm.env beside this script (see llm.env.example) is copied into the
# disk at every start, if mtools' mcopy is installed; otherwise write
# /disk/llm.env inside MyNOS (edit /disk/llm.env).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

serial= net=1 http=8080 http_given= mem=256 reset=
while [ $# -gt 0 ]; do
    case "$1" in
        --serial) serial=1 ;;
        --no-net) net= ;;
        --http) http=${2:?--http PORT}; http_given=1; shift ;;
        --mem) mem=${2:?--mem MB}; shift ;;
        --reset-disk) reset=1 ;;
        --) shift; break ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "run-mynos.sh: unknown option $1 (--help)" >&2; exit 2 ;;
    esac
    shift
done

if ! command -v qemu-system-i386 >/dev/null 2>&1; then
    cat >&2 <<'MSG'
run-mynos.sh: QEMU is needed (qemu-system-i386), for instance:
  Debian, Ubuntu:  sudo apt install qemu-system-x86
  Fedora:          sudo dnf install qemu-system-x86
  macOS:           brew install qemu
MSG
    exit 1
fi
for f in mynos.iso disk-clean.img; do
    [ -f "$f" ] || { echo "run-mynos.sh: $f is missing beside this script" >&2; exit 1; }
done

# the disk: a copy of the clean one, kept between runs
if [ -n "$reset" ] || [ ! -f disk.img ]; then
    cp disk-clean.img disk.img
    echo "run-mynos.sh: /disk is a new, empty disk (disk.img)" >&2
fi

# the language models' configuration, into the disk
if [ -f llm.env ]; then
    if command -v mcopy >/dev/null 2>&1; then
        mcopy -o -i disk.img llm.env ::/llm.env && \
            echo "run-mynos.sh: llm.env copied to /disk/llm.env" >&2
    else
        echo "run-mynos.sh: llm.env not copied (no mcopy): write /disk/llm.env inside MyNOS" >&2
    fi
fi

# the network: QEMU's user network, and the web server's port
netopts=
if [ -n "$net" ]; then
    fwd=
    if [ "$http" != 0 ]; then
        free=yes
        if [ -z "$http_given" ] && command -v python3 >/dev/null 2>&1; then
            python3 -c "import socket; socket.socket().bind(('127.0.0.1', $http))" \
                2>/dev/null || free=
        fi
        if [ -n "$free" ]; then
            fwd=",hostfwd=tcp:127.0.0.1:$http-:80"
            echo "run-mynos.sh: http://localhost:$http/ is MyNOS's web server" >&2
        else
            echo "run-mynos.sh: port $http is busy: no web server forwarding (--http PORT)" >&2
        fi
    fi
    netopts="-netdev user,id=n0$fwd -device ne2k_isa,netdev=n0,iobase=0x300,irq=9"
fi

if [ -n "$serial" ]; then
    set -- -chardev stdio,id=term,signal=off,mux=on -serial null \
        -serial chardev:term -mon chardev=term,mode=readline "$@"
    echo "run-mynos.sh: this terminal is MyNOS's console too (Ctrl-A X stops QEMU)" >&2
fi

# -boot d: the BIOS would try the disk first, which is not bootable
# shellcheck disable=SC2086
exec qemu-system-i386 -boot d -cdrom mynos.iso -m "$mem" \
    -cpu qemu32,+rdrand,+rdseed \
    -drive file=disk.img,format=raw,if=ide,index=0 \
    $netopts "$@"
