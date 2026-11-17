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

net.cmi: net.mli ipc.cmi
	$(OCAMLC) -c net.mli

net.cmo: net.ml net.cmi
	$(OCAMLC) -c net.ml

json.cmi: json.mli
	$(OCAMLC) -c json.mli

json.cmo: json.ml json.cmi
	$(OCAMLC) -c json.ml

http.cmi: http.mli net.cmi
	$(OCAMLC) -c http.mli

http.cmo: http.ml http.cmi
	$(OCAMLC) -c http.ml

llm.cmi: llm.mli ipc.cmi
	$(OCAMLC) -c llm.mli

llm.cmo: llm.ml llm.cmi
	$(OCAMLC) -c llm.ml

tools.cmi: tools.mli llm.cmi json.cmi ipc.cmi
	$(OCAMLC) -c tools.mli

tools.cmo: tools.ml tools.cmi
	$(OCAMLC) -c tools.ml

gfx.cmi: gfx.mli
	$(OCAMLC) -c gfx.mli

gfx.cmo: gfx.ml gfx.cmi
	$(OCAMLC) -c gfx.ml

display.cmi: display.mli gfx.cmi ipc.cmi
	$(OCAMLC) -c display.mli

display.cmo: display.ml display.cmi
	$(OCAMLC) -c display.ml

gui.cmi: gui.mli display.cmi
	$(OCAMLC) -c gui.mli

gui.cmo: gui.ml gui.cmi
	$(OCAMLC) -c gui.ml

tracer.cmi: tracer.mli
	$(OCAMLC) -c tracer.mli

tracer.cmo: tracer.ml tracer.cmi
	$(OCAMLC) -c tracer.ml

MODULES = mynos.cmo wire.cmo ipc.cmo block.cmo net.cmo json.cmo http.cmo llm.cmo tools.cmo gfx.cmo display.cmo gui.cmo tracer.cmo

mynos.cma: $(MODULES)
	$(OCAMLC) -a -o $@ $(MODULES)

clean:
	rm -f *~ *.cm[ioa]
