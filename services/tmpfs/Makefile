# tmpfs: a writable filesystem in memory, in OCaml (tmpfs.ml). Built in the
# dev container (tools/build-all.sh), started by init from the system RAM
# disk.

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: tmpfs.byte

tmpfs.byte: tmpfs.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ tmpfs.ml

clean:
	rm -f *.cm[io] *.byte
