#!/bin/sh
# The Z80's tests (packages/retro/z80.ml), in the dev container, as
# bytecode (no native compiler there): FUSE's tests (seconds), the
# disassembler's, then zexdoc and zexall (about 25 minutes each, at the
# same time). tests/z80/README.md says where they come from.
#   tests/z80/run.sh          FUSE's and the disassembler's
#   tests/z80/run.sh zex      zexdoc and zexall too
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
exec "$root/tools/in-container.sh" dev sh -euc '
cd tests/z80
rm -rf _t && mkdir _t
cp ../../packages/retro/z80.mli ../../packages/retro/z80.ml \
   ../../packages/retro/z80_disasm.mli ../../packages/retro/z80_disasm.ml \
   fuse.ml disasm.ml cpm.ml _t/
cd _t
ocamlc z80.mli z80.ml fuse.ml -o fuse.byte
ocamlc z80.mli z80.ml z80_disasm.mli z80_disasm.ml disasm.ml -o disasm.byte
ocamlc -I +unix unix.cma z80.mli z80.ml cpm.ml -o cpm.byte
ocamlrun fuse.byte ../tests.in ../tests.expected | tail -1
ocamlrun disasm.byte | tail -1
if [ "${1:-}" = zex ]; then
  ocamlrun cpm.byte ../zexdoc.com > zexdoc.out 2>&1 &
  ocamlrun cpm.byte ../zexall.com > zexall.out 2>&1
  wait
  for f in zexdoc zexall; do echo "$f: $(grep -c "  OK" $f.out) OK, $(grep -c ERROR $f.out) ERROR; $(tail -1 $f.out)"; done
fi
' sh "$@"
