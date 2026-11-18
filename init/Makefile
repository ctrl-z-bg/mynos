# init: the first MyNOS program (see init.ml). Built in the dev container.

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: init.byte shutdown.byte

init.byte: init.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ init.ml

shutdown.byte: shutdown_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ shutdown_main.ml

clean:
	rm -f *.cm[io] *.byte
