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
#include "list.h"
#include "mem/dynalloc.h"

void listInit(list_t * q) {
  q->head = q->tail = NULL;
  q->nelem = 0;
}

int listEmpty(list_t * q) {
  return (q->nelem == 0);
}

uint32_t listNElem(list_t * q) {
  return q->nelem;
}

void * listExtract(list_t *q) {
  list_elem_t * el;
  void * ret;

  if (listEmpty(q)) return NULL;
  
  q->nelem--;

  el = q->head;
  q->head = el->next;
  if (q->head)
    (q->head)->prev = NULL;
  else // it was the last one
    q->tail = NULL;

  ret = el->elem;
  kfree(el);

  return(ret);
}

// insert at the end of the queue
int listInsert(list_t *q, void * p) {
  list_elem_t * el;  

  el = kmalloc(sizeof(list_elem_t));
  el->elem = p;
  el->next = NULL;
  el->prev = q->tail;
  if (q->tail)
    (q->tail)->next = el;
  q->tail = el;
  if (!q->head)
    q->head = el;
  q->nelem++;

  return(0);
}

/* this function could be implemented as listExtract and listInsert
   but this is more efficent */
void * listShiftQueue(list_t * q) {
  list_elem_t * el;  
  if (listEmpty(q)) return NULL;
  if (q->head == q->tail) return (q->head)->elem; // just one element

  // take the first element
  el = q->head;
  q->head = el->next;
  (q->head)->prev = NULL;

  // add it at the end
  el->next = NULL;
  el->prev = q->tail;
  (q->tail)->next = el;
  q->tail = el;

  return el->elem;
}

#include "process.h"
void * listExtractElem(list_t *q, void * p, int (*eq)(void*, void*)) {
  void * ret;
  list_elem_t * el;
  list_elem_t * prev;
  list_elem_t * next;

  el = q->head;
  if (eq)
    while ((el != NULL) && (!(*eq)(el->elem, p))) el = el->next;
  else
    while ((el != NULL) && (el->elem != p)) el = el->next;
  if (!el) return NULL;

  prev = el->prev;
  next = el->next;

  if (prev)
    prev->next = next;
  else  // it was the first one
    q->head = next;

  if (next)
    next->prev = prev;
  else  // it was the last one
    q->tail = prev;

  q->nelem--;
  ret = el->elem;
  kfree(el);
  return ret;
}

