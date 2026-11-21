# pkg, the package manager (pkg.ml), and the graphical session's Packages
# window (packages_window.ml), both on module Pkgdb (mynos-vcd). Built in
# the dev container (tools/build-all.sh), on the system RAM disk as
# pkg.byte and packages.byte; the Applications window (apps_window.ml),
# apps.byte, the installed packages that open a window.
OCAMLC = ocamlc -use-prims ../mynos-runtime/primitives -I ../mynos-lib/ocaml
MYNOS = ../mynos-lib/ocaml/mynos.cmi ../mynos-lib/ocaml/mynos.cma \
	../mynos-runtime/primitives

all: pkg.byte packages.byte apps.byte

pkgdb.cmo: pkgdb.ml $(MYNOS)
	$(OCAMLC) -c pkgdb.ml

pkg.byte: pkg.ml pkgdb.cmo
	$(OCAMLC) mynos.cma pkgdb.cmo -o $@ pkg.ml

packages.byte: packages_window.ml pkgdb.cmo
	$(OCAMLC) mynos.cma pkgdb.cmo -o $@ packages_window.ml

apps.byte: apps_window.ml pkgdb.cmo
	$(OCAMLC) mynos.cma pkgdb.cmo -o $@ apps_window.ml

clean:
	rm -f *.cm[io] *.byte
