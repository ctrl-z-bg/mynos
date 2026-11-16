#!/bin/sh
# Run a command inside a MyNOS build-environment container, with the
# repository mounted at /mynos. Rootless podman maps the container's root to
# your user, so files created by the build stay owned by you.
#
# Usage: tools/in-container.sh <legacy|dev> [command...]
#   tools/in-container.sh legacy make -C mynos-core
#   tools/in-container.sh legacy            # interactive shell
set -eu

name=${1:?usage: $0 <legacy|dev> [command...]}
shift
root=$(cd "$(dirname "$0")/.." && pwd)

tty=
[ -t 0 ] && tty=-it

[ $# -eq 0 ] && set -- bash

exec podman run --rm $tty --platform linux/386 \
    -v "$root:/mynos:Z" -w /mynos \
    "mynos-$name" "$@"
