#!/bin/sh
# Ariadne's quick loop (BROWSER-TODO.md, M0): build only ariadne for
# x86-64, put it on the disk as /disk/bin/ariadne.byte, which PATH finds
# before the RAM disk's, and boot MyNOS: no new RAM disk, no full build.
# Needs one full build first (tools/build-x86_64.sh). New files must be
# known to git (git add), since the build copies what git tracks.
# Usage: tools/ariadne-dev.sh [tools/run-demo.sh's arguments]
#   tools/ariadne-dev.sh                       QEMU's window; then, in MyNOS,
#                                              gui, and ariadne in a Terminal
#   SERIAL=1 tools/ariadne-dev.sh -- -display none
#                                              this terminal: ariadne --dump URL
# Without the disk's copy (the RAM disk's ariadne again): rm /disk/bin/ariadne.byte
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
"$root/tools/build-x86_64.sh" 'make -C ariadne &&
    { mmd -i system/disk.img ::/bin 2>/dev/null || true; } &&
    mcopy -o -i system/disk.img ariadne/ariadne.byte ::/bin/ariadne.byte &&
    echo "ariadne-dev.sh: /disk/bin/ariadne.byte updated"'
ARCH=x86_64 exec "$root/tools/run-demo.sh" "$@"
