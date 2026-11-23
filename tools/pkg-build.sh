#!/bin/sh
# Build the packages of packages/*/spec into OUTDIR (mynos-vcd,
# doc/decisions/packages.md): OUTDIR/index.json and
# OUTDIR/packages/NAME-VERSION-HASH.tar (HASH: the first 12 hexadecimal
# digits of its BLAKE2b-256: a new archive is a new name, which no cache
# of raw.githubusercontent.com has served before; tools/pkg-publish.sh
# keeps the previous index's archives, so that a cached index finds its
# own), the layout of the packages'
# repository (ctrl-z-bg/mynos-packages), which pkg reads.
#
# Usage: tools/pkg-build.sh OUTDIR     (in the dev container:
#        tools/build-all.sh builds them into tmp/packages)
#
# A spec (shell assignments) names: NAME, VERSION, DESCRIPTION, LICENSE;
# LIBRARIES (graphics unix threads str num); SRC, the directory of the
# sources, and SOURCES, in the order to compile them: its program,
# NAME.byte (without SOURCES: a package of data); COMMANDS, if the
# program is several commands: pkg makes each a script that runs the
# program, which tells them apart by the script's name (package utils);
# DEPENDS, the packages it needs; RUN,
# the window the Packages window starts, and its arguments; DOC, its
# documentation (a file, kept as README.md); EXTRA, other files (its
# licence, data).
#
# OUTDIR/docs/NAME.md is a package's DOC, for the repository's page; a
# package with pictures (SRC/images, made by tools/pkg-shots.sh) has a
# folder instead, OUTDIR/docs/NAME/README.md and its images/, which the
# README names as images/FILE.png. The archive has the text only (MyNOS's
# Markdown viewer leaves pictures out).
#
# A package's archive holds package.json (name, version, programs, the
# sources of each in the order to compile them, libraries, depends, run,
# doc), the programs as bytecode, built against this tree's runtime and
# libraries, their sources in src/, the documentation, the extra files.
# "program" and "sources" repeat the first program's, for the pkg of
# 2026-11-20, which knew no other fields. The archives are made the same way each time
# (names sorted, owner 0, date 0), so a package that did not change keeps
# its hash.
set -eu
out=${1:?usage: tools/pkg-build.sh OUTDIR}
cd "$(dirname "$0")/.."
root=$(pwd)
# OUTDIR/packages holds only the archives of the specs: a package removed
# or renamed leaves no archive behind
mkdir -p "$out/packages" "$out/docs"
# the previous archives, aside: a package built again the same, but on
# another MyNOS (its "mynos" field, the commit), keeps its old archive, so
# that its hash does not change and pkg upgrade (PKG=local) leaves it
stage=$root/tmp/pkg-stage
prev=$root/tmp/pkg-prev
rm -rf "$prev"; mkdir -p "$prev"
for f in "$out"/packages/*.tar; do [ -f "$f" ] && mv "$f" "$prev/"; done
rm -rf "$out"/docs/*
out=$(cd "$out" && pwd)
mynos=$(cat VERSION 2>/dev/null || echo unknown)

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
jlist() {
    sep=
    for x in $1; do printf '%s"%s"' "$sep" "$(json "$x")"; sep=', '; done
}

entries=
for spec in packages/*/spec; do
    NAME= VERSION= DESCRIPTION= LICENSE= LIBRARIES= SRC= SOURCES= EXTRA=
    COMMANDS= DEPENDS= RUN= DOC=
    . "./$spec"
    d=$stage/$NAME
    rm -rf "$d"; mkdir -p "$d/src"
    # a source may be another package's (../view/png.ml): kept by its name
    for f in $SOURCES; do cp "$SRC/$f" "$d/src/"; done
    names_only=$(for f in $SOURCES; do basename "$f"; done | tr '\n' ' ')
    for f in $EXTRA; do cp -r "$f" "$d/"; done
    # its documentation: in the archive, and beside the index (the
    # repository's page links it)
    if [ -n "$DOC" ]; then
        cp "$DOC" "$d/README.md"
        if [ -d "$SRC/images" ]; then
            mkdir -p "$out/docs/$NAME/images"
            cp "$DOC" "$out/docs/$NAME/README.md"
            cp "$SRC"/images/*.png "$out/docs/$NAME/images/"
        else
            cp "$DOC" "$out/docs/$NAME.md"
        fi
    fi
    [ -z "$SOURCES" ] && rmdir "$d/src"
    # the programs: NAME:SOURCES... (one, today)
    progs=
    [ -n "$SOURCES" ] && progs="$NAME:$(echo $names_only | tr ' ' ,)"
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
    pjson= names=
    for ps in $progs; do
        p=${ps%%:*} srcs=$(echo "${ps#*:}" | tr , ' ')
        (cd "$d/src" &&
         ocamlc -use-prims "$root/mynos-runtime/primitives" -I "$root/mynos-lib/ocaml" \
             $incs -noautolink mynos.cma $cmas -o "../$p.byte" $srcs &&
         rm -f ./*.cm[io])
        pjson=${pjson:+$pjson,
}"    {\"program\": \"$(json "$p").byte\", \"sources\": [$(jlist "$srcs")]}"
        names="$names $p"
    done
    run=
    [ -n "$RUN" ] && run=$(set -- $RUN; first=$1; shift; jlist "$first.byte $*")
    cat > "$d/package.json" <<JSON
{
  "name": "$(json "$NAME")",
  "version": "$(json "$VERSION")",
  "description": "$(json "$DESCRIPTION")",
  "license": "$(json "$LICENSE")",
  "programs": [
$pjson
  ],$( [ -n "$SOURCES" ] && printf '\n  "program": "%s.byte",\n  "sources": [%s],' "$(json "$NAME")" "$(jlist "$names_only")" )
  "libraries": [$(jlist "$LIBRARIES")],
  "commands": [$(jlist "$COMMANDS")],
  "depends": [$(jlist "$DEPENDS")],
  "run": [$run],$( [ -n "$DOC" ] && printf '\n  "doc": "README.md",' )
  "mynos": "$(json "$mynos")"
}
JSON
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime=@0 -cf "$out/packages/.building.tar" -C "$d" .
    # the same as the previous archive of this version but for its
    # "mynos": that archive, and its "mynos"
    pkg_mynos=$mynos
    for old in "$prev/$NAME-$VERSION"-*.tar; do
        [ -f "$old" ] || continue
        o=$stage/.old
        rm -rf "$o"; mkdir -p "$o"; tar -xf "$old" -C "$o"
        same=yes
        [ "$(cd "$o" && find . -type f | sort)" = "$(cd "$d" && find . -type f | sort)" ] || same=
        if [ -n "$same" ]; then
            for f in $(cd "$d" && find . -type f ! -name package.json); do
                cmp -s "$o/$f" "$d/$f" || { same=; break; }
            done
        fi
        [ -n "$same" ] &&
            [ "$(sed '/"mynos":/d' "$o/package.json")" != "$(sed '/"mynos":/d' "$d/package.json")" ] && same=
        if [ -n "$same" ]; then
            cp "$old" "$out/packages/.building.tar"
            pkg_mynos=$(sed -n 's/^ *"mynos": "\(.*\)"$/\1/p' "$o/package.json")
        fi
        rm -rf "$o"
    done
    size=$(wc -c < "$out/packages/.building.tar" | tr -d ' ')
    hash=$(b2sum -l 256 "$out/packages/.building.tar" | cut -d' ' -f1)
    tar=packages/$NAME-$VERSION-$(printf '%s' "$hash" | cut -c1-12).tar
    mv "$out/packages/.building.tar" "$out/$tar"
    entry=$(printf '    {"name": "%s", "version": "%s", "description": "%s",\n     "license": "%s", "archive": "%s", "size": %s,\n     "blake2b-256": "%s", "mynos": "%s",\n     "depends": [%s], "programs": [%s]}' \
        "$(json "$NAME")" "$(json "$VERSION")" "$(json "$DESCRIPTION")" \
        "$(json "$LICENSE")" "$tar" "$size" "$hash" "$(json "$pkg_mynos")" \
        "$(jlist "$DEPENDS")" "$(jlist "${COMMANDS:-$names}")")
    entries=${entries:+$entries,
}$entry
    echo "pkg-build: $tar, $size bytes"
done
rm -rf "$stage" "$prev"
printf '{\n  "format": 1,\n  "packages": [\n%s\n  ]\n}\n' "$entries" > "$out/index.json"
