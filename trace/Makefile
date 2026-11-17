# trace: the event recorder's command, in OCaml. Built in the dev container
# (tools/build-all.sh), on the system RAM disk as trace.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: trace.byte

trace.byte: trace_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ trace_main.ml

clean:
	rm -f *.cm[io] *.byte
