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
#include "video.h"
#include "sem.h"
#include "irq.h"
#include "kutils.h"
#include "dynalloc.h"
#include "process.h"
#include "services.h"

#define MIN(A,B) (((A) < (B))?(A):(B))

typedef struct _procList {
  pid_t pid;
  struct _procList * next;
} procList_t;


struct serviceEntry {
  char name[SERVICENAMEMAXLEN];
  pid_t pid;
  procList_t * clients;
};

static uint32_t lastInsertedEntry = 0;
static uint32_t numEntry = 0;

static struct serviceEntry servicesRegistry[MAXSERVICES];

void __OS_service_initServicesRegistry() {
  printk("Initializing services registry... ");
  kbzero(servicesRegistry, MAXSERVICES * sizeof(struct serviceEntry));
  printk("done.\n");
}

static void insertInProcList(uint32_t idx, pid_t pid) {
  procList_t * new;
  new = (procList_t*)kmalloc(sizeof(procList_t));
  new->pid = pid;
  new->next = servicesRegistry[idx].clients;
  servicesRegistry[idx].clients = new;
}

static int insertInClientProcList(uint32_t entry) {
  servicesTable_t * table;
  int idx = 0;
  table = (processTable[currProcess].processData)->servicesTable;
  while (!table[idx])
    idx++;
  table[idx] = entry;
  return idx;
}

void __OS_service_removeFromProcList(uint32_t idx, pid_t pid) {
  procList_t * runner, * prev;

  /* find the element */
  prev = NULL;
  runner = servicesRegistry[idx].clients;
  while (runner && (runner->pid != pid)) {
    prev = runner;
    runner = runner->next;
  }
  if (runner) {
    if (prev)
      prev->next = runner->next;
    else
      servicesRegistry[idx].clients = runner->next;
    kfree(runner);
  }
}


void __OS_service_deleteRegistryEntry(uint32_t entry) {
  procList_t * list = servicesRegistry[entry].clients;
  procList_t * tmp;
  while (list) {
    tmp = list;
    list = list->next;
    /* TODO: now we should update the processes service table */
    kfree(tmp);
  }
  kbzero(&(servicesRegistry[entry]), sizeof(struct serviceEntry));
  numEntry--;
}

static int findService(char * name) {
  uint32_t idx = 0;
  while (idx < MAXSERVICES) {
    if (!kmemcmp(servicesRegistry[idx].name, name,
		 MIN(kstrlen(name) + 1, SERVICENAMEMAXLEN)))
      break;
    idx++;
  }
  if (idx == MAXSERVICES) return -1;
  else return idx;
}

int __OS_service_registerService(char * name) {
  if (numEntry == MAXSERVICES) return -1;
  /* TODO: check on name */
  do {
    if (++lastInsertedEntry >= MAXSERVICES)
      lastInsertedEntry = 0;
  } while (servicesRegistry[lastInsertedEntry].pid != 0);

  numEntry++;
  servicesRegistry[lastInsertedEntry].pid = currProcess;
  kmemcpy(servicesRegistry[lastInsertedEntry].name, name, 
	  MIN(kstrlen(name) + 1, SERVICENAMEMAXLEN));
  printk("Service ");
  printk(name);
  printk(" registered\n");
  return 0;
}

int __OS_service_registerClient(char * name) {
  int entry;
  int clientEntry;

  /* TODO: check the name */
  if ((entry = findService(name)) == -1)
    return -1;

  if ((clientEntry = insertInClientProcList(entry)) == -1) return -1;
  insertInProcList(entry, currProcess);
  return clientEntry;
}
