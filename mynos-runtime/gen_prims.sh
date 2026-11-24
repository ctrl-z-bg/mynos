#!/bin/sh
# Generate the runtime's primitive list and table with the MyNOS primitives
# added to the upstream ones, without touching the OCaml sources.
#
# Usage: gen_prims.sh <upstream dir> <stubs.c...>
#   writes ./primitives (for ocamlc -use-prims) and ./prims.c
# The upstream dir holds the runtime's own primitives and generated prims.c
# (the dev container keeps them in /opt/ocaml-runtime-musl).
set -eu
export LC_ALL=C

up=$1; shift

# The list: upstream, unchanged, then ours (without any upstream has). A
# bytecode file names the primitives it uses (its PRIM section) and the
# runtime looks each name up in this table at load time: the order does
# not matter, the names do.
{ cat "$up/primitives"
  sed -n -e 's/^CAMLprim value \([a-z][a-z0-9_]*\).*$/\1/p' "$@" | sort -u |
    { grep -vxF -f "$up/primitives" || true; }
} > primitives

{
  # upstream includes and declarations
  sed -n '/^const c_primitive caml_builtin_cprim\[\]/q;p' "$up/prims.c"
  # declarations of ours
  sed -n -e '/^CAMLprim value .*)/p' -e '/^CAMLprim value [^)]*$/,/)/p' "$@" |
    sed -e 's/^CAMLprim /CAMLextern /' -e 's/).*$/);/'
  echo
  echo 'const c_primitive caml_builtin_cprim[] = {'
  sed -e 's/.*/  (c_primitive) &,/' primitives
  echo '  0 };'
  echo
  echo 'const char * const caml_names_of_builtin_cprim[] = {'
  sed -e 's/.*/  "&",/' primitives
  echo '  0 };'
  echo
  # upstream trailer (bytecode loading mode, standard library path)
  sed -n '/caml_byte_program_mode/,$p' "$up/prims.c"
} > prims.c
