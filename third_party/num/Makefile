# nums.cma: the Num library (see README.md), its C stubs in MyNOS's
# ocamlrun (mynos-runtime/Makefile). Built in the dev container
# (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -w -a

all: nums.cma

MODS = int_misc nat big_int arith_flags ratio num arith_status

nums.cma: $(MODS:%=%.mli) $(MODS:%=%.ml) ../../mynos-runtime/primitives
	for m in $(MODS); do $(OCAMLC) -c $$m.mli $$m.ml || exit 1; done
	$(OCAMLC) -a -o $@ $(MODS:%=%.cmo)

clean:
	rm -f *.cm[ioa]
