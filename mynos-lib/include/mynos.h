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

/* PREDEFINED PORTS */
#define MYNOS_PORT_REGISTRY 0

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
/* block the calling thread for at least usec microseconds (10 ms ticks) */
int mynos_sleep(unsigned long usec);
int mynos_setTimer(unsigned long usec);  /* old name of mynos_sleep */

/* STATS */
void mynos_stats(mynos_stats_t * st);

/* CONSOLE */
/* the console's input mode: canon (line editing) and echo, and for raw
   input VMIN and VTIME as termios (tcsetattr does the same) */
int mynos_consoleMode(int canon, int echo, int vmin, int vtime);

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
#define MYNOS_TRACE_EVENT_SIZE 96
int mynos_trace(int op, void * arg1, unsigned int arg2);

/* PROCESSES */
/* start the ELF program in file path as a child process, with arguments
   and environment (NULL-terminated; argv may be NULL, envp NULL means our
   own environment); returns its pid or a MYNOS_ERR_* code. A bare name is
   looked for at the root of the RAM disk, then in the current directory;
   the child starts in our current directory (PWD). Wait for it with
   waitpid. */
int mynos_spawn(const char * path, char ** argv, char ** envp);
/* the same, from an ELF image in memory */
int mynos_spawnImage(void * elf, unsigned int len, char ** argv, char ** envp);

#endif
