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

#ifndef __SCHED_H__
#define __SCHED_H__

#include "procqueue.h"

void initScheduler();

void readyQueueInsert(tss_t * t);
tss_t * readyQueueNext();
tss_t * readyQueueExtractThread(tss_t * t);
uint32_t readyQueueNElem();
void sched_handoff(tss_t * t);
void sched();

// timer queue stuff
void timerQueueInsert(tss_t * t, uint32_t msec);
tss_t * timerQueueNext();
tss_t * timerQueueExtractThread(tss_t * t);
uint32_t timerQueueNElem();
tss_t * timerQueueExtractExpired();
int timerQueueDue();

#endif
