# 2048.byte: 2048-ml (README.md) against MyNOS's graphics.cma. Built in
# the dev container (tools/build-all.sh); it goes on the RAM disk.
# Compiled inside src: the game has a module Gui of its own, and so has
# mynos.cma; the current directory comes first in the search for gui.cmi.
OCAMLC = ocamlc -use-prims ../../../mynos-runtime/primitives \
	-I ../../../mynos-lib/ocaml -I ../../../graphics
# ocamldep -sort
ML = grid.mli ui.mli grid.ml board.mli game.mli gui.mli input.mli tui.mli \
	board.ml game.ml gui.ml input.ml tui.ml ui.ml main.ml
SRC = $(addprefix src/, $(ML))

all: 2048.byte

2048.byte: $(SRC) ../../graphics/graphics.cma ../../mynos-lib/ocaml/mynos.cma \
		../../mynos-runtime/primitives
	cd src && $(OCAMLC) mynos.cma graphics.cma -o ../$@ $(ML)

clean:
	rm -f 2048.byte src/*.cm[io]
