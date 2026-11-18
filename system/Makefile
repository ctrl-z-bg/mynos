# The system RAM disk: init, its configuration, the services started from
# the disk, the shell with the interfaces it needs, and a few programs.
# The registry and memrofs (which serves this disk) are GRUB modules.
# Built in the dev container (tools/build-all.sh).

STDLIB = $(shell ocamlc -where)

all: ramdisk.dsk disk.img

# the runtime and consoled without their debugging information
ocamlrun: ../mynos-runtime/ocamlrun
	strip -o $@ $<
consoled: ../services/console/consoled
	strip -o $@ $<
kilo: ../third_party/kilo/kilo
	strip -o $@ $<
netd: ../services/net/netd
	strip -o $@ $<
displayd: ../services/display/displayd
	strip -o $@ $<

# the bytecode compiler, to compile programs inside MyNOS
ocamlc.byte: $(shell command -v ocamlc.byte 2>/dev/null || echo /opt/ocaml-5.5.2/bin/ocamlc.byte)
	cp $< $@

FILES = ../init/init.byte ../init/shutdown.byte init.rc ocamlrun consoled kilo netd displayd ../httpd/httpd.byte \
	../gui/gui.byte ../gui/welcome.byte ../gui/clock.byte ../gui/services.byte ../gui/terminal.byte \
	../gui/agent_window.byte ../gui/recordings.byte ../gui/system.byte \
	../third_party/fonts/terminus16.psf ../third_party/fonts/terminus16-bold.psf \
	../gui/mynos-logo.pgm ../gui/mynos-logo-2x.pgm \
	../trace/trace.byte ../fetch/fetch.byte ../llm/llm.byte ../agent/agent.byte \
	../services/llm/llmd.byte \
	../third_party/ca-certificates/cacert.pem \
	../services/tmpfs/tmpfs.byte ../services/ata/ata.byte \
	../services/fatfs/fatfs.byte ../editor/edit.byte ../sh/sh.byte \
	../shell/shell.byte ../shell/shell.cmi ../mynos-lib/ocaml/mynos.cmi \
	$(wildcard $(STDLIB)/*.cmi) \
	$(STDLIB)/stdlib.cma $(STDLIB)/std_exit.cmo $(STDLIB)/runtime-launch-info \
	ocamlc.byte ../mynos-runtime/primitives \
	../mynos-lib/ocaml/mynos.cma ../mynos-lib/ocaml/block.cmi \
	../mynos-lib/ocaml/wire.cmi ../mynos-lib/ocaml/ipc.cmi ../mynos-lib/ocaml/net.cmi \
	../mynos-lib/ocaml/tracer.cmi ../mynos-lib/ocaml/json.cmi ../mynos-lib/ocaml/http.cmi \
	../mynos-lib/ocaml/llm.cmi ../mynos-lib/ocaml/tools.cmi \
	../mynos-lib/ocaml/gfx.cmi ../mynos-lib/ocaml/display.cmi ../mynos-lib/ocaml/gui.cmi \
	../mynos-lib/ocaml/power.cmi ../mynos-lib/ocaml/agent.cmi \
	../tests/hello/hello.byte ../tests/spawn/child.byte \
	../tests/ramdisk/AUTOEXEC.BAT

ramdisk.dsk: $(FILES)
	../services/fs/memrofs/tool/createDisk $(FILES) >/dev/null

# the disk of the demo, mounted at /disk: made once, and kept (it holds
# what you save); remove it to start again with an empty one
disk.img:
	mkfs.fat -C -F 32 -n MYNOS $@ 65536 >/dev/null
	printf 'This is the MyNOS disk: a FAT32 image, mounted at /disk.\n' > README.TXT
	mcopy -i $@ README.TXT ::/README.TXT
	rm -f README.TXT

clean:
	rm -f ocamlrun consoled kilo netd displayd ocamlc.byte ramdisk.dsk
