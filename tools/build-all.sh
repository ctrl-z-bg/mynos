#!/bin/sh
# Build the whole system and the test files in a build container.
#
# Usage: tools/build-all.sh
#
# Produces:
#   mynos-core/kernel/kernel.elf     the kernel
#   mynos-lib/lib/libmynos.a         user-space library
#   services/...                     registry, keyboardd, seriald, memrofsd
#   mynos-runtime/ocamlrun           the OCaml 5.5 runtime
#   tests/hello/hello.byte           OCaml test program
#   tests/effects/effects.byte       effect handlers test
#   tests/domains/domains.byte       domains test: threads, futexes
#   mynos-lib/ocaml/mynos.cma        the Mynos OCaml library
#   tests/mynos-ocaml/mynos_test.byte  test of the Mynos library
#   tests/console/echo.byte          reads lines from the console
#   tests/files/ramdisk.dsk          RAM disk with init.byte, a file I/O test
#   tests/spawn/ramdisk.dsk          RAM disk with the runtime and a spawn test
#   tests/storage/ramdisk.dsk        RAM disk with the ATA driver and a disk test
#   tests/fat/ramdisk.dsk, fat*.img  fatfs test: RAM disk, FAT16 and FAT32 images
#   system/ramdisk.dsk               the system RAM disk: init, consoled, the shell
#                                    (the OCaml toplevel), programs
#   tests/abi/abi                    system call checks
#   tests/stress/stress, ramdisk.dsk kernel stress test
#   tests/ramdisk/ramdisk.dsk        RAM disk image for memrofs
#   fetch/fetch.byte                 HTTP and HTTPS from the command line
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

exec "$root/tools/in-container.sh" dev sh -euc '
mkdir -p mynos-lib/lib
make -C mynos-core/kernel
make -C mynos-lib
make -C services
make -C mynos-runtime
make -C tests/abi
make -C tests/stress
make -C mynos-lib/ocaml
(cd tests/mynos-ocaml && ocamlc -use-prims ../../mynos-runtime/primitives \
   -I ../../mynos-lib/ocaml mynos.cma -o mynos_test.byte mynos_test.ml)
(cd tests/console && ocamlc -o echo.byte echo.ml)
(cd tests/files && ocamlc -o init.byte files.ml && cp ../ramdisk/AUTOEXEC.BAT . &&
   ../../services/fs/memrofs/tool/createDisk init.byte AUTOEXEC.BAT >/dev/null)
make -C tests/spawn
(cd tests/hello && ocamlc -o hello.byte hello.ml)
(cd tests/greeter && ocamlc -use-prims ../../mynos-runtime/primitives \
   -I ../../mynos-lib/ocaml mynos.cma -o greeter.byte greeter.ml)
(cd tests/effects && ocamlc -o effects.byte effects.ml)
(cd tests/domains && ocamlc -o domains.byte domains.ml)
make -C tests/threads
(cd tests/ramdisk && ../../services/fs/memrofs/tool/createDisk AUTOEXEC.BAT)
make -C third_party/kilo
make -C third_party/notty
make -C editor
make -C sh
make -C init
make -C services/tmpfs
make -C services/ata
make -C services/fatfs
make -C tests/storage
make -C tests/fat
make -C services/net
make -C httpd
make -C trace
make -C fetch
make -C services/llm
make -C llm
make -C agent
make -C services/display
make -C gui
make -C tests/net
make -C shell
make -C system
'
