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

#ifndef _PROCQUEUE_H 
#define _PROCQUEUE_H
#include "tss.h"
#include "global.h"
#include "process.h"
#include "tss.h"
#include "list.h"

typedef list_t process_queue_t;

void pqInit(process_queue_t * q);
int pqEmpty(process_queue_t * q);
tss_t * pqExtract(process_queue_t *q);
tss_t * pqExtractThread(process_queue_t *q, tss_t * p);
int pqInsert(process_queue_t *q, tss_t * p);
// this insert a new element order by timeToWake field
int pqInsertOrderByTime(process_queue_t *q, tss_t * p, uint32_t msec);
// it returns the old first element (now the last one)
tss_t * pqShiftQueue(process_queue_t * q);
uint32_t pqNElem(process_queue_t * q);

#endif
