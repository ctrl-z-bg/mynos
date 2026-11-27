# Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).
# Built in the dev container (tools/build-all.sh); it runs from the system
# RAM disk.
#
#   make            ariadne.byte, for MyNOS
#   make test       the core's checks, run here (in the container: tools/test-ariadne.sh)
#   make expected   (re)write tests/expected/NAME.txt for every test page: read them!

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml -I +unix -I +threads -noautolink
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma ../mynos-runtime/primitives

PAGES = $(sort $(wildcard pages/*.html))
EXPECTED = $(sort $(wildcard tests/expected/*.txt))

# the engine's core: no input or output (the plan's rule 5), so it is
# built and checked on the host too
CORE = url.cmo dom.cmo html.cmo text.cmo pages.cmo

all: ariadne.byte

core: $(CORE) expected.cmo

ariadne.byte: $(CORE) loader.ml ariadne.ml $(MYNOS)
	$(OCAMLC) mynos.cma unix.cma threads.cma -o $@ $(CORE) loader.ml ariadne.ml

# the test pages, built into ariadne (about:test/NAME), and their dumps:
# generated at every make, replaced only when they change (so that a file
# copied back with an older date, as rsync does, still counts)
pages.ml: FORCE
	sh gen-strings.sh pages $(PAGES) > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@
expected.ml: FORCE
	sh gen-strings.sh expected $(EXPECTED) > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@

dom.cmi: dom.mli
	ocamlc -c $<
dom.cmo: dom.ml dom.cmi
	ocamlc -c $<
html.cmi: html.mli dom.cmi
	ocamlc -c $<
html.cmo: html.ml html.cmi
	ocamlc -c $<
text.cmi: text.mli dom.cmi
	ocamlc -c $<
text.cmo: text.ml text.cmi
	ocamlc -c $<
url.cmo: url.ml
	ocamlc -c $<
pages.cmo: pages.ml
	ocamlc -c $<
expected.cmo: expected.ml
	ocamlc -c $<

# the checks, on the host's ocamlrun
tests/run_tests.byte: $(CORE) expected.cmo tests/run_tests.ml
	ocamlc -I . -o $@ $(CORE) expected.cmo tests/run_tests.ml

test: tests/run_tests.byte
	ocamlrun tests/run_tests.byte

expected: tests/run_tests.byte
	for f in $(PAGES); do n=$$(basename $$f .html); \
	  ocamlrun tests/run_tests.byte --print $$n > tests/expected/$$n.txt; done

clean:
	rm -f *.cm[io] tests/*.cm[io] *.byte tests/*.byte pages.ml expected.ml *.new

FORCE:
.PHONY: all core test expected clean FORCE
