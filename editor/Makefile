# edit: the MyNOS text editor, in OCaml on Notty (edit.ml). Built in the dev
# container (tools/build-all.sh); it runs from the system RAM disk.

NOTTY = ../third_party/notty
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives \
	-I ../mynos-lib/ocaml -I $(NOTTY) -I ../third_party/uutf

all: edit.byte

edit.byte: edit.ml $(NOTTY)/notty.cma ../mynos-lib/ocaml/mynos.cma
	$(OCAMLC) mynos.cma notty.cma -o $@ edit.ml

clean:
	rm -f *.cm[io] *.byte
