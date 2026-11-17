# Network test: a RAM disk with the runtime, netd, init.byte
# (net_test.ml), the test authority's certificate, and llmd with its
# test configuration. Built in the dev container (tools/build-all.sh).

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

llmd.byte: ../../services/llm/llmd.byte
	cp $< $@

sh.byte: ../../sh/sh.byte
	cp $< $@

agent.byte: ../../agent/agent.byte
	cp $< $@

tmpfs.byte: ../../services/tmpfs/tmpfs.byte
	cp $< $@

ask-yes.txt:
	echo y > $@

ask-no.txt:
	echo n > $@

FILES = init.byte net_child.byte ocamlrun netd cacert.pem llmd.byte llm-test.env \
	sh.byte ask-yes.txt ask-no.txt agent.byte tmpfs.byte

ramdisk.dsk: $(FILES)
	../../services/fs/memrofs/tool/createDisk $(FILES) >/dev/null

clean:
	rm -f *.cm[io] *.byte ocamlrun netd cacert.pem ramdisk.dsk ask-yes.txt ask-no.txt
