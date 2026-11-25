# the build host's strip, or the target's (AArch64: aarch64-linux-gnu-strip)
STRIP ?= strip
# Storage test: a RAM disk with the runtime, the ATA driver and init.byte
# (storage.ml). Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives

all: ramdisk.dsk

init.byte: storage.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ storage.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	$(STRIP) -o $@ $<

ramdisk.dsk: init.byte ocamlrun ../../services/ata/ata.byte
	../../services/fs/memrofs/tool/createDisk init.byte ocamlrun ../../services/ata/ata.byte >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
