# llmd: language models as a service, in OCaml (doc/decisions/llm.md).
# Built in the dev container (tools/build-all.sh), started by init from the
# system RAM disk.

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: llmd.byte

llmd.byte: llmd.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ llmd.ml

clean:
	rm -f *.cm[io] *.byte
