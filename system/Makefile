# The system RAM disk: init, its configuration, the services started from
# the disk, the shell with the interfaces it needs, and a few programs.
# The registry and memrofs (which serves this disk) are GRUB modules.
# Built in the dev container (tools/build-all.sh).

STDLIB = $(shell ocamlc -where)

all: ramdisk.dsk

# the runtime and consoled without their debugging information
ocamlrun: ../mynos-runtime/ocamlrun
	strip -o $@ $<
consoled: ../services/console/consoled
	strip -o $@ $<

FILES = ../init/init.byte init.rc ocamlrun consoled \
	../services/tmpfs/tmpfs.byte \
	../shell/shell.byte ../shell/shell.cmi ../mynos-lib/ocaml/mynos.cmi \
	$(wildcard $(STDLIB)/*.cmi) \
	../tests/hello/hello.byte ../tests/spawn/child.byte \
	../tests/ramdisk/AUTOEXEC.BAT

ramdisk.dsk: $(FILES)
	../services/fs/memrofs/tool/createDisk $(FILES) >/dev/null

clean:
	rm -f ocamlrun consoled ramdisk.dsk
