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

.PHONY  : all clean

include ../../mynos.mk
CC = $(MYNOS_CC)

SRC     =       $(wildcard *.c)
OFILES  =       $(SRC:%.c=%.o)

DEPEND = Makefile.depend

CFLAGS = -Wall -I../../mynos-lib/include
LDFLAGS = -L../../mynos-lib/lib/ -lmynos $(MYNOS_LDFLAGS)

all: seriald

seriald: $(OFILES) ../../mynos-lib/lib/libmynos.a
	$(CC) $(OFILES) -o seriald $(LDFLAGS)


clean:
	rm -f *~ $(OFILES) seriald $(DEPEND)

depend:
	$(RM) $(DEPEND)
	$(CC) $(CFLAGS) -M $(SRC) >> $(DEPEND)

ifeq ($(wildcard $(DEPEND)),$(DEPEND))
include $(DEPEND)
endif
