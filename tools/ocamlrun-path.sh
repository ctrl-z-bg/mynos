#!/bin/sh
# Print the path of the OCaml runtime built by tools/build-all.sh
# (mynos-runtime/ocamlrun, OCaml 5.5).
root=$(cd "$(dirname "$0")/.." && pwd)
f=mynos-runtime/ocamlrun
[ -f "$root/$f" ] && { echo "$root/$f"; exit 0; }
echo "no ocamlrun built: run tools/build-all.sh" >&2
exit 1
