#!/bin/sh
# The MSX's modules on the host (packages/msx, packages/retro's PSG), in
# the dev container, as bytecode: tests/msx/msxtest.ml (a minute or so).
# emu/1's own test, in MyNOS, is tests/emu (run-tests.sh's sec_emu).
#   tests/msx/run.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
exec "$root/tools/in-container.sh" dev sh -euc '
cd tests/msx
rm -rf _t && mkdir _t
cp ../../packages/retro/z80.mli ../../packages/retro/z80.ml ../../packages/retro/png.ml \
   ../../packages/retro/ay8910.mli ../../packages/retro/ay8910.ml \
   ../../packages/msx/vdp.mli ../../packages/msx/vdp.ml \
   ../../packages/msx/cartridge.mli ../../packages/msx/cartridge.ml \
   ../../packages/msx/msx_keys.mli ../../packages/msx/msx_keys.ml \
   ../../packages/msx/msx.mli ../../packages/msx/msx.ml msxtest.ml _t/
cd _t
# emu_proto without MyNOS: its type of memory spaces only (the rest needs Ipc)
echo "type space = Cpu | Ram | Vram | Rom" > emu_proto.mli
cp emu_proto.mli emu_proto.ml
ocamlc z80.mli z80.ml png.ml emu_proto.mli emu_proto.ml ay8910.mli ay8910.ml vdp.mli vdp.ml \
  cartridge.mli cartridge.ml msx_keys.mli msx_keys.ml msx.mli msx.ml msxtest.ml -o msxtest.byte
ocamlrun msxtest.byte ../../..
'
