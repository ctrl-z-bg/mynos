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
# (a Raspberry Pi has no clock: its kernel's time starts at the last
# commit's, tools/build-kernel-aarch64.sh)
epoch=$(git -C "$root" log -1 --format=%ct 2>/dev/null || echo 0)
[ "$(cat "$tree/EPOCH" 2>/dev/null)" = "$epoch" ] || echo "$epoch" > "$tree/EPOCH"
# what to run there: the arguments, or the whole build of build-all.sh
# (its commands, but the kernel's: tools/build-kernel-aarch64.sh's), with
# the cross toolchain's strip for the programs
default=$(sed -n "/^exec \"\$root\/tools\/in-container.sh\" dev sh -euc '/,/^'\$/p" "$root/tools/build-all.sh" |
          sed '1d;$d' |
          sed 's@^make -C mynos-core/kernel$@sh tools/build-kernel-aarch64.sh@')
default="export STRIP=aarch64-linux-gnu-strip
$default"
script=${*:-$default}
# MyNOS's C code was written where char is signed (x86): the same here
exec podman run --rm --platform linux/amd64 -v "$tree:/mynos:Z" -w /mynos \
    -e MYNOS_CC="musl-gcc -fsigned-char" mynos-dev-aarch64 sh -euc "$script"
