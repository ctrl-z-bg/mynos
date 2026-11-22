# The graphical session's programs (doc/decisions/gui.md): gui (the
# command), welcome, clock, services, terminal, agent_window. Built in the dev container
# (tools/build-all.sh), on the system RAM disk.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

PROGRAMS = gui.byte welcome.byte clock.byte services.byte terminal.byte recordings.byte files.byte \
	tour.byte log_window.byte \
	system.byte \
	agent_window.byte text.byte

all: $(PROGRAMS)

gui.byte: gui_main.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ gui_main.ml

lesson.cmo: lesson.ml
	$(OCAMLC) -c lesson.ml

system.byte: system.ml lesson.cmo $(MYNOS)
	$(OCAMLC) mynos.cma lesson.cmo -o $@ system.ml

tour.byte: tour.ml lesson.cmo $(MYNOS)
	$(OCAMLC) mynos.cma lesson.cmo -o $@ tour.ml

%.byte: %.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ $<

clean:
	rm -f *.cm[io] *.byte
