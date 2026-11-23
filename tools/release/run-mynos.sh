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
#   --mem MB      the memory (default 2048; MyNOS uses at most 3072)
#   --no-kvm      emulate the processor even if KVM (/dev/kvm) is there
#   --no-sound    no sound card (by default a Sound Blaster 16, through
#                 the host's audio: pipewire, pulseaudio, alsa, coreaudio)
#   --reset-disk  start /disk again, empty (disk.img is replaced)
#   --udp PORT    this machine's UDP port PORT forwarded to MyNOS's (GavML's
#                 network game: --udp 7145)
#   --display UI  QEMU's window: sdl (the default with sound, when this
#                 QEMU has it: with gtk and a sound card QEMU's window
#                 could freeze), gtk, or another of qemu -display help
#
# A llm.env beside this script (see llm.env.example) is copied into the
# disk at every start, if mtools' mcopy is installed; otherwise write
# /disk/llm.env inside MyNOS (edit /disk/llm.env).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

serial= net=1 http=8080 http_given= mem=2048 reset= kvm=1 sound=1 ui= udp=
while [ $# -gt 0 ]; do
    case "$1" in
        --serial) serial=1 ;;
        --no-net) net= ;;
        --http) http=${2:?--http PORT}; http_given=1; shift ;;
        --mem) mem=${2:?--mem MB}; shift ;;
        --reset-disk) reset=1 ;;
        --no-kvm) kvm= ;;
        --no-sound) sound= ;;
        --display) shift; ui=${1:?--display needs a name} ;;
        --udp) shift; udp=${1:?--udp needs a port} ;;
        --) shift; break ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    if [ -n "$udp" ]; then
        fwd="$fwd,hostfwd=udp::$udp-:$udp"
        echo "run-mynos.sh: UDP port $udp of this machine goes to MyNOS's" >&2
    fi
    netopts="-netdev user,id=n0$fwd -device ne2k_isa,netdev=n0,iobase=0x300,irq=9"
fi

# KVM: the host's processor runs MyNOS's, far faster than emulating it
accel=
if [ -n "$kvm" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="-accel kvm"
    echo "run-mynos.sh: KVM on (--no-kvm to emulate the processor)" >&2
elif [ -n "$kvm" ]; then
    echo "run-mynos.sh: no /dev/kvm to use: the processor is emulated (slower)" >&2
fi

# sound: a Sound Blaster 16, through the host's audio, by a backend this
# QEMU has (without one, MyNOS runs silent)
audio=
if [ -n "$sound" ]; then
    backends=$(qemu-system-i386 -audiodev help 2>/dev/null)
    has() { printf '%s\n' "$backends" | grep -qx "$1"; }
    run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    be=
    if [ -S "$run/pipewire-0" ] && has pipewire; then be=pipewire
    elif [ -S "$run/pulse/native" ] && has pa; then be=pa
    elif [ "$(uname)" = Darwin ] && has coreaudio; then be=coreaudio
    elif [ -d /dev/snd ] && has alsa; then be=alsa
    fi
    if [ -n "$be" ]; then
        audio="-audiodev $be,id=snd -device sb16,audiodev=snd"
        echo "run-mynos.sh: sound through $be (--no-sound for none)" >&2
    fi
fi

if [ -n "$serial" ]; then
    set -- -chardev stdio,id=term,signal=off,mux=on -serial null \
        -serial chardev:term -mon chardev=term,mode=readline "$@"
    echo "run-mynos.sh: this terminal is MyNOS's console too (Ctrl-A X stops QEMU)" >&2
fi

# the window: with a sound card, SDL rather than GTK (QEMU's GTK window
# froze, its main loop spinning, while the sound card played), unless
# the options choose one
case " $* " in
    *" -display "*|*" -nographic "*) ;;
    *)
        if [ -z "$ui" ] && [ -n "$audio" ] &&
           qemu-system-i386 -display help 2>/dev/null | grep -qx sdl; then ui=sdl; fi
        [ -n "$ui" ] && set -- -display "$ui" "$@" ;;
esac

# -boot d: the BIOS would try the disk first, which is not bootable
# shellcheck disable=SC2086
exec qemu-system-i386 -boot d -cdrom mynos.iso -m "$mem" \
    -cpu qemu32,+rdrand,+rdseed $accel $audio \
    -drive file=disk.img,format=raw,if=ide,index=0 \
    $netopts "$@"
