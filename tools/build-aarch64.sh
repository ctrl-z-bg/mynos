#!/bin/sh
# MyNOS for AArch64 (doc/decisions/aarch64.md), built apart from the
# others as x86-64's (tools/build-x86_64.sh): the tracked sources copied
# into build/aarch64/tree, built there by the dev-aarch64 container (a
# cross toolchain: musl-gcc makes AArch64 programs, gcc the build's own
# tools, ocamlc bytecode, which is the same everywhere).
# Usage: tools/build-aarch64.sh [commands to run there instead]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tree=$root/build/aarch64/tree
mkdir -p "$tree"
(cd "$root" && git ls-files -z) | (cd "$root" && rsync -a --from0 --files-from=- ./ "$tree/")
version=$("$root/tools/version.sh")
[ "$(cat "$tree/VERSION" 2>/dev/null)" = "$version" ] || echo "$version" > "$tree/VERSION"
# what builds on AArch64 so far (the rest of build-all.sh's list comes
# as its pieces are ported)
default='
mkdir -p mynos-lib/lib
sh tools/build-kernel-aarch64.sh
make -C mynos-lib
make -C services
make -C mynos-runtime
make -C mynos-lib/ocaml
(cd tests/hello && ocamlc -o hello.byte hello.ml)
(cd tests/ramdisk && ../../services/fs/memrofs/tool/createDisk AUTOEXEC.BAT)
'
script=${*:-$default}
# MyNOS's C code was written where char is signed (x86): the same here
exec podman run --rm --platform linux/amd64 -v "$tree:/mynos:Z" -w /mynos \
    -e MYNOS_CC="musl-gcc -fsigned-char" mynos-dev-aarch64 sh -euc "$script"
