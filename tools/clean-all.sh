#!/bin/sh
# Remove all build outputs (a build from scratch: tools/clean-all.sh, then
# tools/build-all.sh).
#
# Usage: tools/clean-all.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

exec "$root/tools/in-container.sh" dev sh -euc '
make -C mynos-core/kernel clean
make -C mynos-lib clean
make -C services clean
make -C services/fs/memrofs/tool clean
make -C mynos-runtime clean
make -C third_party/num clean
make -C tests/abi clean
make -C tests/fpu clean
make -C tests/stdio clean
make -C tests/stress clean
make -C mynos-lib/ocaml clean
rm -f tests/*/*.byte tests/*/*.cm[io] tests/*/ramdisk.dsk tests/files/AUTOEXEC.BAT \
  tests/spawn/ocamlrun
make -C init clean
make -C third_party/kilo clean
make -C third_party/notty clean
make -C editor clean
make -C sh clean
make -C services/tmpfs clean
make -C services/ata clean
make -C tests/storage clean
make -C services/fatfs clean
make -C tests/fat clean
make -C services/net clean
make -C tests/net clean
make -C httpd clean
make -C trace clean
make -C fetch clean
make -C log clean
make -C services/llm clean
make -C llm clean
make -C agent clean
make -C services/display clean
make -C gui clean
make -C graphics clean
make -C pkg clean
make -C shell clean
make -C system clean
' >/dev/null
