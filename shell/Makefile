# The MyNOS shell: the OCaml toplevel as init.byte, on a RAM disk with the
# runtime, the standard library interfaces and a few programs.
# Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
STDLIB = $(shell ocamlc -where)

all: ramdisk.dsk

shell.cmi: shell.mli
	$(OCAMLC) -c shell.mli

shell.cmo: shell.ml shell.cmi
	$(OCAMLC) -c shell.ml

init.byte: shell.cmo main.ml
	$(OCAMLC) -linkall -I +compiler-libs ocamlcommon.cma ocamlbytecomp.cma \
	  ocamltoplevel.cma mynos.cma shell.cmo main.ml -o $@

# the runtime without its debugging information: 0.5 MB instead of 1.7
ocamlrun: ../mynos-runtime/ocamlrun
	strip -o $@ $<

FILES = init.byte ocamlrun shell.cmi ../mynos-lib/ocaml/mynos.cmi \
	$(wildcard $(STDLIB)/*.cmi) \
	../tests/hello/hello.byte ../tests/spawn/child.byte \
	../tests/ramdisk/AUTOEXEC.BAT

ramdisk.dsk: init.byte ocamlrun shell.cmi
	../services/fs/memrofs/tool/createDisk $(FILES) >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun ramdisk.dsk
