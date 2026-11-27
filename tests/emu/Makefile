# emu/1 test (doc/decisions/retro-emulators.md, section 8): the packages
# zxspectrum's, camlboy's and msx's programs, built from their specs'
# sources, and emutest.byte, emutest_gb.byte, emutest_msx.byte, which
# drive them through emu/1; a disk with them, their ROMs and games, made
# with mkfs.fat and mtools. Built in the dev container
# (tools/build-all.sh); run by tools/run-tests.sh (sec_emu).

# (run in a folder below this one)
OCAMLC = ocamlc -use-prims ../../../mynos-runtime/primitives -I ../../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives
SPEC = ../../packages/zxspectrum/spec
ZX = $(shell . $(SPEC); for f in $$SOURCES; do echo ../../packages/zxspectrum/$$f; done)

MSX_SPEC = ../../packages/msx/spec
MSX = $(shell . $(MSX_SPEC); for f in $$SOURCES; do echo ../../packages/msx/$$f; done)

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

msx.byte: $(MSX) $(MSX_SPEC) $(MYNOS)
	rm -rf mx && mkdir mx && cp $(MSX) mx/
	cd mx && $(OCAMLC) -I +unix -I +threads -noautolink mynos.cma unix.cma threads.cma \
	  -o ../$@ $(notdir $(MSX))
	rm -rf mx

emutest_msx.byte: emutest_msx.ml ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml $(MYNOS)
	rm -rf em && mkdir em && cp ../../packages/retro/emu_proto.mli ../../packages/retro/emu_proto.ml emutest_msx.ml em/
	cd em && $(OCAMLC) mynos.cma -o ../$@ emu_proto.mli emu_proto.ml emutest_msx.ml
	rm -rf em

emu.img: zxspectrum.byte emutest.byte camlboy.byte emutest_gb.byte msx.byte emutest_msx.byte \
  ../../packages/zxspectrum/48.rom ../../third_party/glazx/glazx48.tap \
  ../../third_party/tobutobugirl/tobutobugirl.gb ../../third_party/cbios/cbios_main_msx1.rom \
  ../../third_party/cbios/cbios_logo_msx1.rom ../../third_party/westen/westen.rom
	rm -f $@
	mkfs.fat -C -F 32 $@ 65536 >/dev/null
	mmd -i $@ ::/zx ::/zx/games
	mcopy -i $@ zxspectrum.byte emutest.byte ../../packages/zxspectrum/48.rom ::/zx/
	mcopy -i $@ ../../third_party/glazx/glazx48.tap ::/zx/games/glazx.tap
	mmd -i $@ ::/gb ::/gb/games
	mcopy -i $@ camlboy.byte emutest_gb.byte ::/gb/
	mcopy -i $@ ../../third_party/tobutobugirl/tobutobugirl.gb ::/gb/games/
	mmd -i $@ ::/msx ::/msx/games
	mcopy -i $@ msx.byte emutest_msx.byte ../../third_party/cbios/cbios_main_msx1.rom \
	  ../../third_party/cbios/cbios_logo_msx1.rom ::/msx/
	mcopy -i $@ ../../third_party/westen/westen.rom ::/msx/games/

clean:
	rm -rf zx et cb eg mx em zxspectrum.byte emutest.byte camlboy.byte emutest_gb.byte msx.byte emutest_msx.byte emu.img
