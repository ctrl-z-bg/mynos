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

SUBDIRS	= 3parts

CFLAGS += $(foreach DIR, $(SUBDIRS), -I$(DIR))

.PHONY: kernel clean all $(SUBDIRS)

SRCSC	= 	$(wildcard *.c)
OFILESC	=	$(SRCSC:%.c=%.o)

SRCSAS	= 	$(wildcard *.asm)
OFILESAS	=	$(SRCSAS:%.asm=%.o)

ALL_OBJ  = $(foreach DIR, $(SUBDIRS), $(DIR)/$(DIR:%=%_module.o))

all: $(SUBDIRS) kernel

$(SUBDIRS):
	$(MAKE) -C $@

$(ALL_OBJ):
	$(MAKE) -C $(@D:%_module.o=%)

($OFILESC): $(SRCSC)
	$(CC) -c $(CFLAGS) $<

($OFILESAS): $(SRCSC)
	$(AS) $(ASFLAGS) $<

kernel: $(ALL_OBJ) $(OFILESC) start.asm
	nasm -f elf start.asm -o start.o
	$(LD) start.o $(OFILESC) $(ALL_OBJ) \
		-o kernel.bin -oformat binary -Ttext 0x0

clean:
	for i in $(SUBDIRS) ; do \
          make -C $$i clean;\
	done
	rm -f *.o *.bin *~

depend:
	for i in $(SUBDIRS) ; do \
	  make -C $$i depend;\
	done
	$(RM) $(DEPEND)
	$(CC) -M $(SRCSC) >> $(DEPEND)

DEPEND = Makefile.depend

ifeq ($(wildcard $(DEPEND)),$(DEPEND))
include $(DEPEND)
endif
