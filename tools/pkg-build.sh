#!/bin/sh
# Build the packages of packages/*/spec into OUTDIR (mynos-vcd,
# doc/decisions/packages.md): OUTDIR/index.json and
# OUTDIR/packages/NAME-VERSION.tar, the layout of the packages'
# repository (ctrl-z-bg/mynos-packages), which pkg reads.
#
# Usage: tools/pkg-build.sh OUTDIR     (in the dev container:
#        tools/build-all.sh builds them into tmp/packages)
#
# A package's archive holds package.json (name, version, program,
# sources in the order to compile them, libraries), the program as
# bytecode, built against this tree's runtime and libraries, its sources
# in src/, and its licence. The archives are made the same way each time
# (names sorted, owner 0, date 0), so a package that did not change keeps
# its hash.
set -eu
out=${1:?usage: tools/pkg-build.sh OUTDIR}
cd "$(dirname "$0")/.."
root=$(pwd)
mkdir -p "$out/packages"
out=$(cd "$out" && pwd)
mynos=$(cat VERSION 2>/dev/null || echo unknown)
stage=$root/tmp/pkg-stage

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
jlist() {
    sep=
    for x in $1; do printf '%s"%s"' "$sep" "$(json "$x")"; sep=', '; done
}

entries=
for spec in packages/*/spec; do
    NAME= VERSION= DESCRIPTION= LICENSE= LIBRARIES= SRC= SOURCES= EXTRA=
    . "./$spec"
    d=$stage/$NAME
    rm -rf "$d"; mkdir -p "$d/src"
    for f in $SOURCES; do cp "$SRC/$f" "$d/src/"; done
    for f in $EXTRA; do cp "$f" "$d/"; done
    incs= cmas=
    for l in $LIBRARIES; do
        case $l in
            graphics) incs="$incs -I $root/graphics"; cmas="$cmas graphics.cma" ;;
            unix) incs="$incs -I +unix"; cmas="$cmas unix.cma" ;;
            threads) incs="$incs -I +unix -I +threads"; cmas="$cmas unix.cma threads.cma" ;;
            str) incs="$incs -I +str"; cmas="$cmas str.cma" ;;
            num|nums) incs="$incs -I $root/third_party/num"; cmas="$cmas nums.cma" ;;
            *) echo "pkg-build: $NAME: unknown library $l" >&2; exit 1 ;;
        esac
    done
    # in src, as pkg compiles them: the package's modules come first
    (cd "$d/src" &&
     ocamlc -use-prims "$root/mynos-runtime/primitives" -I "$root/mynos-lib/ocaml" \
         $incs -noautolink mynos.cma $cmas -o "../$NAME.byte" $SOURCES &&
     rm -f ./*.cm[io])
    cat > "$d/package.json" <<JSON
{
  "name": "$(json "$NAME")",
  "version": "$(json "$VERSION")",
  "description": "$(json "$DESCRIPTION")",
  "license": "$(json "$LICENSE")",
  "program": "$(json "$NAME").byte",
  "sources": [$(jlist "$SOURCES")],
  "libraries": [$(jlist "$LIBRARIES")],
  "mynos": "$(json "$mynos")"
}
JSON
    tar=packages/$NAME-$VERSION.tar
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime=@0 -cf "$out/$tar" -C "$d" .
    size=$(wc -c < "$out/$tar" | tr -d ' ')
    hash=$(b2sum -l 256 "$out/$tar" | cut -d' ' -f1)
    entry=$(printf '    {"name": "%s", "version": "%s", "description": "%s",\n     "license": "%s", "archive": "%s", "size": %s,\n     "blake2b-256": "%s", "mynos": "%s"}' \
        "$(json "$NAME")" "$(json "$VERSION")" "$(json "$DESCRIPTION")" \
        "$(json "$LICENSE")" "$tar" "$size" "$hash" "$(json "$mynos")")
    entries=${entries:+$entries,
}$entry
    echo "pkg-build: $tar, $size bytes"
done
rm -rf "$stage"
printf '{\n  "format": 1,\n  "packages": [\n%s\n  ]\n}\n' "$entries" > "$out/index.json"
