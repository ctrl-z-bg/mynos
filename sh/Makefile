# sh: the MyNOS command shell, in OCaml (sh.ml). Built in the dev container
# (tools/build-all.sh); it runs from the system RAM disk.

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: sh.byte

sh.byte: sh.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ sh.ml

clean:
	rm -f *.cm[io] *.byte
