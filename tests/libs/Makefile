# the build host's strip, or the target's (AArch64: aarch64-linux-gnu-strip)
STRIP ?= strip
# Libraries test: a RAM disk with the runtime, tmpfs and init.byte
# (libs.ml: Str, Num, the CPU time, the user id, O_EXCL). Built in the dev
# container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml \
	-I +unix -I +str -I ../../third_party/num -noautolink
LIBS = ../../mynos-lib/ocaml/mynos.cma ../../third_party/num/nums.cma \
	../../mynos-runtime/primitives

all: ramdisk.dsk

init.byte: libs.ml $(LIBS)
	$(OCAMLC) mynos.cma unix.cma str.cma nums.cma -o $@ libs.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	$(STRIP) -o $@ $<

ramdisk.dsk: init.byte ocamlrun ../../services/tmpfs/tmpfs.byte
	../../services/fs/memrofs/tool/createDisk init.byte ocamlrun \
	  ../../services/tmpfs/tmpfs.byte >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
