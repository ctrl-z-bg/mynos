# The Mynos OCaml library (bytecode). Needs ocamlc 5.x and the primitive
# list of the MyNOS runtime (mynos-runtime/primitives).
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives

all: mynos.cma

mynos.cmi: mynos.mli
	$(OCAMLC) -c mynos.mli

mynos.cmo: mynos.ml mynos.cmi
	$(OCAMLC) -c mynos.ml

wire.cmi: wire.mli
	$(OCAMLC) -c wire.mli

wire.cmo: wire.ml wire.cmi
	$(OCAMLC) -c wire.ml

ipc.cmi: ipc.mli wire.cmi mynos.cmi
	$(OCAMLC) -c ipc.mli

ipc.cmo: ipc.ml ipc.cmi
	$(OCAMLC) -c ipc.ml

block.cmi: block.mli ipc.cmi
	$(OCAMLC) -c block.mli

block.cmo: block.ml block.cmi
	$(OCAMLC) -c block.ml

MODULES = mynos.cmo wire.cmo ipc.cmo block.cmo

mynos.cma: $(MODULES)
	$(OCAMLC) -a -o $@ $(MODULES)

clean:
	rm -f *~ *.cm[ioa]
