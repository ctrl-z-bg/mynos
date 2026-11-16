# Test of Mynos.spawn: a RAM disk with the runtime, init.byte (spawn.ml)
# and child.byte. Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml

all: ramdisk.dsk

init.byte: spawn.ml
	$(OCAMLC) mynos.cma -o $@ spawn.ml

child.byte: child.ml
	$(OCAMLC) mynos.cma -o $@ child.ml

# the runtime without its debugging information: 0.5 MB instead of 1.7
ocamlrun: ../../mynos-runtime/ocamlrun
	strip -o $@ $<

ramdisk.dsk: init.byte child.byte ocamlrun
	../../services/fs/memrofs/tool/createDisk init.byte child.byte ocamlrun >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
