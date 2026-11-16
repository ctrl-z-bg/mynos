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

static process_queue_t readyQueue;
static process_queue_t timerQueue;

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

#if 0
void prova() {
  tss_t * a;
  tss_t * b;
  tss_t * c;
  list_elem_t * el;
  timerTicks = 120;
  a = kmalloc(sizeof(tss_t));
  b = kmalloc(sizeof(tss_t));
  c = kmalloc(sizeof(tss_t));
  timerQueueInsert(a, 2000);
  timerQueueInsert(b, 5000);
  timerQueueInsert(c, 3000);
  el = timerQueue.head;
  printk("\n--");
  print_ulong(timerTicks);
  while (el != NULL) {
    tss_t * t = (tss_t*)el->elem;
    printk("\n----");
    print_ulong(t->timeToWake);
    el = el->next;
  }
  while(1);
}
#endif

void initScheduler() {
  pqInit(&timerQueue);
  pqInit(&readyQueue);
}

void timerQueueInsert(tss_t * t, uint32_t msec) {
  pqInsertOrderByTime(&timerQueue, t, msec);
}

tss_t * timerQueueNext() {
  return pqShiftQueue(&timerQueue);
}

tss_t * timerQueueExtractThread(tss_t * t) {
  return pqExtractThread(&timerQueue, t);
}

uint32_t timerQueueNElem() {
  return pqNElem(&timerQueue);
}

tss_t * timerQueueExtractExpired() {
  tss_t * ret;
  if (pqEmpty(&timerQueue))
    return NULL;
  
  ret = (tss_t*)(timerQueue.head->elem);
  if (ret->timeToWake < timerTicks) {
    // remove the first element...
    pqExtract(&timerQueue);
    // ... and return it
    return ret;
  }
  return NULL;
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
  tss_t * awaken;
  
  // wake the timeout expired processes
  while ((awaken = timerQueueExtractExpired()) != NULL)
    privV(awaken);

  // free the memory of the processes that ended
  reapZombies();

  currThread = readyQueueNext();
  /* the idle thread (process 0) runs only when no other thread is ready:
     it keeps the CPU until the next timer tick, and every IPC exchange
     that reached it in the round robin waited up to 10 ms */
  if (currThread->pid == 0 && readyQueueNElem() > 1)
    currThread = readyQueueNext();
  currProcess = currThread->pid;

  if (currThread != oldThread)
    switchTo(oldThread, currThread);
}

