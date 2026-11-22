# play: sound from the command line (module Sound, soundd), in OCaml.
# Built in the dev container (tools/build-all.sh), on the system RAM disk
# as play.byte.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: play.byte

play.byte: play.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ play.ml

clean:
	rm -f *.cm[io] *.byte
