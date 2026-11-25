#!/bin/sh
# MyNOS for x86-64 (doc/decisions/x86-64.md), built apart from the i386
# build: the tracked sources copied into build/x86_64/tree, built there by
# the dev-x86_64 container, so that the two architectures' objects never
# mix. Usage: tools/build-x86_64.sh [make targets, as directories...]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tree=$root/build/x86_64/tree
mkdir -p "$tree"
# the sources: what git tracks, and the third-party files the build needs
(cd "$root" && git ls-files -z) | (cd "$root" && rsync -a --from0 --files-from=- ./ "$tree/")
# the version (tools/version.sh: the tree is not a git checkout), rewritten
# only when it changes, as build-all.sh does
version=$("$root/tools/version.sh")
[ "$(cat "$tree/VERSION" 2>/dev/null)" = "$version" ] || echo "$version" > "$tree/VERSION"
# what to run there: the arguments, or the whole build of build-all.sh
# (its commands, but the kernel's: tools/build-kernel-x86_64.sh's)
if [ $# -gt 0 ]; then
    script="$*"
else
    script=$(sed -n "/^exec \"\$root\/tools\/in-container.sh\" dev sh -euc '/,/^'\$/p" "$root/tools/build-all.sh" |
             sed '1d;$d' | sed 's@^make -C mynos-core/kernel$@sh tools/build-kernel-x86_64.sh@')
fi
exec podman run --rm --platform linux/amd64 -v "$tree:/mynos:Z" -w /mynos \
    mynos-dev-x86_64 sh -euc "$script"
