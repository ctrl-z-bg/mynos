# emu/1 test (doc/decisions/retro-emulators.md, section 8): the package
# zxspectrum's program, built from its spec's sources, and emutest.byte,
# which drives it through its service; a disk with both, the ROM and a
# tape, made with mkfs.fat and mtools. Built in the dev container
# (tools/build-all.sh); run by tools/run-tests.sh (sec_emu).

# (run in a folder below this one)
OCAMLC = ocamlc -use-prims ../../../mynos-runtime/primitives -I ../../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives
SPEC = ../../packages/zxspectrum/spec
ZX = $(shell . $(SPEC); for f in $$SOURCES; do echo ../../packages/zxspectrum/$$f; done)

all: emu.img

zxspectrum.byte: $(ZX) $(SPEC) $(MYNOS)
	rm -rf zx && mkdir zx && cp $(ZX) zx/
	cd zx && $(OCAMLC) -I +unix -I +threads -noautolink mynos.cma unix.cma threads.cma \
	  -o ../$@ $(notdir $(ZX))
	rm -rf zx

emutest.byte: emutest.ml ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml $(MYNOS)
	rm -rf et && mkdir et && cp ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml emutest.ml et/
	cd et && $(OCAMLC) mynos.cma -o ../$@ emu_proto.mli emu_proto.ml emutest.ml
	rm -rf et

emu.img: zxspectrum.byte emutest.byte ../../packages/zxspectrum/48.rom ../../third_party/glazx/glazx48.tap
	rm -f $@
	mkfs.fat -C -F 32 $@ 65536 >/dev/null
	mmd -i $@ ::/zx
	mcopy -i $@ zxspectrum.byte emutest.byte ../../packages/zxspectrum/48.rom \
	  ../../third_party/glazx/glazx48.tap ::/zx/

clean:
	rm -rf zx et zxspectrum.byte emutest.byte emu.img
