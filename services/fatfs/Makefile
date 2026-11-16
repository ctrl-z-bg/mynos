# fatfs: the FAT filesystem service, in OCaml (fatfs.ml). Built in the dev
# container (tools/build-all.sh), started by init from the system RAM disk.

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: fatfs.byte

fatfs.byte: fatfs.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ fatfs.ml

clean:
	rm -f *.cm[io] *.byte
