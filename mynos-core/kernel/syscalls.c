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

#include "trace.h"
#include "mem/mem.h"
#include "global.h"
#include "video.h"
#include "syscalls.h"
#include "pic.h"
#include "pit.h"
#include "irq.h"
#include "services.h"
#include "stats.h"
#include "time.h"
#include "process.h"
#include "mynos.h"
#include "ipc/channel.h"

extern uint32_t currProcess;

void _mynos_syscalls_trap_TRAP();
/* the entry, by number: arch/i386/entry.c */



/* unknown native system call: report it and fail the call */
int32_t _mynos_syscall_WRONGSYSCALL(uint32_t syscall_id) {
  printk("MyNOS syscall ");
  print_uint(syscall_id);
  printk(" doesn't exist (process ");
  print_uint(CURRPID);
  printk(")\n");
  return MYNOS_ERR_INVALID;
}

/* sleep for at least usec microseconds (mynos_setTimer / mynos_sleep).
   It used to only store a wake-up time nobody read, in the wrong unit. */
/* spawn (30): start a new process, child of the caller, from an ELF image
   in the caller's memory, with arguments and environment (NULL-terminated
   vectors, either may be NULL). Returns the pid or a MYNOS_ERR_* code. */
int _mynos_syscall_spawn(uint32_t * elf, uint32_t len, char ** argv,
			 char ** envp, uint32_t privileges) {
  if (!__mem_userArea(elf, len) || __mem_userVector(argv, 1024, 4096) < 0 ||
      __mem_userVector(envp, 1024, 4096) < 0)
    return MYNOS_ERR_INVALID;
  /* a child gets at most its parent's privileges */
  if (privileges & ~processTable[currProcess]->privileges)
    return MYNOS_ERR_DENY;
  return createProcess(elf, len, argv, envp, CURRPID, privileges);
}

/* channelPeer (26): the pid of the process at the other end of one of the
   caller's channels (doc/decisions/identity-and-permissions.md); an error
   if the channel is not the caller's, or the other end freed it */
int _mynos_syscall_channelPeer(int32_t c) {
  unichannel_t * other = getMyWriteChannel(c);
  if (other == NULL || getMyReadChannel(c) == NULL) return MYNOS_ERR_INVALID;
  if (other->receiver < 0) return MYNOS_ERR_BROKEN;
  return other->receiver;
}

/* mapPhysical (28): npages of a device's memory (not RAM: a frame
   buffer) from physical address phys, mapped into the caller: their
   address. Drivers only (the io privilege). */
int _mynos_syscall_mapPhysical(uint32_t phys, uint32_t npages) {
  void * a;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  a = __OS_mapPhysical(phys, npages);
  return a ? (int)a : MYNOS_ERR_INVALID;
}

/* dmaArea (29): the DMA area (mem.c: 64 KB below 16 MB, for ISA DMA).
   what 0: mapped into the caller, its address; 1: its physical address,
   which the driver gives the DMA controller. Drivers only (the io
   privilege); MYNOS_ERR_INVALID if the boot found no place for it. */
int _mynos_syscall_dmaArea(uint32_t what) {
  void * a;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (__dma_area == 0) return MYNOS_ERR_INVALID;
  if (what == 1) return (int)__dma_area;
  a = __OS_mapDmaArea();
  return a ? (int)a : MYNOS_ERR_FULL;
}

/* dmaAlloc (39): npages (1 to 256) of RAM, physically contiguous and
   zeroed, mapped into the caller, for a device that reads and writes
   memory by itself (virtio's queues and buffers): their address, and in
   *phys their physical address, which the driver gives the device.
   Drivers only (the io privilege). The process's mapping is the pages'
   only reference: they are freed when it ends. */
int _mynos_syscall_dmaAlloc(uint32_t npages, uint32_t * phys) {
  uint32_t p;
  void * a;
  if (!(processTable[currProcess]->privileges & MYNOS_PRIV_IO))
    return MYNOS_ERR_DENY;
  if (npages == 0 || npages > 256 || !__mem_userArea(phys, sizeof *phys))
    return MYNOS_ERR_INVALID;
  a = __OS_allocDma(npages, &p);
  if (a == NULL) return MYNOS_ERR_FULL;
  if (copy_to_user(phys, &p, sizeof p) < 0) return MYNOS_ERR_INVALID;
  return (int)a;
}

/* processInfo (27): a process's privileges, with MYNOS_PROC_ALIVE while
   it runs; MYNOS_ERR_INVALID if there is no such pid (it ended and was
   collected, or never was) */
int _mynos_syscall_processInfo(pid_t pid) {
  process_descriptor_t * p = proc(pid);
  if (p == NULL) return MYNOS_ERR_INVALID;
  return (int)(p->privileges & 0xFF) | (p->isAlive ? MYNOS_PROC_ALIVE : 0);
}

/* log (31): write a message of a program to the kernel log (the log port,
   and the screen only while kernel messages are shown there) */
int _mynos_syscall_log(const char * s, uint32_t len) {
  uint32_t i;
  if (len > 1024) len = 1024;
  if (!__mem_userArea(s, len)) return MYNOS_ERR_INVALID;
  for (i = 0; i < len; i++)
    print_char(s[i]);
  return 0;
}

int32_t _mynos_syscall_setTimer(ulong32_t usec) {
  time_sleepUsec(usec);
  return 0;
}

/* enableIrq (100), disableIrq (101): the caller's own lines only */
int _mynos_syscall_enableIrq(ushort16_t n) {
  if (!__OS_irq_valid(n)) return MYNOS_ERR_INVALID;
  if (!__OS_irq_owns(n, CURRPID)) return MYNOS_ERR_DENY;
  enable_irq(n);
  return 0;
}

int _mynos_syscall_disableIrq(ushort16_t n) {
  if (!__OS_irq_valid(n)) return MYNOS_ERR_INVALID;
  if (!__OS_irq_owns(n, CURRPID)) return MYNOS_ERR_DENY;
  disable_irq(n);
  return 0;
}


