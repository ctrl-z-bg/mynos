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

pid_t pqExtract(process_queue_t *q) {
    pid_t r;
    
    if ( pqEmpty(q) ) return(0);
    
    r = q->queue[q->head];
    
    q->head = (q->head+1)%q->len;
    q->pres--;
    return(r);
}

int pqInsert(process_queue_t *q, pid_t p) {
    pid_t r;
    
    if ( pqFull(q) ) return(-1);
    
    q->queue[q->tail] = p;
    
    q->tail = (q->tail+1)%q->len;
    q->pres++;
    return(0);
}

