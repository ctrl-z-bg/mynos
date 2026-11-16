# The MyNOS shell: the OCaml toplevel (shell.byte), with module Shell.
# Built in the dev container (tools/build-all.sh); it runs from the system
# RAM disk (system/), started by init.

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: shell.byte

shell.cmi: shell.mli $(MYNOS)
	$(OCAMLC) -c shell.mli

shell.cmo: shell.ml shell.cmi
	$(OCAMLC) -c shell.ml

shell.byte: shell.cmo main.ml $(MYNOS)
	$(OCAMLC) -linkall -I +compiler-libs ocamlcommon.cma ocamlbytecomp.cma \
	  ocamltoplevel.cma mynos.cma shell.cmo main.ml -o $@

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
