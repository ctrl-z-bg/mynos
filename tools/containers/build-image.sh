#!/bin/sh
# Build a MyNOS build-environment image.
# Usage: tools/containers/build-image.sh dev
set -eu

name=${1:?usage: $0 dev}
here=$(cd "$(dirname "$0")" && pwd)

case $name in *x86_64*) platform=linux/amd64 ;; *) platform=linux/386 ;; esac

exec podman build --platform $platform \
    -t "mynos-$name" \
    -f "$here/$name/Containerfile" \
    "$here/$name"
