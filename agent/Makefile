# agent: a task carried out by a language model with tools (modules Llm,
# Tools, Tracer; doc/decisions/llm.md). Built in the dev container
# (tools/build-all.sh), on the system RAM disk as agent.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: agent.byte

agent.byte: agent_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ agent_main.ml

clean:
	rm -f *.cm[io] *.byte
