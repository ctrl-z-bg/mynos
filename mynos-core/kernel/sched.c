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

#include "sched.h"
#include "tss.h"
#include "mem/mem.h"
#include "kutils.h"
#include "process.h"
#include "sem.h"
#include "softtaskswitch.h"
#include "video.h"

process_queue_t readyQueue;

void readyQueueInsert(tss_t * t) {
  pqInsert(&readyQueue, t);
}

tss_t * readyQueueNext() {
  return pqShiftQueue(&readyQueue);
}

tss_t * readyQueueExtractThread(tss_t * t) {
  return pqExtractThread(&readyQueue, t);
}

uint32_t readyQueueNElem() {
  return pqNElem(&readyQueue);
}

void initScheduler() {
  pqInit(&readyQueue);
}

#if 0
void sched1() {
  tss_t * oldThread = currThread;

  do {
    if (currThread->next != NULL)
      currThread = currThread->next;
    else {
      currProcess = (currProcess + 1) % numProcess;
      if (processTable[currProcess]) 
	currThread = processTable[currProcess]->tss;
      else
	currThread = NULL;
    }
    if (currThread && 
	(currThread->timeToWake) && (timerTicks >= currThread->timeToWake)) {
      // SEND A SIGNAL... TODO
      currThread->timeToWake = 0;
      if (currThread->isWaitingOnP != -1)
	__OS_sem_V(currThread->privSem);
    }
  } while ((!processTable[currProcess]) || 
	   (!processTable[currProcess]->isAlive) ||
	   (currThread->isWaitingOnP != -1));

  if (currThread != oldThread)
    switchTo(oldThread, currThread);
}
#endif

void sched() {
  tss_t * oldThread = currThread;

  currThread = readyQueueNext();
  currProcess = currThread->pid;

  if (currThread != oldThread)
    switchTo(oldThread, currThread);
}

