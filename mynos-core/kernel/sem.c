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

#include "global.h"
#include "sem.h"
#include "mem/dynalloc.h"
#include "kutils.h"
#include "tss.h"
#include "process.h"
#include "procqueue.h"
#include "video.h"
#include "sched.h"

#define MAXSEM ((MAXPROCESSES)*2)
#define MAXSEMVALUE 100

typedef struct _semaphore_t {
    uint32_t mutex; /* mutex and used could be merged */
    ubyte_t used;
    int id;
    uint32_t value;
    process_queue_t queue[1];
} semaphore_t;

static struct semaphore_list {
    semaphore_t list[MAXSEM];
    int last;
    uint32_t nused;
    uint32_t mutex;
} semaphores;


#ifdef DEBUG
#define yield() {\
    printk("Yielding on semaphore!\n");\
    sched();\
    }
#else
#define yield() {\
    sched();\
    }
#endif

static inline int __testnset(uint32_t *m) {
    uint32_t result;

    __asm__ volatile ("bts $1, %1; sbbl %0, %0"
                      :"=r" (result):"m" (*m):"memory");
    return(result);
}
/*            __asm__ volatile(\
    	             "tns: lock bts $1, %0\n"\
	             "     jnc tns\n"\
	             ::"m" (*m):"memory");\ */

static inline void __lock(uint32_t *m) {
    while (__testnset(m)) yield();
}


static inline void __unlock(uint32_t *m) {
    __asm__ volatile("lock btr $1, %0\n"::"m" (*m):"memory");
}

static int initSemaphore(int i) {
    semaphores.list[i].value = MAXSEMVALUE;
    semaphores.list[i].used = 0;
    __unlock(&semaphores.list[i].mutex);
    pqInit(semaphores.list[i].queue);
    return(0);
}

int __OS_sem_initSemaphores() { 
    uint32_t i;

    semaphores.nused = 0;
    for (i = 0; i < MAXSEM; i++) 
	if ( initSemaphore(i) < 0 ) return(-1);
    semaphores.last = 0;
    return(0);
}

int __OS_sem_allocateSemaphore(uint32_t n) {
    uint32_t i;
    uint32_t l;

    if ( n > MAXSEMVALUE) return(-1);
    __lock(&(semaphores.mutex));
    if (semaphores.nused == MAXSEM) {
	__unlock(&(semaphores.mutex));
	return(-1);
    }


    for (i = 0; 
	 (i < MAXSEM) && semaphores.list[(i+semaphores.last)%MAXSEM].used; 
	 i++);
    l = semaphores.last;
    semaphores.last += i + 1;
    i = (i+l)%MAXSEM;
    /* i contains a free semaphore index */

    if ( i == MAXSEM ) {
	__unlock(&(semaphores.mutex));
	return(-1);
    }

    semaphores.nused++;    
    
    /* If this lock is stolen by someone he will found used to FALSE,
       and he cannot access. Actually, it could not know the semaphore id
       because is generated here and still not returned */
    __lock(&(semaphores.list[i].mutex));
    semaphores.list[i].used = 1; 
    semaphores.list[i].id = l;
    semaphores.list[i].value = n;
    __unlock(&(semaphores.list[i].mutex));
    __unlock(&(semaphores.mutex));
#ifdef DEBUG
    printk("*SEM*: allocate, found: ");
    print_uint(l);
    printk("\n");
#endif
    return(l);
}


/* [*] WARNING: DEADLOCK ALLOCATE-FREE (it should be ok)*/
int __OS_sem_freeSemaphore(int semid) {
    uint32_t i = semid%MAXSEM;

    /* It could steal the semaphore to someone, the programmer should take care
       of freeing only _dead_ semaphores */
    __lock(&(semaphores.list[i].mutex));
    if ( (!semaphores.list[i].used) || (semaphores.list[i].id != semid) ) {
	__unlock(&(semaphores.list[i].mutex));
	return(-1);
    }
    semaphores.list[i].used = 0;
    __lock(&(semaphores.mutex));
    semaphores.nused--;
    __unlock(&(semaphores.mutex));
    __unlock(&(semaphores.list[i].mutex));
    return(0);
    /* The freed semaphore is accessible, but not used */
}


int __OS_sem_P(int semid) {
    uint32_t *sm;
    int i=semid%MAXSEM;
    
    sm = &(semaphores.list[i].mutex);

    __lock(sm);
#ifdef DEBUG
    printk("*SEM*: P, locked: ");
    print_uint(i);
    printk("[used: ");
    print_uint(semaphores.list[i].used);
    printk("] [id: ");
    print_uint(semaphores.list[i].id);
    printk("] [value: ");
    print_uint(semaphores.list[i].value);
    printk("]\n");
#endif
    if ( (!semaphores.list[i].used) || (semaphores.list[i].id != semid) ) {
	__unlock(sm);
	return(-1);
    }
    
    if ( !semaphores.list[i].value ) {
	/* Add in semaphore queue */
      // TODO THREADS (once it was processTable[currProcess])
      readyQueueExtractThread(currThread);

	pqInsert(semaphores.list[i].queue, currThread);

	__unlock(sm);
#ifdef DEBUG
	printk("*SEM*: P, busy\n");
#endif
	yield();
    }
#ifdef DEBUG
    printk("*SEM*: P GOT!\n");
#endif

    /* Here the semaphore is mine:
       if I was in the queue the lock has been done by the V */
    semaphores.list[i].value--;
    __unlock(sm);
    return(0);
}

int __OS_sem_tryP(int semid) {
    uint32_t *sm;
    uint32_t i=semid%MAXSEM;
    
    sm = &(semaphores.list[i].mutex);
    __lock(sm);
    if ( (!semaphores.list[i].used) || (semaphores.list[i].id != semid) ) {
	__unlock(sm);
	return(-1);
    }
    
    if ( !semaphores.list[i].value ) {
	/* Add in semaphore queue */
	/* currProcess is not in ReadyQueue, I do not need to remove it
	   from there */
	__unlock(sm);
	return(1);
    }

    /* Here the semaphore is mine:
       if I was in the queue the lock has been done by the V */
    semaphores.list[i].value--;
    __unlock(sm);
    return(0);
}


int __OS_sem_V(int semid) {
    uint32_t *sm;
    tss_t * p;
    uint32_t i=semid%MAXSEM;
    uint32_t tw;
    
    sm = &(semaphores.list[i].mutex);
    __lock(sm);
#ifdef DEBUG
    printk("*SEM*: V, locked: ");
    print_uint(i);
    printk("\n");
#endif

    if ( (!semaphores.list[i].used) || (semaphores.list[i].id != semid) ) {
	__unlock(sm);
	return(-1);
    }
    /* Should I wake up someone? */
    tw = !semaphores.list[i].value && !pqEmpty(semaphores.list[i].queue);
    
    semaphores.list[i].value++;
    if ( tw ) {
	/* - (*) Take one from the queue and put it in ready queue 
	   - Let the to know who woke.
	   - Pass the critic section to the waken process 
	     (otherwise is not fair)
	   - value will be put to zero by the waken process */
	p = pqExtract(semaphores.list[i].queue);
#ifdef DEBUG
	printk("*SEM*: V, waking up: ");
	print_uint(p->threadID);
	printk("\n");
#endif

	/* Wake me up before you go go... */
	if (p) readyQueueInsert(p);
    } else __unlock(sm);

    return(0);
}
