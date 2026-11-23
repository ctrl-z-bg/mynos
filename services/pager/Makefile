# pagerd: the external pager (module Pager, mynos-vzp), in OCaml, and
# mapcat, its command. Built in the dev container (tools/build-all.sh), on
# the system RAM disk as pagerd.byte and mapcat.byte; init starts pagerd.
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml \
	-I +unix -I +threads -noautolink
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: pagerd.byte mapcat.byte

pagerd.byte: pagerd.ml $(MYNOS)
	$(OCAMLC) mynos.cma unix.cma threads.cma -o $@ pagerd.ml

mapcat.byte: mapcat.ml $(MYNOS)
	$(OCAMLC) mynos.cma unix.cma -o $@ mapcat.ml

clean:
	rm -f *.cm[io] *.byte
