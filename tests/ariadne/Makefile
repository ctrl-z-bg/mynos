# the build host's strip, or the target's (AArch64: aarch64-linux-gnu-strip)
STRIP ?= strip
# Ariadne's core (ariadne/, doc/decisions/browser.md) checked in MyNOS: a
# RAM disk with the runtime and init.byte, which is ariadne/tests/run_tests.ml
# (the program make -C ariadne test runs on the host). Built in the dev
# container (tools/build-all.sh), after ariadne.

ARIADNE = ../../ariadne
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I $(ARIADNE)
CORE = $(addprefix $(ARIADNE)/, url.cmo encoding.cmo entities_data.cmo tokenizer.cmo dom.cmo \
	treebuilder.cmo html.cmo text.cmo css.cmo selector.cmo style.cmo layout.cmo pages.cmo expected.cmo expected_layout.cmo)

all: ramdisk.dsk

$(CORE) &: FORCE
	$(MAKE) -C $(ARIADNE) core

# compiled here, so that its objects do not mix with the host's build
init.byte: $(ARIADNE)/tests/run_tests.ml $(CORE) ../../mynos-runtime/primitives
	cp $(ARIADNE)/tests/run_tests.ml run_tests.ml
	$(OCAMLC) -o $@ $(CORE) run_tests.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	$(STRIP) -o $@ $<

ramdisk.dsk: init.byte ocamlrun
	../../services/fs/memrofs/tool/createDisk init.byte ocamlrun >/dev/null

clean:
	rm -f *.cm[io] *.byte run_tests.ml ocamlrun ramdisk.dsk

FORCE:
.PHONY: all clean FORCE
