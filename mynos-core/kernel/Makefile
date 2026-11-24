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


RELPATH    = kernel
include ../CommonHeader

SUBDIRS	= 3parts ipc mem arch/$(ARCH)

#CFLAGS += $(foreach DIR, $(SUBDIRS), -I$(DIR))

# MYNOS LIB INCLUDE
CFLAGS += -I../../mynos-lib/include

# the version (tools/version.sh, written to VERSION by tools/build-all.sh):
# the boot's banner and uname
MYNOS_VERSION := $(shell cat ../../VERSION 2>/dev/null || echo unknown)
CFLAGS += -DMYNOS_VERSION='"$(MYNOS_VERSION)"'

.PHONY: kernel clean all $(SUBDIRS)

SRCSC	= 	$(wildcard *.c)
OFILESC	=	$(SRCSC:%.c=%.o)

SRCSAS	= 	$(wildcard *.asm)
OFILESAS	=	$(SRCSAS:%.asm=%.o)

ALL_OBJ  = 3parts/3parts_module.o ipc/ipc_module.o mem/mem_module.o \
	   arch/$(ARCH)/arch_module.o
# first in the kernel: the multiboot header must be in its first 8 KB
START    = arch/$(ARCH)/start.o

all: $(SUBDIRS) kernel

$(SUBDIRS):
	$(MAKE) -C $@

$(ALL_OBJ):
	$(MAKE) -C $(@D)

($OFILESC): $(SRCSC)
	$(CC) -c $(CFLAGS) $<

($OFILESAS): $(SRCSC)
	$(AS) $(ASFLAGS) $<

kernel: $(ALL_OBJ) $(OFILESC)
	$(LD) $(START) $(OFILESC) $(ALL_OBJ) \
		--oformat elf32-i386 -Ttext 0x200000 -o kernel.elf 

clean:
	for i in $(SUBDIRS) ; do \
          make -C $$i clean;\
	done
	rm -f *.o *.d *.elf *~ Makefile.depend

depend:
	for i in $(SUBDIRS) ; do \
	  make -C $$i depend;\
	done
	$(RM) $(DEPEND)
	$(CC) $(CFLAGS) -M $(SRCSC) >> $(DEPEND)

DEPEND = Makefile.depend

ifeq ($(wildcard $(DEPEND)),$(DEPEND))
include $(DEPEND)
endif

# compiled again when the version changes
main.o linux_syscalls.o: $(wildcard ../../VERSION)

-include $(OFILESC:.o=.d)
