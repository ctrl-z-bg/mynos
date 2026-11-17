# Network test: a RAM disk with the runtime, netd, init.byte
# (net_test.ml) and the test authority's certificate. Built in the dev
# container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives

all: ramdisk.dsk

init.byte: net_test.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ net_test.ml

net_child.byte: net_child.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ net_child.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	strip -o $@ $<

netd: ../../services/net/netd
	strip -o $@ $<

# netd trusts the test authority (tls/ca.pem), as /cacert.pem
cacert.pem: tls/ca.pem
	cp $< $@

ramdisk.dsk: init.byte net_child.byte ocamlrun netd cacert.pem
	../../services/fs/memrofs/tool/createDisk init.byte net_child.byte ocamlrun netd cacert.pem >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun netd cacert.pem ramdisk.dsk
