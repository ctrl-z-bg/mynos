#!/bin/sh
# MyNOS in the browser (mynos-2a2): a static site, for GitHub Pages, that
# runs a release's ISO and clean disk on v86 (a PC in JavaScript and
# WebAssembly), without network. The images are split in chunks of 1 MB,
# compressed with zstd, which v86 fetches only when the guest reads them.
# v86 and its BIOS are downloaded at fixed versions, checked by sha256.
#
# Usage: tools/make-web.sh RELEASE_DIR [OUT]
#   RELEASE_DIR  tmp/release/mynos-VERSION (tools/make-release.sh)
#   OUT          default tmp/web
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
rel=${1:?usage: make-web.sh RELEASE_DIR [OUT]}
out=${2:-$root/tmp/web}
cd "$root"
[ -f "$rel/mynos.iso" ] && [ -f "$rel/disk-clean.img" ] || { echo "make-web.sh: no release in $rel" >&2; exit 1; }
version=$(sed -n 's/^MyNOS \(.*\)$/\1/p' "$rel/README.txt" | head -1)
command -v zstd >/dev/null || { echo "make-web.sh: zstd is needed" >&2; exit 1; }

V86=0.5.473
V86_SHA=364ab67a68c1d83646e2ddf7caf73c24574694a132b2b43689ad0f72e7242636
BIOS_COMMIT=b8a39b11dd2076870699e6cac053556271b9bfab
SEABIOS_SHA=73e3f359102e3a9982c35fce98eb7cd08f18303ac7f1ba6ebfbe6cdc1c244d98
VGABIOS_SHA=a4bc0d80cc3ca028c73dafa8fee396b8d054ce87ebd8abfbd31b06b437607880
CHUNK=1048576

# v86 and the BIOS, once, in tmp/web-cache
cache=tmp/web-cache
mkdir -p "$cache"
fetch() {   # URL FILE SHA256
    if ! echo "$3  $2" | sha256sum -c --status >/dev/null 2>&1; then
        curl -sSfL -o "$2" "$1"
        echo "$3  $2" | sha256sum -c --status || { echo "make-web.sh: $2: wrong sha256" >&2; rm -f "$2"; exit 1; }
    fi
}
fetch "https://registry.npmjs.org/v86/-/v86-$V86.tgz" "$cache/v86-$V86.tgz" "$V86_SHA"
fetch "https://raw.githubusercontent.com/copy/v86/$BIOS_COMMIT/bios/seabios.bin" "$cache/seabios.bin" "$SEABIOS_SHA"
fetch "https://raw.githubusercontent.com/copy/v86/$BIOS_COMMIT/bios/vgabios.bin" "$cache/vgabios.bin" "$VGABIOS_SHA"

# the images under a directory of their version: a browser that still
# holds a chunk of the last release (GitHub Pages: 10 minutes) never mixes
# it with this one's (it did: an old kernel with a new sh.byte)
images=$(echo "$version" | tr -c 'A-Za-z0-9.\n-' '_')
rm -rf "$out"
mkdir -p "$out/images/$images" "$out/v86-pkg"
tar -xzf "$cache/v86-$V86.tgz" -C "$out/v86-pkg"
cp "$out/v86-pkg/package/build/libv86.js" "$out/v86-pkg/package/build/v86.wasm" "$out/"
cp "$out/v86-pkg/package/LICENSE" "$out/LICENSE-v86.txt"
rm -rf "$out/v86-pkg"
cp "$cache/seabios.bin" "$cache/vgabios.bin" "$out/"
touch "$out/.nojekyll"          # GitHub Pages: serve the files as they are

# the images: NAME-START-END.EXT.zst, as v86 asks for them
split_image() {   # FILE NAME EXT
    size=$(stat -c %s "$1")
    i=0
    while [ $((i * CHUNK)) -lt "$size" ]; do
        start=$((i * CHUNK))
        dd if="$1" bs=$CHUNK skip=$i count=1 status=none |
            zstd -q -19 -o "$out/images/$images/$2-$start-$((start + CHUNK)).$3.zst"
        i=$((i + 1))
    done
    echo "$size"
}
iso_size=$(split_image "$rel/mynos.iso" mynos iso)
disk_size=$(split_image "$rel/disk-clean.img" disk img)

sed -e "s|@VERSION@|$version|g" -e "s|@V86@|$V86|g" -e "s|@BIOS_COMMIT@|$BIOS_COMMIT|g" \
    -e "s|@CHUNK@|$CHUNK|g" -e "s|@ISO_SIZE@|$iso_size|g" -e "s|@DISK_SIZE@|$disk_size|g" \
    -e "s|@IMAGES@|$images|g" \
    tools/web/index.html > "$out/index.html"
echo "make-web.sh: $out ($(du -sh "$out" | cut -f1), $(ls "$out/images/$images" | wc -l) chunks), MyNOS $version"
