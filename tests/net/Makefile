# Network test: a RAM disk with the runtime, netd and init.byte
# (net_test.ml). Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives

all: ramdisk.dsk

init.byte: net_test.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ net_test.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	strip -o $@ $<

netd: ../../services/net/netd
	strip -o $@ $<

ramdisk.dsk: init.byte ocamlrun netd
	../../services/fs/memrofs/tool/createDisk init.byte ocamlrun netd >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun netd ramdisk.dsk
