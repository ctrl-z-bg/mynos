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

#ifndef _SCHED_H 
#define _SCHED_H
#include "process.h"
#include "global.h"
#include "procqueue.h"
#include "tss.h"

typedef struct _process_queue_t {
  tss_t * queue[MAXPROCESSES+1];
  uint32_t len;
  uint32_t pres;
  uint32_t head;
  uint32_t tail;
} process_queue_t;

#define pqEmpty(q) ( ((q)->tail) == ((q)->head) )
#define pqFull(q)  ( ((q)->pres) == ((q)->len - 1) )
#define pqInit(q)  { (q)->tail = (q)->head; \
                     (q)->pres = 0; \
                     (q)->len = MAXPROCESSES + 1; }

tss_t * pqExtract(process_queue_t *q);
int pqInsert(process_queue_t *q, tss_t * p);

#endif
