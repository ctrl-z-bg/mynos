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

#ifndef _LIST_H 
#define _LIST_H
#include "global.h"

typedef struct list_elem_s {
  void * elem;
  struct list_elem_s * prev;
  struct list_elem_s * next;
} list_elem_t;

typedef struct _process_queue_t {
  list_elem_t * head;
  list_elem_t * tail;
  uint32_t nelem;
} list_t;

void listInit(list_t * q);
int listEmpty(list_t * q);
void * listExtract(list_t *q);
void * listExtractElem(list_t *q, void * p, int (*eq)(void*, void*));
int listInsert(list_t *q, void * p);
// it returns the old first element (now the last one)
void * listShiftQueue(list_t * q);
uint32_t listNElem(list_t * q);

#endif
