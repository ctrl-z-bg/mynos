/*
  MyNOS
  Copyright (C) 2002
  MyNOS team (http://sourceforge.net/projects/mynos/)

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
*/
#include "procqueue.h"
#include "mem/dynalloc.h"

void pqInit(process_queue_t * q) {
  listInit(q);
}

int pqEmpty(process_queue_t * q) {
  return listEmpty(q);
}

uint32_t pqNElem(process_queue_t * q) {
  return pqNElem(q);
}

tss_t * pqExtract(process_queue_t *q) {
  tss_t * ret = (tss_t*)listExtract(q);
  if (ret) ret->queue = NULL;
  return(ret);
}

int pqInsert(process_queue_t *q, tss_t * p) {
  int ret = listInsert(q, p);
  if (ret == 0) 
    p->queue = q;

  return(ret);
}

tss_t * pqShiftQueue(process_queue_t * q) {
  return (tss_t*)listShiftQueue(q);
}

tss_t * pqExtractThread(process_queue_t *q, tss_t * p) {
  tss_t * ret = (tss_t*)listExtractElem(q, p, NULL);
  if (ret)
    ret->queue = NULL;
  return ret;
}

