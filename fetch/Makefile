# fetch: HTTP and HTTPS from the command line (module Http), in OCaml.
# Built in the dev container (tools/build-all.sh), on the system RAM disk
# as fetch.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: fetch.byte

fetch.byte: fetch_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ fetch_main.ml

clean:
	rm -f *.cm[io] *.byte
