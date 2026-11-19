# log: the kernel's log, in OCaml (Mynos.log_read).
# Built in the dev container (tools/build-all.sh), on the system RAM disk
# as log.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: log.byte

log.byte: log_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ log_main.ml

clean:
	rm -f *.cm[io] *.byte
