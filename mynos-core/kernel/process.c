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
#include "mem.h"
#include "gdt.h"
#include "tss.h"
#include "kutils.h"
#ifdef ELF
#include "elf.h"
#endif
#include "process.h"

tss_t processTable[MAXPROCESSES];
uint32_t numProcess = 1;
uint32_t currProcess = 0;  /* the first process is the idle process */

extern uint32_t * test_start;
extern uint32_t test_len;

tss_t * spawnProcess(tss_t * tss) {
  uint32_t * newPD;
  uint32_t * lastPT;
  uint32_t * lastButOnePT;
  uint32_t * currPT;
  uint32_t * currPF;        /* current page frame */
  uint32_t * stackFrame; 
  uint32_t i;
  ushort16_t tssd_gdt_sel, code_gdt_sel, data_gdt_sel;
  uint32_t npages_for_process;

#ifdef ELF
  Elf32_Phdr elf_phdata[ELF_MAXSEG];
  Elf32_Ehdr elf_ex;
  uint32_t entryaddr, curraddr, size, baseaddr;
  
  elf_ex=*(Elf32_Ehdr *)test_start;

  /* Used GRUB as inspiration */
  /* Check if is a good ELF for us */
  if (!BOOTABLE_I386_ELF(elf_ex))
      return(NULL);

  entryaddr = (uint32_t) elf_ex.e_entry;
  /* End check */
  
  /* Now read in all of the header information, after some consistency tests */
  if (elf_ex.e_phentsize != sizeof(Elf32_Phdr))
      return(NULL);
  if ( (elf_ex.e_phnum > ELF_MAXSEG) ||
       (elf_ex.e_phnum > (65536U / elf_ex.e_phentsize) ) )
      return(NULL);
  size = elf_ex.e_phnum * elf_ex.e_phentsize;
  kmemcpy(elf_phdata, test_start+elf_ex.e_phoff, size);
   
#endif
  npages_for_process = 32;

  if ((newPD = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  kbzero(newPD, PAGE_SIZE);

  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    newPD[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

  // HORRIBLE HACK!!! Open VGA memory to all processes!
#ifdef TRY_VGA
  {
    uint32_t * pte;
    uint32_t i;

    newPD[0] = newPD[0] | PF_USER | PF_READWRITE;
    for (i = 0xA0000; i<0xB0000; i+=0x1000) {
      pte = (int*)__GET_PAGE_TABLE_ENTRY(__ADDRESS_PD_INDEX(i), 
					 __ADDRESS_PT_INDEX(i));
      *pte = *pte | PF_USER | PF_READWRITE;
    }
  }
#endif

  if ((lastPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  kbzero(lastPT, PAGE_SIZE);

  if ((lastButOnePT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  kbzero(lastButOnePT, PAGE_SIZE);

  if ((currPT = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  kbzero(currPT, PAGE_SIZE);
  newPD[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_USER | PF_READWRITE | PF_PRESENT;

  if ((currPF = (uint32_t*)__OS_askPages(npages_for_process, 1, 0)) == NULL) return NULL;

  kbzero(currPF, npages_for_process * PAGE_SIZE);

  ///////////////
#ifdef ELF
  /* From here instead ELF code is Grub "inspired" */
  curraddr = (uint32_t) currPF;
  baseaddr = 0;

  for (i = 0; i < elf_ex.e_phnum; i++) {
      Elf32_Phdr *phdr;
      uint32_t memsz, filesz;
      ushort16_t control, sel, startaddr;
      
      phdr = (Elf32_Phdr *) ((char *)test_start + elf_ex.e_phoff +  (elf_ex.e_phentsize * i));
      /* we consider only the segments to be loaded*/
      if (phdr->p_type != PT_LOAD) continue; 
      startaddr = phdr->p_vaddr;
      if (baseaddr == 0) baseaddr=phdr->p_vaddr;
      memsz = phdr->p_memsz;
      filesz = phdr->p_filesz;
      curraddr = (uint32_t)currPF + ( phdr->p_vaddr - baseaddr );
      if (filesz > memsz) filesz = memsz; /* It should not occur (I think) */
      kmemcpy((void*)curraddr, (void*)((uint32_t)test_start + (uint32_t)(phdr->p_offset)), 
	      filesz);
      if (memsz > filesz) { /*We do not need that if we already zero'ed all the pages */
	  kbzero((void *)(curraddr + filesz), memsz-filesz);
      }
      sel = gdt_get_free_index();
      control = D_BIG + D_BIG_LIM + D_DPL3;
      if (phdr->p_flags & PF_X) {
	  code_gdt_sel = sel;
	  control += D_CODE;
      } else {
	  data_gdt_sel = sel;
	  control += D_DATA;
      }
      
      if (phdr->p_flags & PF_W) 
	  control += D_WRITE;
      gdt_set_entry(sel, 0x00000000, 0xFFFFF, control);

  }
  /* Here the segments are loaded, we have not symbol loading at the moment,
     neither relocatable segments. */
  
#else 
kmemcpy((void*)currPF, (void*)test_start, test_len); 
#endif

  /////////////////

  for (i = 0; i < npages_for_process; i++)
  currPT[i] = LINEAR_TO_PHYSICAL_ADDRESS(currPF +(1024*i)) 
    | PF_USER | PF_PRESENT | PF_READWRITE;
  printk("Set linear2phis addr....\n");
  /* alloc a third page (allocated only logically)
  if ((currPF = (uint32_t*)__OS_askPages(1, 0)) == NULL) return NULL;
  currPT[2] = PF_USER | PF_LOGICAL_PRESENT | PF_READWRITE; */

  newPD[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;
  newPD[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(lastButOnePT) | PF_USER | PF_READWRITE | PF_PRESENT;

  /* copy the first shared entries in the PTs images */
  /* to add to CVS!!! */
  for (i = 0; i <= _asm_last_kernel_page_dir_entry_used; i++)
    lastPT[i] = *((uint32_t*)__GET_PAGE_DIR_ENTRY(i));

    printk("Copied first shared entries....\n");
  lastPT[_asm_last_kernel_page_dir_entry_used + 1] = 
    LINEAR_TO_PHYSICAL_ADDRESS(currPT) | PF_PRESENT;
  lastPT[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(lastPT) | PF_PRESENT;
  lastPT[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(lastButOnePT) | PF_PRESENT;
  
  lastButOnePT[1024-1] = LINEAR_TO_PHYSICAL_ADDRESS(newPD) | PF_PRESENT;
  if ((stackFrame = (uint32_t*)__OS_askPages(1, 0, 0)) == NULL) return NULL;
  //  lastButOnePT[1024-2] = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_USER | PF_PRESENT | PF_READWRITE;
  lastButOnePT[1024-2] = PF_USER | PF_LOGICAL_PRESENT | PF_READWRITE;

  /* create new segments descriptors, if ELF is defined it has already been done. */
#ifndef ELF 
  code_gdt_sel = gdt_get_free_index();
  gdt_set_entry(code_gdt_sel, 
		0x00000000, 0xFFFFF, 
		(D_CODE + D_BIG + D_BIG_LIM + D_DPL3));
  data_gdt_sel = gdt_get_free_index();
  gdt_set_entry(data_gdt_sel, 
		0x00000000, 0xFFFFF, 
		(D_DATA + D_WRITE + D_BIG + D_BIG_LIM+ D_DPL3));
#endif
  tssd_gdt_sel = gdt_get_free_index();

  gdt_set_entry(tssd_gdt_sel, 
		LINEAR_TO_PHYSICAL_ADDRESS((uint32_t)tss),
		sizeof(tss_t), D_TSS);
    printk("GDT TSS entry....\n");
  /* set the new process tss */
  tss->pgdir = (uint32_t**)LINEAR_TO_PHYSICAL_ADDRESS(newPD);
  tss->io_bitmap_offset = 0;
  tss->eip = (uint32_t)0x40000000;

  tss->isAlive = 1;

  //#define LDT
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
    (uint32_t)((uint32_t)LAST_PAGE_DIR_VALID_INDEX*0x400000 - 4100);
  if ((stackFrame = (uint32_t*)__OS_askPages(1, 1, 0)) == NULL) return NULL;
  currPT[1023] = LINEAR_TO_PHYSICAL_ADDRESS(stackFrame) | PF_PRESENT;
  tss->esp0 = tss->esp1 = tss->esp2 = 0x40400000 - 1;//(uint32_t)stackFrame + 4095;
  tss->ss0 = tss->ss1 = tss->ss2 = GDT_OS_DATA_SEL;
  printk("SET TSS entry....\n");
#ifdef LDT
{
  union DT_entry * ldt;
  /* CREATE LDT */
  if ((ldt = (union DT_entry*)__OS_askPages(1, 0, 0)) == NULL) return NULL;

  gdt_set_entry(102, (uint32_t)ldt,
		4096, (D_LDT + D_BIG + D_DPL3));

  SEG_createStandardDescriptor((uint32_t*)(ldt+1), 0x00000000, 0xFFFFF, (D_CODE + D_BIG + D_BIG_LIM + D_DPL3));
  SEG_createStandardDescriptor((uint32_t*)(ldt+2), 0x00000000, 0xFFFFF, (D_DATA + D_WRITE + D_BIG + D_BIG_LIM+ D_DPL3));
}
#endif
  return tss;
}


void killProcess() {
  processTable[currProcess].isAlive = 0;
}
