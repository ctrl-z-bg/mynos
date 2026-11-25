/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The event recorder (doc/decisions/tracer.md): while a recording is on,
 * the kernel writes an event for every interaction between processes
 * (spawn, exit, IPC connections and messages) into a ring buffer, which a
 * program reads with the trace system call (native 32). Events are 96
 * bytes, little endian; module Tracer (mynos-lib/ocaml/tracer.ml) decodes
 * them:
 *
 *    0 seq     4 tsc low   8 tsc high   12 kind (16 bits)   14 pid (16)
 *   16 tid    20 peer     24 channel    28 size    32 arg
 *   36 number of bytes in data (16)     40 data (56 bytes)
 */

#ifndef __TRACE_H__
#define __TRACE_H__

#include "global.h"

#define TRACE_DATA 56

enum {
  TRACE_PROCESS = 1,   /* pid, peer: its parent, data: its name (at start) */
  TRACE_SPAWN,         /* pid: the parent, peer: the child, data: its name */
  TRACE_EXIT,          /* pid, arg: the status */
  TRACE_CONNECT,       /* pid: the client, peer: the server, channel, arg: port */
  TRACE_SEND,          /* pid, peer: the receiver, channel, size, data */
  TRACE_RECV,          /* pid, peer: the sender, channel, size */
  TRACE_FREE,          /* pid, peer: the other side, channel */
  TRACE_IRQ,           /* pid: the driver, peer: the process interrupted,
			  arg: the IRQ */
  TRACE_MARK,          /* pid, data: a label the program gave (its phases) */
  TRACE_FAULT,         /* pid: the process, peer: the external pager,
			  arg: the page it waits for, its number
			  (mem/pager.c) */
  TRACE_PAGE           /* pid: the pager, peer: the process, size: 4096,
			  arg: the page given, its number */
};

/* trace system call operations */
#define TRACE_START 0
#define TRACE_STOP  1
#define TRACE_READ  2   /* arg1: buffer, arg2: events: how many were copied */
#define TRACE_INFO  3   /* arg1: 9 words: recording, pending, dropped,
			   tsc and timer ticks at the start (3 words), now (3) */
#define TRACE_FREE_BUFFER 4
#define TRACE_MARK_OP 5 /* arg1: a label, arg2: its length (at most 56 kept) */

extern int trace_on;

/* a kernel string or bytes (data may be a pointer the caller checked) */
void trace_event(int kind, int pid, int peer, int channel, uint32_t size,
		 uint32_t arg, const void * data, uint32_t n);
#define TRACE(k, pid, peer, ch, size, arg, data, n) \
  do { if (trace_on) trace_event(k, pid, peer, ch, size, arg, data, n); } while (0)

int _mynos_syscall_trace(uint32_t op, vaddr_t arg1, uint32_t arg2);

/* processes (33): the live processes, 32 bytes each (pid, parent,
   privileges | MYNOS_PROC_BYTECODE for OCaml programs, threads, name: 16
   bytes), into buf, at most max: how many */
#define PROCESS_ENTRY 32
int _mynos_syscall_processes(vaddr_t buf, uint32_t max);
int _mynos_syscall_faults(int32_t pid, vaddr_t buf);
int _mynos_syscall_procstat(int32_t pid, vaddr_t buf);
int _mynos_syscall_pager(uint32_t op, uint32_t a, uint32_t b, uint32_t c, uint32_t d);

/* a process's name from its argv (base name; for "ocamlrun X.byte", X) */
void trace_setName(char * name, char ** argv);

#endif
