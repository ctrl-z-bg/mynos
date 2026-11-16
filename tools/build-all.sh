#!/bin/sh
# Build the whole system and the test files in a build container.
#
# Usage: tools/build-all.sh [dev|legacy]     (default: dev)
#
# Produces:
#   mynos-core/kernel/kernel.elf     the kernel
#   mynos-lib/lib/libmynos.a         user-space library
#   services/...                     registry, keyboardd, seriald, memrofsd
#   mynos-runtime/ocamlrun           the OCaml 5.5 runtime (dev), or
#   mynos-byterun/src/ocamlrun       the OCaml 3.06 runtime (legacy)
#   tests/hello/hello.byte           OCaml test program
#   tests/effects/effects.byte       effect handlers test (OCaml 5 only)
#   tests/domains/domains.byte       domains test: threads, futexes (OCaml 5 only)
#   mynos-lib/ocaml/mynos.cma        the Mynos OCaml library (dev only)
#   tests/mynos-ocaml/mynos_test.byte  test of the Mynos library (dev only)
#   tests/console/echo.byte          reads lines from the console (dev only)
#   tests/files/ramdisk.dsk          RAM disk with init.byte, a file I/O test (dev only)
#   tests/spawn/ramdisk.dsk          RAM disk with the runtime and a spawn test (dev only)
#   system/ramdisk.dsk               the system RAM disk: init, consoled, the shell
#                                    (the OCaml toplevel), programs (dev only)
#   tests/abi/abi                    system call checks
#   tests/ramdisk/ramdisk.dsk        RAM disk image for memrofs
set -eu

name=${1:-dev}
root=$(cd "$(dirname "$0")/.." && pwd)

exec "$root/tools/in-container.sh" "$name" sh -euc '
mkdir -p mynos-lib/lib
make -C mynos-core/kernel
make -C mynos-lib
make -C services
make -C ${MYNOS_RUNTIME:-mynos-byterun/src}
make -C tests/abi
if [ "${MYNOS_RUNTIME:-}" = mynos-runtime ]; then
  make -C mynos-lib/ocaml
  (cd tests/mynos-ocaml && ocamlc -use-prims ../../mynos-runtime/primitives \
     -I ../../mynos-lib/ocaml mynos.cma -o mynos_test.byte mynos_test.ml)
  (cd tests/console && ocamlc -o echo.byte echo.ml)
  (cd tests/files && ocamlc -o init.byte files.ml && cp ../ramdisk/AUTOEXEC.BAT . &&
     ../../services/fs/memrofs/tool/createDisk init.byte AUTOEXEC.BAT >/dev/null)
  make -C tests/spawn
fi
(cd tests/hello && ocamlc -o hello.byte hello.ml)
case $(ocamlc -version) in
  5.*) (cd tests/effects && ocamlc -o effects.byte effects.ml)
       (cd tests/domains && ocamlc -o domains.byte domains.ml) ;;
esac
(cd tests/ramdisk && ../../services/fs/memrofs/tool/createDisk AUTOEXEC.BAT)
if [ "${MYNOS_RUNTIME:-}" = mynos-runtime ]; then
  make -C init
  make -C services/tmpfs
  make -C shell
  make -C system
fi
'
