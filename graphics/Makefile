# graphics.cma: OCaml's Graphics on Display and Gfx (graphics.mli,
# mynos-0rn), and its test, gtest.byte. Built in the dev container
# (tools/build-all.sh); graphics.cma and graphics.cmi go on the RAM disk.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: graphics.cma gtest.byte

graphics.cmi: graphics.mli $(MYNOS)
	$(OCAMLC) -c graphics.mli

graphics.cma: graphics.ml graphics.cmi
	$(OCAMLC) -c graphics.ml
	$(OCAMLC) -a -o $@ graphics.cmo

gtest.byte: gtest.ml graphics.cma
	$(OCAMLC) mynos.cma graphics.cma -o $@ gtest.ml

clean:
	rm -f *.cm[ioa] *.byte
