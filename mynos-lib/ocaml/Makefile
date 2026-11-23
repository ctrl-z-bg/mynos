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

fs.cmi: fs.mli ipc.cmi
	$(OCAMLC) -c fs.mli

fs.cmo: fs.ml fs.cmi
	$(OCAMLC) -c fs.ml

console.cmi: console.mli ipc.cmi
	$(OCAMLC) -c console.mli

console.cmo: console.ml console.cmi
	$(OCAMLC) -c console.ml

registry.cmi: registry.mli ipc.cmi
	$(OCAMLC) -c registry.mli

registry.cmo: registry.ml registry.cmi
	$(OCAMLC) -c registry.ml

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

agent.cmi: agent.mli llm.cmi tools.cmi
	$(OCAMLC) -c agent.mli

agent.cmo: agent.ml agent.cmi tracer.cmi
	$(OCAMLC) -c agent.ml

voice.cmi: voice.mli agent.cmi
	$(OCAMLC) -c voice.mli

voice.cmo: voice.ml voice.cmi
	$(OCAMLC) -c voice.ml

gfx.cmi: gfx.mli
	$(OCAMLC) -c gfx.mli

gfx.cmo: gfx.ml gfx.cmi
	$(OCAMLC) -c gfx.ml

display.cmi: display.mli gfx.cmi ipc.cmi
	$(OCAMLC) -c display.mli

display.cmo: display.ml display.cmi
	$(OCAMLC) -c display.ml

pager.cmi: pager.mli ipc.cmi
	$(OCAMLC) -c pager.mli

pager.cmo: pager.ml pager.cmi
	$(OCAMLC) -c pager.ml

clipboard.cmi: clipboard.mli ipc.cmi
	$(OCAMLC) -c clipboard.mli

clipboard.cmo: clipboard.ml clipboard.cmi
	$(OCAMLC) -c clipboard.ml

sound.cmi: sound.mli ipc.cmi
	$(OCAMLC) -c sound.mli

sound.cmo: sound.ml sound.cmi
	$(OCAMLC) -c sound.ml

textarea.cmi: textarea.mli gui.cmi
	$(OCAMLC) -c textarea.mli

textarea.cmo: textarea.ml textarea.cmi
	$(OCAMLC) -c textarea.ml

gui.cmi: gui.mli display.cmi clipboard.cmi
	$(OCAMLC) -c gui.mli

gui.cmo: gui.ml gui.cmi
	$(OCAMLC) -c gui.ml

power.cmi: power.mli ipc.cmi
	$(OCAMLC) -c power.mli

power.cmo: power.ml power.cmi
	$(OCAMLC) -c power.ml

tracer.cmi: tracer.mli
	$(OCAMLC) -c tracer.mli

tracer.cmo: tracer.ml tracer.cmi
	$(OCAMLC) -c tracer.ml

MODULES = mynos.cmo wire.cmo ipc.cmo block.cmo fs.cmo console.cmo registry.cmo net.cmo json.cmo http.cmo llm.cmo tools.cmo tracer.cmo agent.cmo voice.cmo gfx.cmo display.cmo clipboard.cmo gui.cmo textarea.cmo power.cmo sound.cmo pager.cmo

# every module but Mynos uses Mynos: a change in mynos.mli recompiles them
$(filter-out mynos.cmo,$(MODULES)) $(filter-out mynos.cmi,$(MODULES:.cmo=.cmi)): mynos.cmi

mynos.cma: $(MODULES)
	$(OCAMLC) -a -o $@ $(MODULES)

clean:
	rm -f *~ *.cm[ioa]
