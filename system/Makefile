# The system RAM disk: init, its configuration, the services started from
# the disk, the shell with the interfaces it needs, and a few programs.
# The registry and memrofs (which serves this disk) are GRUB modules.
# Built in the dev container (tools/build-all.sh).

STDLIB = $(shell ocamlc -where)

# the disk image (tools/make-iso.sh makes a clean one elsewhere with
# DISK=...)
DISK ?= disk.img

all: ramdisk.dsk $(DISK)

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

# the Num library (mynos-yux): its interfaces
NUM_CMI = $(addprefix ../third_party/num/, num.cmi big_int.cmi nat.cmi ratio.cmi \
	arith_status.cmi arith_flags.cmi int_misc.cmi)

FILES = ../init/init.byte ../init/shutdown.byte init.rc ocamlrun consoled kilo netd displayd ../httpd/httpd.byte \
	../gui/gui.byte ../gui/welcome.byte ../gui/clock.byte ../gui/services.byte ../gui/terminal.byte \
	../gui/agent_window.byte ../gui/recordings.byte ../gui/system.byte ../gui/files.byte \
	../gui/tour.byte ../gui/tour.txt \
	../third_party/fonts/terminus16.psf ../third_party/fonts/terminus16-bold.psf \
	../gui/mynos-logo.pgm ../gui/mynos-logo-2x.pgm \
	../trace/trace.byte ../fetch/fetch.byte ../llm/llm.byte ../agent/agent.byte \
	../log/log.byte ../gui/log_window.byte \
	../services/llm/llmd.byte \
	../third_party/ca-certificates/cacert.pem \
	../services/tmpfs/tmpfs.byte ../services/ata/ata.byte \
	../services/fatfs/fatfs.byte ../editor/edit.byte ../sh/sh.byte \
	../shell/shell.byte ../shell/shell.cmi ../mynos-lib/ocaml/mynos.cmi \
	$(wildcard $(STDLIB)/*.cmi) \
	$(STDLIB)/stdlib.cma $(STDLIB)/std_exit.cmo $(STDLIB)/runtime-launch-info \
	$(STDLIB)/unix/unix.cma $(STDLIB)/unix/unix.cmi $(STDLIB)/threads/threads.cma \
	$(STDLIB)/threads/thread.cmi $(STDLIB)/threads/event.cmi \
	$(STDLIB)/str/str.cma $(STDLIB)/str/str.cmi \
	../third_party/num/nums.cma $(NUM_CMI) \
	../graphics/graphics.cma ../graphics/graphics.cmi ../third_party/2048-ml/2048.byte \
	ocamlc.byte ../mynos-runtime/primitives \
	../mynos-lib/ocaml/mynos.cma ../mynos-lib/ocaml/block.cmi ../mynos-lib/ocaml/fs.cmi \
	../mynos-lib/ocaml/console.cmi ../mynos-lib/ocaml/registry.cmi \
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
$(DISK):
	mkfs.fat -C -F 32 -n MYNOS $@ 65536 >/dev/null
	printf 'This is the MyNOS disk: a FAT32 image, mounted at /disk.\n' > $@.readme
	mcopy -i $@ $@.readme ::/README.TXT
	rm -f $@.readme

clean:
	rm -f ocamlrun consoled kilo netd displayd ocamlc.byte ramdisk.dsk
