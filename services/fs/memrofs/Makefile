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

DIRS = tool

.PHONY  : all clean

include ../../../mynos.mk
CC = $(MYNOS_CC)

SRC     =       $(wildcard *.c)
OFILES  =       $(SRC:%.c=%.o)

DEPEND = Makefile.depend

CFLAGS = -Wall -I../../../mynos-lib/include
LDFLAGS = -L../../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: memrofsd
	for i in $(DIRS) ; do \
		make -C $$i;\
	done

memrofsd: $(OFILES) ../../../mynos-lib/lib/libmynos.a
	$(CC) $(OFILES) -o memrofsd $(LDFLAGS)


clean:
	for i in $(DIRS) ; do \
		make -C $$i clean;\
	done
	rm -f *~ $(OFILES) memrofsd $(DEPEND)

depend:
	for i in $(DIRS) ; do \
		make -C $$i depend;\
	done
	$(RM) $(DEPEND)
	$(CC) $(CFLAGS) -M $(SRC) >> $(DEPEND)

ifeq ($(wildcard $(DEPEND)),$(DEPEND))
include $(DEPEND)
endif
