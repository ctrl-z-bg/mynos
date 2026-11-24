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

#ifndef __MYNOS_H__
#define __MYNOS_H__

#include <mynos_registry.h>

// MYNOS ERRORS
#define MYNOS_ERR_FULL     (-1)
#define MYNOS_ERR_BUSY     (-2)
#define MYNOS_ERR_INVALID  (-3)
#define MYNOS_ERR_DENY     (-4)
#define MYNOS_ERR_BROKEN   (-5)
#define MYNOS_ERR_EXPIRED  (-6)

// IPC FLAGS
#define MYNOS_IPC_SHARED     0x1
#define MYNOS_IPC_NONBLOCK   0x2

/* PREDEFINED PORTS: the ones below MYNOS_FIRST_FREE_PORT are taken by
   number only (allocPortP), by privileged processes */
#define MYNOS_PORT_REGISTRY 0
#define MYNOS_FIRST_FREE_PORT 16

/* privileges of a process (doc/decisions/identity-and-permissions.md):
   given at spawn, at most the parent's own */
#define MYNOS_PRIV_IO 1        /* port I/O and IRQs: drivers */
/* with driverRegister's irq: a PCI line, level-triggered, which drivers
   may share; the kernel masks it at each interrupt, and the driver
   unmasks it with enableIrq once it has talked to its device */
#define MYNOS_IRQ_PCI 0x100
/* processInfo's result: the privileges, and this bit while it runs */
#define MYNOS_PROC_ALIVE 0x100
#define MYNOS_PROC_BYTECODE 0x200   /* processes(): an OCaml program, on ocamlrun */

// under this size (byte) the message is copied if not shared
// (copied twice, to be honest)
#define MYNOS_SHORT_MESSAGE_SIZE 8

typedef struct {
  void * start;
  unsigned int size;
  int isShort;
} mynos_msg_t;

typedef struct {
  unsigned int numProcesses;
  unsigned int numThreads;
  unsigned int pid;
  unsigned int ppid;
  unsigned int freeppages;
} mynos_stats_t;

/* IPC */
int mynos_send(int channel, void * buf, unsigned int size,
	       unsigned int flags);
int mynos_recv(int channel, mynos_msg_t **pmsg, 
	       unsigned int flags, unsigned int timeout);
/* send and receive an empty message */
void mynos_signalSync(int channel);
void mynos_waitSync(int channel);
int mynos_freeChannel(int c);
int mynos_freeMsg(mynos_msg_t ** pmsg);

/* Port */
int mynos_allocPort();
int mynos_allocPortP(int port);
int mynos_connectToPort(int port);
int mynos_listenPort(int port);
int mynos_changePortOwner(int port, int newpid);
/* the pid of the process at the other end of a channel of ours: a
   service's caller (doc/decisions/identity-and-permissions.md) */
int mynos_channelPeer(int channel);
int mynos_freePort(int port);

/* Semaphore */
int mynos_P(int sem);
int mynos_tryP(int sem);   /* 0: taken, 1: would block, <0: error */
int mynos_V(int sem);
int mynos_initSem(unsigned int n);
int mynos_freeSem(int sem);

int mynos_enableIrq(unsigned short n);
int mynos_disableIrq(unsigned short n);

int mynos_driverRegister(char * name, unsigned int irq, 
			 unsigned int * io, unsigned int * mem);

int mynos_serviceRegister(char * name);
int mynos_clientRegister(char * name);

void outportb(unsigned short port,unsigned char value);
unsigned char inportb(unsigned short port);

/* THREADS STUFF */
int mynos_threadCreate(void * (*start_routine)(void *), 
		  void * arg, void * stack, unsigned int flags);
void mynos_threadExit(void * retval);
int mynos_threadSelf();

/* TIMER */
/* block the calling thread for at least usec microseconds (1 ms ticks) */
int mynos_sleep(unsigned long usec);
int mynos_setTimer(unsigned long usec);  /* old name of mynos_sleep */

/* STATS */
void mynos_stats(mynos_stats_t * st);

/* CONSOLE */
/* the console's input mode: canon (line editing) and echo, and for raw
   input VMIN and VTIME as termios (tcsetattr does the same) */
int mynos_consoleMode(int canon, int echo, int vmin, int vtime);
/* the program the caller started and waits for: Ctrl-C on the console
   ends it (0: none); -1 without a console */
int mynos_consoleForeground(int pid);
/* the same, and Ctrl-C an interrupt (isig 1) or a key (0, editors), or
   unchanged (-1) */
int mynos_consoleModeSig(int canon, int echo, int isig, int vmin, int vtime);

/* key releases in raw mode (1) or not (0), reported after the keys as
   CONSOLE_RELEASES says (mynos_console.h): displayd */
int mynos_consoleKeyReleases(int on);

/* LOG */
/* write a line (printf format) to the kernel log: the serial log port, not
   the screen, once the system has started. For services' messages. */
void mynos_log(const char * fmt, ...);

/* EVENT RECORDER (doc/decisions/tracer.md, mynos-core/kernel/trace.h) */
#define MYNOS_TRACE_START 0
#define MYNOS_TRACE_STOP  1
#define MYNOS_TRACE_READ  2   /* arg1: buffer, arg2: events -> how many */
#define MYNOS_TRACE_INFO  3   /* arg1: 9 words */
#define MYNOS_TRACE_FREE  4
#define MYNOS_TRACE_MARK  5   /* arg1: a label, arg2: its length */
#define MYNOS_TRACE_EVENT_SIZE 96

/* the live processes (native 33): 32 bytes each, at most max: how many */
typedef struct {
  int pid, ppid;
  unsigned int privileges;    /* MYNOS_PRIV_* */
  unsigned int threads;
  char name[16];              /* the program's base name */
} mynos_process_t;
int mynos_processes(mynos_process_t * buf, int max);

/* end a process (native 34), as killed (SIGKILL): not init, not one with
   privileges the caller lacks; 0 or an error */
int mynos_kill(int pid);
int mynos_trace(int op, void * arg1, unsigned int arg2);
/* the kernel's log (native 35): its messages since boot, the last 64 KB of
   them. buf NULL: the position now (bytes ever logged); otherwise copies
   the bytes from position `from` (the oldest kept, if older): how many */
int mynos_klog(unsigned int from, char * buf, unsigned int max);
/* the page faults resolved (native 36): pid's, or the system's since boot
   (pid 0): out[0] pages allocated on use, out[1] copy-on-write; 0 or an
   error */
int mynos_faults(int pid, unsigned int out[2]);
/* a process's statistics (native 38): out[0] its CPU ticks (10 ms), [1]
   and [2] its page faults (allocated on use, copy-on-write), [3] its pages
   in memory, [4] its threads, [5] the clock's ticks since boot; pid 0:
   the kernel, whose ticks are the idle time and whose pages are the
   RAM's; 0 or an error */
int mynos_procstat(int pid, unsigned int out[6]);

/* THE EXTERNAL PAGER (native 37; doc/manual/appendix-b-memory.md, B.14) */
#define MYNOS_PAGER_REGISTER 0
#define MYNOS_PAGER_REGION   1
#define MYNOS_PAGER_NEXT     2
#define MYNOS_PAGER_SUPPLY   3
#define MYNOS_PAGER_QUERY    4
#define MYNOS_PAGER_EVICT    5
#define MYNOS_PAGER_COPY     6
/* a page a process waits for */
typedef struct {
  int pid;
  unsigned int addr;       /* the page's address in that process */
  unsigned int token;      /* the region's token, plus the page's index */
  int write;               /* the first access was a write */
} mynos_pager_fault_t;
/* become the pager (the io privilege): a semaphore of ours, V'd once for
   each page waited for; or an error */
int mynos_pagerRegister(void);
/* npages of pid's memory, waiting for us, tokens from token on, writable
   or not: the first page's address, or 0 (no room, or an error) */
void * mynos_pagerRegion(int pid, unsigned int npages, unsigned int token, int writable);
/* the next page waited for: 1, or 0 for none */
int mynos_pagerNext(mynos_pager_fault_t * f);
/* our page at src (page-aligned) moves to pid at addr; src NULL: none,
   that process ends; 0 or an error */
int mynos_pagerSupply(int pid, void * addr, void * src);
/* a page given to pid at addr: 0 if it is not there (or not given), else
   1 | 2 if used since the last query | 4 if written since the last copy;
   its use forgotten */
int mynos_pagerQuery(int pid, void * addr);
/* that page taken back: its frame moves to our page at dst, and pid's
   entry waits for us again, with token (writable or not); 0 or an error */
int mynos_pagerEvict(int pid, void * addr, void * dst, unsigned int token, int writable);
/* that page copied into ours at dst, its writes forgotten; 0 or an error */
int mynos_pagerCopy(int pid, void * addr, void * dst);

/* PROCESSES */
/* start the ELF program in file path as a child process, with arguments
   and environment (NULL-terminated; argv may be NULL, envp NULL means our
   own environment); returns its pid or a MYNOS_ERR_* code. A bare name is
   looked for at the root of the RAM disk, then in the current directory;
   the child starts in our current directory (PWD). Wait for it with
   waitpid. */
int mynos_spawn(const char * path, char ** argv, char ** envp);
/* the same, giving the child privileges (MYNOS_PRIV_*): at most ours */
int mynos_spawnPriv(const char * path, char ** argv, char ** envp,
		    int privileges);
/* a process's privileges, | MYNOS_PROC_ALIVE while it runs; an error if
   there is no such pid (pids are not reused: a slot's next process gets
   another one) */
int mynos_processInfo(int pid);
/* a device's memory (not RAM: a frame buffer), npages from physical
   address phys, mapped here (drivers only): its address, or NULL */
void * mynos_mapPhysical(unsigned long phys, int npages);
/* the DMA area: MYNOS_DMA_AREA_SIZE bytes of RAM below 16 MB, on a 64 KB
   boundary, chosen by the kernel at boot, for ISA DMA (a sound card's),
   mapped here: its address, its physical address in *phys (the DMA
   controller's); NULL without one. Drivers only. */
#define MYNOS_DMA_AREA_SIZE 65536
void * mynos_dmaArea(unsigned long * phys);
/* npages (1 to 256) of RAM in one physical piece, zeroed, mapped here,
   for a device that reads and writes memory by itself (virtio): its
   address, its physical address in *phys; NULL if there is no such
   piece. Drivers only. Freed when the process ends. */
void * mynos_dmaAlloc(int npages, unsigned long * phys);
/* the same, from an ELF image in memory */
int mynos_spawnImage(void * elf, unsigned int len, char ** argv, char ** envp);

#endif
