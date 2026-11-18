#!/bin/sh
# Build a MyNOS build-environment image.
# Usage: tools/containers/build-image.sh dev
set -eu

name=${1:?usage: $0 dev}
here=$(cd "$(dirname "$0")" && pwd)

exec podman build --platform linux/386 \
    -t "mynos-$name" \
    -f "$here/$name/Containerfile" \
    "$here/$name"
