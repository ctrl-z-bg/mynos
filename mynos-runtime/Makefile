# The MyNOS OCaml runtime: the upstream bytecode runtime (OCAML_RUNTIME_LIB,
# set by the dev container) linked with a MyNOS main() and the primitives of
# the Mynos library (mynos_stubs.c, built on libmynos).
#
# Outputs: ocamlrun, and primitives (the full primitive list, which ocamlc
# needs with -use-prims to link programs that use Mynos).
include ../mynos.mk
CC = $(MYNOS_CC)

OCAML_RUNTIME_LIB ?= /opt/ocaml-runtime-musl
CFLAGS = -Wall -O2 -I$(OCAML_RUNTIME_LIB) -I../mynos-lib/include

STUBS = mynos_stubs.c

all: ocamlrun

primitives prims.c: gen_prims.sh $(STUBS) $(OCAML_RUNTIME_LIB)/primitives
	./gen_prims.sh $(OCAML_RUNTIME_LIB) $(STUBS)

prims.o: prims.c
	$(CC) $(CFLAGS) -c prims.c

ocamlrun: main.o mynos_stubs.o prims.o $(OCAML_RUNTIME_LIB)/libcamlrun.a \
          ../mynos-lib/lib/libmynos.a
	$(CC) -o $@ main.o mynos_stubs.o prims.o \
	  $(OCAML_RUNTIME_LIB)/libcamlrun.a -L../mynos-lib/lib -lmynos \
	  -lm -lpthread $(MYNOS_LDFLAGS)

clean:
	rm -f *~ *.o ocamlrun primitives prims.c
