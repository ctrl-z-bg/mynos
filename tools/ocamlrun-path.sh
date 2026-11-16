#!/bin/sh
# Print the path of the OCaml runtime built by tools/build-all.sh:
# mynos-runtime/ocamlrun (OCaml 5.5, dev) or mynos-byterun/src/ocamlrun
# (OCaml 3.06, legacy). tools/clean-all.sh removes both.
root=$(cd "$(dirname "$0")/.." && pwd)
for f in mynos-runtime/ocamlrun mynos-byterun/src/ocamlrun; do
    [ -f "$root/$f" ] && { echo "$root/$f"; exit 0; }
done
echo "no ocamlrun built: run tools/build-all.sh" >&2
exit 1
