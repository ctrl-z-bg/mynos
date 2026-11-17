# llm: ask a language model from the command line (module Llm, service
# llmd). Built in the dev container (tools/build-all.sh), on the system
# RAM disk as llm.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: llm.byte

llm.byte: llm_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ llm_main.ml

clean:
	rm -f *.cm[io] *.byte
