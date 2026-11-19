#!/bin/sh
# Compile the manual's examples (doc/manual/examples, one directory per
# chapter), so that a change in the libraries that breaks one of them
# breaks the build. The programs go to tmp/examples (not kept by git).
# Run inside the dev container (tools/build-all.sh calls it).
set -e
cd "$(dirname "$0")/.."
out=tmp/examples
mkdir -p "$out"
prims=mynos-runtime/primitives
for f in doc/manual/examples/*/*.ml; do
    name=$(basename "$f" .ml)
    extra=
    case "$name" in othreads|keys) extra="-I +unix -I +threads unix.cma threads.cma -noautolink" ;; esac
    ocamlc -use-prims $prims -I mynos-lib/ocaml -I "$(dirname "$f")" mynos.cma $extra \
        -o "$out/$name.byte" "$f"
done
for f in doc/manual/examples/*/*.c; do
    name=$(basename "$f" .c)
    $MYNOS_CC -Wall -O2 -Imynos-lib/include "$f" -o "$out/$name" \
        -Lmynos-lib/lib -lmynos $MYNOS_LDFLAGS \
        -Wl,-u,__stdio_read -Wl,-u,__stdio_write -Wl,-u,__stdout_write \
        -Wl,-u,__stdio_seek -Wl,-u,__stdio_close
done
rm -f doc/manual/examples/*/*.cm[io]
echo "examples: $(ls $out | wc -l) programs"
