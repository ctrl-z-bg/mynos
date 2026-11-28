#!/bin/sh
# A native OCaml program for MyNOS (doc/decisions/ocaml-native.md): the
# cross ocamlopt of the dev-aarch64 container (MYNOS_OCAMLOPT), the Mynos
# library (mynos-lib/ocaml/mynos.cmxa) and its stubs
# (mynos-runtime/libmynosrt.a), linked as MyNOS's C programs (static, at
# 0x40000000, libmynos's stdio). Run in the container, from the tree:
#   tools/ocamlopt-mynos.sh [ocamlopt's options and files] -o PROG
# e.g. tools/ocamlopt-mynos.sh -I +unix unix.cmxa mynos.cmxa prog.ml -o prog
# OCaml's native runtime (libasmrun) is named before libmynos, so that
# what it takes from the C library comes from libmynos where libmynos
# has it, as for ocamlrun.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
: "${MYNOS_OCAMLOPT:?no cross ocamlopt here: run in the dev-aarch64 container}"
ldflags=${MYNOS_LDFLAGS:-"-static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code -Wl,--build-id=none"}
ldflags="$ldflags -Wl,-u,__stdio_read -Wl,-u,__stdio_write -Wl,-u,__stdout_write -Wl,-u,__stdio_seek -Wl,-u,__stdio_close"
exec "$MYNOS_OCAMLOPT" -I "$root/mynos-lib/ocaml" "$@" \
    -ccopt "$ldflags" \
    -cclib "-lasmrun -L$root/mynos-runtime -lmynosrt -L$root/mynos-lib/lib -lmynos"
