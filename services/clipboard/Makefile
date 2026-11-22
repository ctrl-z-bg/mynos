# clipboard: the clipboard service (module Clipboard), in OCaml. Built in
# the dev container (tools/build-all.sh), on the system RAM disk as
# clipboard.byte; init starts it.
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: clipboard.byte

clipboard.byte: clipboard_service.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ clipboard_service.ml

clean:
	rm -f *.cm[io] *.byte
