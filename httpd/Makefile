# httpd: a small web server, in OCaml. Built in the dev container
# (tools/build-all.sh), on the system RAM disk.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: httpd.byte

httpd.byte: httpd.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ httpd.ml

clean:
	rm -f *.cm[io] *.byte
