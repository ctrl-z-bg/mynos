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

#include "mem.h"
#include "gdt.h"
#include "tss.h"
#include "kutils.h"

#define MAXPROCESSES 30

tss_t processTable[MAXPROCESSES];
uint32_t numProcess = 1;
uint32_t currProcess = 0;  /* the first process is the idle process */

tss_t * spawnProcess(tss_t * tss) {
  uint32_t * newPD;
  uint32_t * lastPT;
  uint32_t * lastButOnePT;
  uint32_t * currPT;
  uint32_t * currPF;        /* current page frame */
  uint32_t * stackFrame; 
  uint32_t i;
  ushort16_t tssd_gdt_sel, code_gdt_sel, data_gdt_sel;

  if ((newPD = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;
  kbzero(newPD, PAGE_SIZE);

  for (i = 0; i <= 255/*_asm_last_page_dir_entry_used*/; i++)
    newPD[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  if ((lastPT = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;
  kbzero(lastPT, PAGE_SIZE);

  if ((lastButOnePT = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;
  kbzero(lastButOnePT, PAGE_SIZE);

  if ((currPT = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;
  kbzero(currPT, PAGE_SIZE);
  newPD[256]=//_asm_last_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_USER | PF_READWRITE | PF_PRESENT;

  if ((currPF = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;

  ///////////////
  kmemcpy((void*)currPF, (void*)0x208000, 4096);
  /////////////////

  currPT[0] = LINEAR_TO_PHYSICAL_ADDRESS(currPF) | PF_USER | PF_PRESENT |
    PF_READWRITE;
  newPD[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;
  newPD[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(lastButOnePT) | PF_USER | PF_READWRITE | PF_PRESENT;
  
  lastPT[0] = LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_PRESENT;
  lastPT[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;
  lastPT[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(lastButOnePT) | PF_PRESENT;
  
  lastButOnePT[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(newPD) | PF_PRESENT;
  if ((stackFrame = (uint32_t*)__OS_askPages(1)) == NULL) return NULL;
  lastButOnePT[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_USER | PF_PRESENT | PF_READWRITE;

  /* create new segments descriptors */
  code_gdt_sel = gdt_get_free_index();
  gdt_set_entry(code_gdt_sel, 
		0x00000000, 0xFFFFF, 
		(D_CODE + D_BIG + D_BIG_LIM + D_DPL3));
  data_gdt_sel = gdt_get_free_index();
  gdt_set_entry(data_gdt_sel, 
		0x00000000, 0xFFFFF, 
		(D_DATA + D_WRITE + D_BIG + D_BIG_LIM+ D_DPL3));
  tssd_gdt_sel = gdt_get_free_index();
  gdt_set_entry(tssd_gdt_sel, 
		LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)tss),
		sizeof(tss_t), D_TSS);

  /* set the new process tss */
  tss->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(newPD);
  tss->io_bitmap_offset = 0;
  tss->eip = (uint32_t)0x40000000;

#define LDT
#ifdef LDT
  tss->cs = 0x8 * 1 + 7;
  tss->ds = 0x8 * 2 + 7;
  tss->es = 0x8 * 2 + 7;
  tss->fs = 0x8 * 2 + 7;
  tss->gs = 0x8 * 2 + 7;
  tss->ss = 0x8 * 2 + 7;
#else
  tss->cs = (((uint32_t)code_gdt_sel)<<3) + 3;
  tss->ds = (((uint32_t)data_gdt_sel)<<3) + 3;
  tss->es = (((uint32_t)data_gdt_sel)<<3) + 3;
  tss->fs = (((uint32_t)data_gdt_sel)<<3) + 3;
  tss->gs = (((uint32_t)data_gdt_sel)<<3) + 3;
  tss->ss = (((uint32_t)data_gdt_sel)<<3) + 3;
#endif

  tss->tssd_gdt_selector = tssd_gdt_sel << 3;

#ifdef LDT
  tss->ldt = 102 * 0x8;
#else
  tss->ldt = 0;
#endif

  tss->eflags = 0x200;
  tss->esp = tss->ebp =
    (uint32_t)((_asm_last_page_dir_entry_used)*0x400000 - 4100);
  tss->esp0 = tss->esp - numProcess*100;//1000;
  tss->esp1 = tss->esp - 1000;
  tss->esp2 = tss->esp - 1000;
  tss->ss0 = tss->ss1 = tss->ss2 = GDT_OS_DATA_SEL;

#ifdef LDT
{
  union DT_entry * ldt;
  /* CREATE LDT */
  if ((ldt = (union DT_entry*)__OS_askPages(1)) == NULL) return NULL;

  gdt_set_entry(102, (uint32_t)ldt,
		4096, (D_LDT + D_BIG + D_DPL3));

  SEG_createStandardDescriptor((uint32_t*)(ldt+1), 0x00000000, 0xFFFFF, (D_CODE + D_BIG + D_BIG_LIM + D_DPL3));
  SEG_createStandardDescriptor((uint32_t*)(ldt+2), 0x00000000, 0xFFFFF, (D_DATA + D_WRITE + D_BIG + D_BIG_LIM+ D_DPL3));
}
#endif

  return NULL;
}


