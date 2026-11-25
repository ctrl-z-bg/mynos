#!/bin/sh
# Run a command inside a MyNOS build-environment container, with the
# repository mounted at /mynos. Rootless podman maps the container's root to
# your user, so files created by the build stay owned by you.
#
# Usage: tools/in-container.sh <image> [command...]   (the image: dev)
#   tools/in-container.sh dev make -C mynos-core
#   tools/in-container.sh dev               # interactive shell
set -eu

name=${1:?usage: $0 dev [command...]}
shift
root=$(cd "$(dirname "$0")/.." && pwd)

tty=
[ -t 0 ] && tty=-it

[ $# -eq 0 ] && set -- bash

# already inside the test container (tools/containers/test), which has
# the tools the suite asks the dev container for (mtools): run them here
if [ -n "${MYNOS_TEST_CONTAINER:-}" ]; then
    cd "$root" && exec "$@"
fi

# the image's architecture: dev-x86_64 is amd64, the others i386
case $name in *x86_64*|*aarch64*|test) platform=linux/amd64 ;; *) platform=linux/386 ;; esac

exec podman run --rm $tty --platform $platform \
    -v "$root:/mynos:Z" -w /mynos \
    "mynos-$name" "$@"
