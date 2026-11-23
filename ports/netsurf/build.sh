#!/bin/sh
# NetSurf 3.11 for MyNOS (ports/netsurf, mynos-1g0): its sources fetched
# (version and hashes fixed here), patched, built in the mynos-netsurf
# container (static, musl, i386) and linked with libmynos. The work is in
# build/netsurf; the result in build/netsurf/stage: the program (nsfb),
# its resources (res) and a home with its Choices (home).
# Needs libmynos built first (tools/build-all.sh). FRESH=1 starts again
# from the tarballs.
set -eu
cd "$(dirname "$0")/../.."
w=build/netsurf
ns=netsurf-all-3.11
ns_url=https://download.netsurf-browser.org/netsurf/releases/source-full/$ns.tar.gz
ns_sha=4dea880ff3c2f698bfd62c982b259340f9abcd7f67e6c8eb2b32c61f71644b7b
z=zlib-1.3.1
z_url=https://github.com/madler/zlib/releases/download/v1.3.1/$z.tar.gz
z_sha=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

mkdir -p $w
[ -n "${FRESH:-}" ] && rm -rf $w/$ns $w/$z $w/stage

fetch() {   # url file sha256
    [ -f "$w/$2" ] || { curl -fsSL -o "$w/$2.part" "$1" && mv "$w/$2.part" "$w/$2"; }
    echo "$3  $w/$2" | sha256sum -c --quiet
}
fetch $ns_url $ns.tar.gz $ns_sha
fetch $z_url $z.tar.gz $z_sha

if [ ! -d $w/$ns ]; then
    tar xzf $w/$ns.tar.gz -C $w
    for p in ports/netsurf/patches/*.patch; do patch -s -p1 -d $w/$ns < "$p"; done
fi
[ -d $w/$z ] || tar xzf $w/$z.tar.gz -C $w
# MyNOS's own files, new or changed since the tree was made
copy() { cmp -s "ports/netsurf/$1" "$w/$ns/$2" || cp "ports/netsurf/$1" "$w/$ns/$2"; }
copy mynos-surface.c libnsfb/src/surface/mynos.c
copy mynos-http.c netsurf/content/fetchers/mynos_http.c

podman image exists mynos-netsurf || tools/containers/build-image.sh netsurf
tools/in-container.sh netsurf sh ports/netsurf/inside.sh
ls -l $w/stage/nsfb
