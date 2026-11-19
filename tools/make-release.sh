#!/bin/sh
# A release of MyNOS (mynos-sc9): tmp/release/mynos-VERSION.tar.gz, for
# people who have only QEMU. It holds the bootable ISO (tools/make-iso.sh),
# a clean disk (never the developer's system/disk.img), run-mynos.sh, a
# README, llm.env.example, and the licences. Build first
# (tools/build-all.sh): the version is the build's (VERSION).
#
# Usage: tools/make-release.sh        (then upload the .tar.gz to GitHub)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[ -f VERSION ] || { echo "make-release.sh: no VERSION: build first (tools/build-all.sh)" >&2; exit 1; }
version=$(cat VERSION)
name=mynos-$version
out=tmp/release
dir=$out/$name
commit=$(git rev-parse HEAD)
case "$version" in
    *-"$(git rev-parse --short HEAD)") ;;
    *) echo "make-release.sh: VERSION ($version) is not this commit's: build again" >&2; exit 1 ;;
esac
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "make-release.sh: warning: uncommitted changes; the release says commit $commit" >&2
fi
url=$(git remote get-url origin 2>/dev/null |
      sed -e 's|^git@github.com:|https://github.com/|' -e 's|\.git$||')

rm -rf "$dir" "$out/$name.tar.gz"
mkdir -p "$dir/licenses"
# the system and the clean disk
tools/make-iso.sh "$dir/mynos.iso" >/dev/null
mv "$dir/mynos-disk.img" "$dir/disk-clean.img"
cp tools/release/run-mynos.sh llm.env.example "$dir/"
sed -e "s|@VERSION@|$version|g" -e "s|@COMMIT@|$commit|g" -e "s|@URL@|${url:-the MyNOS repository}|g" \
    tools/release/README.txt > "$dir/README.txt"
# the licences: MyNOS's (GPL 2), and those of the software it contains
cp third_party/lwip/COPYING "$dir/licenses/lwIP.txt"
cp third_party/mbedtls/LICENSE "$dir/licenses/MbedTLS.txt"
cp third_party/notty/LICENSE.md "$dir/licenses/Notty.txt"
cp third_party/uutf/LICENSE.md "$dir/licenses/uutf.txt"
cp third_party/kilo/LICENSE "$dir/licenses/kilo.txt"
cp third_party/fonts/README "$dir/licenses/Terminus-font.txt"
cp third_party/ca-certificates/README.md "$dir/licenses/ca-certificates.txt"
tools/in-container.sh dev sh -c "cp /usr/share/common-licenses/GPL-2 $dir/licenses/MyNOS-GPL-2.txt &&
    cp /opt/ocaml-*/share/doc/ocaml/LICENSE $dir/licenses/OCaml.txt"
chmod +x "$dir/run-mynos.sh"
tar -C "$out" -czf "$out/$name.tar.gz" "$name"
( cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )
echo "make-release.sh: $out/$name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1)), and its .sha256"
