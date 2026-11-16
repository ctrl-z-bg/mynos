# The Mynos OCaml library (bytecode). Needs ocamlc 5.x and the primitive
# list of the MyNOS runtime (mynos-runtime/primitives).
OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives

all: mynos.cma

mynos.cmi: mynos.mli
	$(OCAMLC) -c mynos.mli

mynos.cmo: mynos.ml mynos.cmi
	$(OCAMLC) -c mynos.ml

block.cmi: block.mli mynos.cmi
	$(OCAMLC) -c block.mli

block.cmo: block.ml block.cmi
	$(OCAMLC) -c block.ml

mynos.cma: mynos.cmo block.cmo
	$(OCAMLC) -a -o $@ mynos.cmo block.cmo

clean:
	rm -f *~ *.cm[ioa]
