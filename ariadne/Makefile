# Ariadne, MyNOS's new browser (doc/decisions/browser.md, BROWSER-TODO.md).
# Built in the dev container (tools/build-all.sh); it runs from the system
# RAM disk.
#
#   make            ariadne.byte, for MyNOS
#   make test       the core's checks and html5lib-tests, run here
#                   (in the container: tools/test-ariadne.sh)
#   make test-html5lib-verbose   every failure of html5lib-tests, explained
#   make expected   (re)write tests/expected/NAME.txt for every test page: read them!

OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml -I +unix -I +threads -noautolink
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma ../mynos-runtime/primitives

PAGES = $(sort $(wildcard pages/*.html))
EXPECTED = $(sort $(wildcard tests/expected/*.txt))
EXPECTED_LAYOUT = $(sort $(wildcard tests/expected-layout/*.txt))

# the engine's core: no input or output (the plan's rule 5), so it is
# built and checked on the host too
CORE = url.cmo encoding.cmo entities_data.cmo tokenizer.cmo dom.cmo treebuilder.cmo \
	html.cmo text.cmo css.cmo selector.cmo style.cmo layout.cmo pages.cmo

all: ariadne.byte

core: $(CORE) expected.cmo expected_layout.cmo

ariadne.byte: $(CORE) loader.ml ariadne.ml $(MYNOS)
	$(OCAMLC) mynos.cma unix.cma threads.cma -o $@ $(CORE) loader.ml ariadne.ml

# generated at every make, replaced only when they change (so that a file
# copied back with an older date, as rsync does, still counts): the test
# pages, built into ariadne (about:test/NAME), their dumps, and the HTML
# Standard's named character references
pages.ml: FORCE
	sh gen-strings.sh pages $(PAGES) > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@
expected.ml: FORCE
	sh gen-strings.sh expected $(EXPECTED) > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@
expected_layout.ml: FORCE
	sh gen-strings.sh expected_layout $(EXPECTED_LAYOUT) > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@
entities_data.ml: FORCE
	sh gen-entities.sh ../third_party/whatwg-entities/entities.json > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@

%.cmi: %.mli
	ocamlc -c $<
%.cmo: %.ml
	ocamlc -c $<

# what each module needs
dom.cmo: dom.cmi
tokenizer.cmi: tokenizer.mli
tokenizer.cmo: tokenizer.cmi encoding.cmo entities_data.cmo
treebuilder.cmo: tokenizer.cmi dom.cmi
html.cmi: dom.cmi encoding.cmo
html.cmo: html.cmi treebuilder.cmo encoding.cmo
text.cmi: dom.cmi
text.cmo: text.cmi
css.cmo: encoding.cmo
selector.cmo: css.cmo dom.cmi
style.cmo: css.cmo selector.cmo dom.cmi
layout.cmo: style.cmo dom.cmi

# the checks, on the host's ocamlrun: the core's (tests/run_tests.ml), and
# html5lib-tests (tests/html5lib.ml, with a copy of MyNOS's Json)
tests/run_tests.byte: $(CORE) expected.cmo expected_layout.cmo tests/run_tests.ml
	ocamlc -I . -o $@ $(CORE) expected.cmo expected_layout.cmo tests/run_tests.ml

tests/json.ml: ../mynos-lib/ocaml/json.ml
	cp $< $@
tests/json.mli: ../mynos-lib/ocaml/json.mli
	cp $< $@
tests/html5lib.byte: $(CORE) tests/json.ml tests/json.mli tests/html5lib.ml
	ocamlc -I . -I tests -c tests/json.mli
	ocamlc -I . -I tests -o $@ $(CORE) tests/json.ml tests/html5lib.ml

# the stages timed on saved pages: ocamlrun tests/bench.byte FILE...
tests/bench.byte: $(CORE) tests/bench.ml
	ocamlc -I . -I +unix -o $@ unix.cma $(CORE) tests/bench.ml

HTML5LIB = ../third_party/html5lib-tests/tokenizer ../third_party/wpt-html-parsing

test: tests/run_tests.byte tests/html5lib.byte
	ocamlrun tests/run_tests.byte
	ocamlrun tests/html5lib.byte --fail-under 99.9 $(HTML5LIB)

test-html5lib-verbose: tests/html5lib.byte
	ocamlrun tests/html5lib.byte -v $(HTML5LIB)

expected: tests/run_tests.byte
	for f in $(PAGES); do n=$$(basename $$f .html); \
	  ocamlrun tests/run_tests.byte --print $$n > tests/expected/$$n.txt; \
	  ocamlrun tests/run_tests.byte --print-layout $$n > tests/expected-layout/$$n.txt; done

clean:
	rm -f *.cm[io] tests/*.cm[io] *.byte tests/*.byte *.new
	rm -f pages.ml expected.ml expected_layout.ml entities_data.ml tests/json.ml tests/json.mli

FORCE:
.PHONY: all core test test-html5lib-verbose expected clean FORCE
