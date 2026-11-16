# The MyNOS OCaml runtime: the upstream bytecode runtime (OCAML_RUNTIME_LIB,
# set by the dev container) linked with a MyNOS main() for the MyNOS loader.
include ../mynos.mk
CC = $(MYNOS_CC)
CFLAGS = -Wall -O2

OCAML_RUNTIME_LIB ?= /opt/ocaml-runtime-musl

all: ocamlrun

ocamlrun: main.o $(OCAML_RUNTIME_LIB)/libcamlrun.a $(OCAML_RUNTIME_LIB)/prims.o
	$(CC) -o $@ main.o $(OCAML_RUNTIME_LIB)/prims.o \
	  $(OCAML_RUNTIME_LIB)/libcamlrun.a -lm -lpthread $(MYNOS_LDFLAGS)

clean:
	rm -f *~ *.o ocamlrun
