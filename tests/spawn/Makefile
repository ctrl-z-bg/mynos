# the build host's strip, or the target's (AArch64: aarch64-linux-gnu-strip)
STRIP ?= strip
# Test of Mynos.spawn: a RAM disk with the runtime, init.byte (spawn.ml)
# and child.byte. Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml

all: ramdisk.dsk

MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives

init.byte: spawn.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ spawn.ml

child.byte: child.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ child.ml

# the runtime without its debugging information: 0.5 MB instead of 1.7
ocamlrun: ../../mynos-runtime/ocamlrun
	$(STRIP) -o $@ $<

ramdisk.dsk: init.byte child.byte ocamlrun
	../../services/fs/memrofs/tool/createDisk init.byte child.byte ocamlrun >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
