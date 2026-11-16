# notty.cma: uutf, Notty's core and the MyNOS backend (see README.md).
# Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives \
	-I ../../mynos-lib/ocaml -I ../uutf
MYNOS = ../../mynos-lib/ocaml/mynos.cmi ../../mynos-lib/ocaml/mynos.cma \
	../../mynos-runtime/primitives

all: notty.cma

UUTF = ../uutf/uutf.cmo
MODS = notty_uucp_data notty_uucp notty_grapheme_cluster notty notty_mynos

../uutf/uutf.cmo: ../uutf/uutf.mli ../uutf/uutf.ml
	cd ../uutf && ocamlc -c uutf.mli uutf.ml

notty.cma: $(UUTF) $(MODS:%=%.mli) $(MODS:%=%.ml) $(MYNOS)
	for m in $(MODS); do $(OCAMLC) -w -a -c $$m.mli $$m.ml || exit 1; done
	$(OCAMLC) -a -o $@ $(UUTF) $(MODS:%=%.cmo)

clean:
	rm -f *.cm[ioa] ../uutf/*.cm[io]
