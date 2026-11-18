# OCaml's threads on MyNOS (mynos-09i): linked with -noautolink, since the
# runtime (mynos-runtime/ocamlrun) has the unix and threads primitives
# built in and loads no shared library.
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml \
	-I +unix -I +threads -noautolink

all: threads_test.byte

threads_test.byte: threads_test.ml ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives
	$(OCAMLC) mynos.cma unix.cma threads.cma -o $@ threads_test.ml

clean:
	rm -f *.cm[io] *.byte
