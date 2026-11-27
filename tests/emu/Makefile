# emu/1 test (doc/decisions/retro-emulators.md, section 8): the packages
# zxspectrum's and camlboy's programs, built from their specs' sources,
# and emutest.byte, emutest_gb.byte, which drive them through emu/1; a disk with both, the ROM and a
# tape, made with mkfs.fat and mtools. Built in the dev container
# (tools/build-all.sh); run by tools/run-tests.sh (sec_emu).

# (run in a folder below this one)
OCAMLC = ocamlc -use-prims ../../../mynos-runtime/primitives -I ../../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives
SPEC = ../../packages/zxspectrum/spec
ZX = $(shell . $(SPEC); for f in $$SOURCES; do echo ../../packages/zxspectrum/$$f; done)

CB_SPEC = ../../packages/camlboy/spec
CB = $(shell . $(CB_SPEC); for f in $$SOURCES; do echo ../../third_party/camlboy/src/$$f; done)

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

camlboy.byte: $(CB) $(CB_SPEC) $(MYNOS)
	rm -rf cb && mkdir cb && cp $(CB) cb/
	cd cb && $(OCAMLC) -I +unix -I +threads -noautolink mynos.cma unix.cma threads.cma \
	  -o ../$@ $(notdir $(CB))
	rm -rf cb

emutest_gb.byte: emutest_gb.ml ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml $(MYNOS)
	rm -rf eg && mkdir eg && cp ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml emutest_gb.ml eg/
	cd eg && $(OCAMLC) mynos.cma -o ../$@ emu_proto.mli emu_proto.ml emutest_gb.ml
	rm -rf eg

emu.img: zxspectrum.byte emutest.byte camlboy.byte emutest_gb.byte ../../packages/zxspectrum/48.rom \
  ../../third_party/glazx/glazx48.tap ../../third_party/tobutobugirl/tobutobugirl.gb
	rm -f $@
	mkfs.fat -C -F 32 $@ 65536 >/dev/null
	mmd -i $@ ::/zx
	mcopy -i $@ zxspectrum.byte emutest.byte ../../packages/zxspectrum/48.rom \
	  ../../third_party/glazx/glazx48.tap ::/zx/
	mmd -i $@ ::/gb
	mcopy -i $@ camlboy.byte emutest_gb.byte ../../third_party/tobutobugirl/tobutobugirl.gb ::/gb/

clean:
	rm -rf zx et cb eg zxspectrum.byte emutest.byte camlboy.byte emutest_gb.byte emu.img
