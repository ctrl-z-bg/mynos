# MyNOS
# Copyright (C) 2002
# MyNOS team (http://sourceforge.net/projects/mynos/)
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

DIRS = boot kernel

.PHONY  : all clean bootfloppy depend

all: test
	for i in $(DIRS) ; do \
		make -C $$i;\
	done

test: test.c
	gcc -c test.c

	ld test.o \
	  /home/zava/tmp/dietlibc-0.17/bin-i386/libm.a \
	  /home/zava/tmp/dietlibc-0.17/bin-i386/dietlibc.a \
	  -static -o test --oformat binary -Ttext 0x40000000

bootfloppy:
	dd if=/dev/zero of=floppyb bs=1024 count=221
	/sbin/mkfs.msdos floppyb
	mount -o loop -t msdos floppyb /mnt/floppy
	cp kernel/kernel.elf /mnt/floppy/
	cp test /mnt/floppy
	umount /mnt/floppy

clean:
	rm -f *~ *.o test
	for i in $(DIRS) ; do \
		make -C $$i clean;\
	done

depend:
		make -C kernel depend;\
