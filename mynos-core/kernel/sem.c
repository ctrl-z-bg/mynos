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
#include "mynos.h"

/* ids: slot + MAXSEM * n (id % MAXSEM finds the slot) */
#define MAXSEM 4096
#define MAXSEMVALUE 100

typedef struct _semaphore_t {
    uint32_t mutex; /* mutex and used could be merged */
    ubyte_t used;
    int id;
    uint32_t value;
    int owner;      /* the process that made it (initSem), or -1: the
		       kernel's, freed by the kernel */
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
	static int said = 0;
	__unlock(&(semaphores.mutex));
	ktableFull("semaphore", &said);
	return(-1);
    }


    for (i = 0; 
	 (i < MAXSEM) && semaphores.list[(i+semaphores.last)%MAXSEM].used; 
	 i++);
    if ( i == MAXSEM ) {
	__unlock(&(semaphores.mutex));
	return(-1);
    }
    /* the id: the free slot's index plus a multiple of MAXSEM, so that
       id % MAXSEM finds the slot again (an id of semaphores.last, the
       first slot looked at, missed when slots were skipped: freeing that
       semaphore then failed, and the table filled up) */
    l = semaphores.last + i;
    if (l >= 0x40000000) l %= MAXSEM;      /* ids stay positive */
    semaphores.last = l + 1;
    i = l % MAXSEM;
    /* i contains a free semaphore index */

    semaphores.nused++;    
    
    /* If this lock is stolen by someone he will found used to FALSE,
       and he cannot access. Actually, it could not know the semaphore id
       because is generated here and still not returned */
    __lock(&(semaphores.list[i].mutex));
    semaphores.list[i].used = 1; 
    semaphores.list[i].id = l;
    semaphores.list[i].value = n;
    semaphores.list[i].owner = -1;
    __unlock(&(semaphores.list[i].mutex));
    __unlock(&(semaphores.mutex));
#ifdef DEBUG
    printk("*SEM*: allocate, found: ");
    print_uint(l);
    printk("\n");
#endif
    return(l);
}


/* initSem (9): a semaphore of the calling process, freed when it ends if
   it does not free it (libmynos's malloc makes one in every process: one
   leaked with each process, until the table was full) */
int __OS_sem_allocateUserSemaphore(uint32_t n) {
    int id = __OS_sem_allocateSemaphore(n);
    if (id >= 0) semaphores.list[id % MAXSEM].owner = CURRPID;
    return id;
}

/* a kernel semaphore given to a process (an IRQ's, to its driver) */
void __OS_sem_setOwner(int semid, int pid) {
    if (semid >= 0 && semaphores.list[semid % MAXSEM].used &&
	semaphores.list[semid % MAXSEM].id == semid)
	semaphores.list[semid % MAXSEM].owner = pid;
}

/* The system calls P (6), tryP (7), V (8), semFree (13): on the calling
   process's own semaphores only. The kernel's (threads' private ones,
   ports') and other processes' are refused. */
static int mine(int semid) {
    semaphore_t * s;
    if (semid < 0) return 0;
    s = &semaphores.list[semid % MAXSEM];
    return s->used && s->id == semid && s->owner >= 0 && s->owner == CURRPID;
}

int __OS_sem_userP(int semid) {
    return mine(semid) ? __OS_sem_P(semid) : MYNOS_ERR_DENY;
}
int __OS_sem_userTryP(int semid) {
    return mine(semid) ? __OS_sem_tryP(semid) : MYNOS_ERR_DENY;
}
int __OS_sem_userV(int semid) {
    return mine(semid) ? __OS_sem_V(semid) : MYNOS_ERR_DENY;
}
int __OS_sem_userFree(int semid) {
    return mine(semid) ? __OS_sem_freeSemaphore(semid) : MYNOS_ERR_DENY;
}

/* the semaphores a process made: at its end */
void __OS_sem_freeProcessSemaphores(int pid) {
    uint32_t i;
    for (i = 0; i < MAXSEM; i++)
	if (semaphores.list[i].used && semaphores.list[i].owner == pid)
	    __OS_sem_freeSemaphore(semaphores.list[i].id);
}

/* [*] WARNING: DEADLOCK ALLOCATE-FREE (it should be ok)*/
int __OS_sem_freeSemaphore(int semid) {
    uint32_t i = semid%MAXSEM;
    if (semid < 0) return(-1);   /* a negative id indexed before the table */

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
    if (semid < 0) return(-1);   /* a negative id indexed before the table */
    
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
    currThread->semHeld = 0;
    __unlock(sm);
    return(0);
}

/* a thread that ends (its process killed) after a V woke it, before it
   ran: the lock the V handed it is freed, and the V stays (the value it
   raised, taken by nobody). Without it the lock stayed held: the next P,
   V or free of that semaphore spun in __lock for ever (a window's program
   woken by its Close and killed at once by its terminal's hang-up, at the
   end of the graphical session: the kernel then turned in sched) */
void __OS_sem_threadEnded(void * thread) {
    tss_t * t = thread;
    if (t->semHeld > 0 && t->semHeld <= MAXSEM)
	__unlock(&semaphores.list[t->semHeld - 1].mutex);
    t->semHeld = 0;
}

int __OS_sem_tryP(int semid) {
    uint32_t *sm;
    uint32_t i=semid%MAXSEM;
    if (semid < 0) return(-1);   /* a negative id indexed before the table */
    
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
    if (semid < 0) return(-1);   /* a negative id indexed before the table */
    
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
	if (p) {
	    p->semHeld = i + 1;       /* the lock, handed to it */
	    readyQueueInsert(p);
	}
    } else __unlock(sm);

    return(0);
}
