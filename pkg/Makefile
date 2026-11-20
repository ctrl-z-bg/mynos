# pkg: the package manager (pkg.ml, mynos-vcd), in OCaml. Built in the dev
# container (tools/build-all.sh), on the system RAM disk as pkg.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: pkg.byte

pkg.byte: pkg.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ pkg.ml

clean:
	rm -f *.cm[io] *.byte
