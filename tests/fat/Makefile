# the build host's strip, or the target's (AArch64: aarch64-linux-gnu-strip)
STRIP ?= strip
# FAT test: a RAM disk with the runtime, the ATA driver, fatfs and init.byte
# (fat.ml); and two disk images, FAT16 and FAT32, made with mkfs.fat and
# mtools. Built in the dev container (tools/build-all.sh).

OCAMLC = ocamlc -use-prims ../../mynos-runtime/primitives -I ../../mynos-lib/ocaml
MYNOS = ../../mynos-lib/ocaml/mynos.cma ../../mynos-runtime/primitives
DRIVERS = ../../services/ata/ata.byte ../../services/fatfs/fatfs.byte

all: ramdisk.dsk fat16.img fat32.img

init.byte: fat.ml $(MYNOS)
	$(OCAMLC) mynos.cma -o $@ fat.ml

ocamlrun: ../../mynos-runtime/ocamlrun
	$(STRIP) -o $@ $<

ramdisk.dsk: init.byte ocamlrun $(DRIVERS) vblkd
	../../services/fs/memrofs/tool/createDisk init.byte ocamlrun $(DRIVERS) vblkd >/dev/null

# the virtio disk's driver (AArch64's virt has no IDE)
vblkd: ../../services/virtio/vblkd
	$(STRIP) -o $@ $<

# the files every image starts with
content: Makefile
	mkdir -p content/docs
	printf 'Hello from a FAT disk!\n' > content/hello.txt
	printf 'Long names work.\n' > content/docs/'A long file name.txt'
	LC_ALL=C awk 'BEGIN { for (i = 0; i < 100000; i++) printf "%c", i % 253 }' \
	  > content/docs/big.bin
	cp Makefile content/Makefile
	touch content

fat16.img: content
	rm -f $@
	mkfs.fat -C -F 16 -n MYNOS $@ 16384 >/dev/null
	mcopy -s -i $@ content/* ::/

fat32.img: content
	rm -f $@
	mkfs.fat -C -F 32 -n MYNOS $@ 65536 >/dev/null
	mcopy -s -i $@ content/* ::/

clean:
	rm -rf *.cm[io] *.byte ocamlrun vblkd ramdisk.dsk *.img content run-*.img
