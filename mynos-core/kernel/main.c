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
#include "main.h"
#include "gdt.h"
#include "io.h"
#include "mem/mem.h"
#include "pic.h"
#include "pit.h"
#include "time.h"
#include "random.h"
#include "idt.h"

#include "tss.h"
#include "process.h"
#include "sched.h"

#include "mem/dynalloc.h"

#include "sem.h"

#include "kutils.h"

#include "services.h"

#include "delay.h"

#include "multiboot.h"

#ifdef TRY_VGA
#include "vga.h"
#endif

#include "ipc/ipc.h"
#include "softtaskswitch.h"

void __print_free_phy_pages() {
  printk("(adesso ci sono ");
  print_uint(__number_of_free_physical_pages);
  printk(" pagine fisiche non allocate)\n\n");
}

extern void softReset();

extern process_descriptor_t * processTable[];
extern uint32_t numProcess;
ushort16_t * idle_tssd_selector;

tss_t THEtss;

void tsksw() {
  ushort16_t gdt_index, tssd_gdt_selector;

  /* allocate a new tss */
  processTable[0] = 
    (process_descriptor_t*)kmalloc(sizeof(process_descriptor_t));
  processTable[0]->tss = (tss_t*)kmalloc(sizeof(tss_t));
  kmemcpy(processTable[0]->name, "kernel", 7);
  processTable[0]->faultsAlloc = processTable[0]->faultsCow = 0;
  kbzero(processTable[0]->childWaiting, sizeof processTable[0]->childWaiting);
  processTable[0]->tss->tls_base = 0;
  processTable[0]->tss->tls_limit = 0;
  processTable[0]->tss->tls_pages = 0;

  /* set a tss for the outcoming process */
  processTable[0]->tss->pgdir = (uint32_t**)0x100000;
  processTable[0]->tss->io_bitmap_offset = sizeof(tss_t)<<16;
  processTable[0]->tss->ldt = 0;
  processTable[0]->isAlive = 1;
  processTable[0]->tss->justForked = 0;

  processTable[0]->numThreads = 1;
  (processTable[0]->tss)->next = (processTable[0]->tss)->prev = NULL;
  processTable[0]->pid = 0;
  processTable[0]->tss->pid = 0;
  processTable[0]->tss->tid = 0;
  processTable[0]->tss->clearTid = NULL;
  processTable[0]->tss->kstack = 0;

  processTable[0]->tss->timeToWake = 0;

  processTable[0]->tss->cs = GDT_OS_CODE_SEL;
  processTable[0]->tss->ss0 = GDT_OS_DATA_SEL;

  currThread = processTable[0]->tss;

  // insert the thread into readyQueue
  readyQueueInsert(currThread);

  //SEM
  processTable[0]->tss->privSem = __OS_sem_allocateSemaphore(0);
  processTable[0]->tss->semHeld = 0;

  gdt_index = gdt_get_free_index();
  tssd_gdt_selector = (uint32_t)gdt_index << 3;

  kmemcpy(&THEtss, processTable[0]->tss, sizeof(tss_t));

  /* set the tssd in the gdt, for the incoming and the outcoming processes */
  gdt_set_entry(gdt_index,
		(uint32_t)(&THEtss),
		sizeof(tss_t), D_TSS);

  /* load the task register with the relative address in the gdt of the
     current process's tssd */
  idle_tssd_selector = (ushort16_t*)((uint32_t)tssd_gdt_selector);
  __asm__ volatile ("ltrw (idle_tssd_selector)\n");

}

#ifdef RAMDISK
void * ramdisk;
uint32_t ramdisk_len;
uint32_t ramdisk_present = 0;
#endif

modinfo_t bytecode;

/* used in soft reset to restore the original multiboot data */
//multiboot_info_t * boot_info_global;

/* the kernel command line (multiboot), copied before memory is set up */
static char kernel_cmdline[256];

/* the modules' command lines ("path arg1 arg2...", as GRUB's module
   line or QEMU's -initrd entry): their argv */
#define MODULE_CMDLINE 256
#define MODULE_MAXARGS 16
static char module_cmdline[MAXMODULES][MODULE_CMDLINE];
static char module_cut[MAXMODULES];
static char * module_argv[MAXMODULES][MODULE_MAXARGS + 1];

/* split module i's command line in place into its argv */
static char ** module_args(int i) {
  char * s = module_cmdline[i];
  int n = 0;
  while (*s && n < MODULE_MAXARGS) {
    while (*s == ' ') *s++ = 0;
    if (!*s) break;
    module_argv[i][n++] = s;
    while (*s && *s != ' ') s++;
  }
  *s = 0;
  module_argv[i][n] = NULL;
  return n ? module_argv[i] : NULL;   /* NULL: the default argv */
}

/* does the kernel command line contain this word? */
static int cmdline_has(const char * word) {
  int n = kstrlen(word), i, j;
  for (i = 0; kernel_cmdline[i]; i++) {
    for (j = 0; j < n && kernel_cmdline[i + j] == word[j]; j++) ;
    if (j == n && (i == 0 || kernel_cmdline[i - 1] == ' ') &&
	(kernel_cmdline[i + n] == ' ' || kernel_cmdline[i + n] == 0))
      return 1;
  }
  return 0;
}

void mynos_main(multiboot_info_t *boot_info) {
  module_t * module;
  modinfo_t modinfo[MAXMODULES];
  int i;
  int nmodules;

  arch_irq_disable();

  /* initialize the FPU, and record its clean state for new threads */
  arch_fpu_reset();
  fpu_init();

  /* prepare the modules informations */
  /* NB: I do that right now because the memory bitmap allocation can
     reset the grub information
  */
  if (boot_info->flags & 0x4) {         /* a command line */
    char * s = (char *)boot_info->cmdline;
    for (i = 0; s[i] && i < (int)sizeof(kernel_cmdline) - 1; i++)
      kernel_cmdline[i] = s[i];
    kernel_cmdline[i] = 0;
  }
  module = (module_t *)boot_info->mods_addr;
  nmodules = boot_info->mods_count;
  /* the bootloader's structures, read after init_memory: no DMA area
     (mem.c) on them */
  mem_reserveAtBoot((uint32_t)boot_info, sizeof(multiboot_info_t));
  mem_reserveAtBoot((uint32_t)module, nmodules * sizeof(module_t));
  for (i = 0; i < boot_info->mods_count; i++) {
    modinfo[i].start = (uint32_t*)module[i].mod_start;
    modinfo[i].len = module[i].mod_end - module[i].mod_start;
    mem_reserveAtBoot(module[i].mod_start, modinfo[i].len);
    if (module[i].string)
      mem_reserveAtBoot(module[i].string, MODULE_CMDLINE);
    if (i < MAXMODULES && module[i].string) {
      char * s = (char *)module[i].string;
      int j;
      for (j = 0; s[j] && j < MODULE_CMDLINE - 1; j++)
	module_cmdline[i][j] = s[j];
      module_cmdline[i][j] = 0;
      module_cut[i] = s[j] != 0;          /* said at start, not in silence */
    }
  }


  //boot_info_global = boot_info;

  clear_screen();
  video_font_init();
  printk("Welcome to MyNOS - v" MYNOS_VERSION "\n\n");

  init_memory();

#ifdef RAMDISK
  /* modules above 4MB are readable only after init_memory has mapped them */
  for (i = 0; i < nmodules; i++)
    if (!kmemcmp((uint32_t*)modinfo[i].start, ".RAMDISK", 8)) {
      ramdisk = (void *)modinfo[i].start;
      ramdisk_len = modinfo[i].len;
      ramdisk_present = i;
    }
#endif

  initProcessTable();
  initScheduler();

  printk("Initializing the 8259 Programmable Interrupt Controller... ");
  init_pics();
  printk("done.\n");

  printk("Loading Interrupt Descriptor Table... ");
  init_idt();
  printk("done.\n");

  calibratingDelayLoop();

  printk("Physical Memory : ");
  print_uint(_asm_global_mem_size);
  printk(" MB\n");

  print_uint(__memory_bitmap_size);
  printk(" bytes allocated for memory map\n");

  printk("Initializing the Intel 8253 Programmable Interval Timer... ");
  init_pit(PIT_FREQ, 0);
  set_vector(pit_ISR, M_VEC, (D_INT + D_PRESENT));
  printk("done.\n");
  time_init();
  random_init();
  __OS_sem_initSemaphores();

  __OS_service_initServicesRegistry();

#ifdef RAMDISK
  if (!ramdisk_present)
    printk("No RAMDISK found\n");
  else {
    printk("RAMDISK found (module ");
    print_uint(ramdisk_present);
    printk(")\n");
  }
#endif

  /* prepare the test program information */
  //test_start = modinfo[0].start;
  //test_len = modinfo[0].len;
  bytecode.start = modinfo[1].start;
  bytecode.len = modinfo[1].len;


#ifdef TRY_VGA
  init_graph_vga(320, 200, 1);
#endif
#if 0
  {
    int y;
    for (y = 0; y < 200; y++)
      vga_draw_line(0, y, 319, y, 0);
  }

  vga_draw_rect(0,0,319,199, 15);
  vga_draw_rect(50, 20, 80, 50, 15);
  vga_draw_rect(100, 20, 130, 50, 15);
  vga_draw_line(90, 50, 90, 150, 15);
  vga_draw_line(60, 170, 120, 170, 15);
  vga_draw_line(50, 160, 60, 170, 15);
  vga_draw_line(120, 170, 130, 160, 15);
#endif

  {
    int i;
    
    for (i = 0; i < MAXPROCESSES; i++)
      if (processTable[i])
	processTable[i]->isAlive = 0;
  }

  /* to try the releasePages */
#if 0
  printk("free pages: ");
  print_uint(__number_of_free_physical_pages);
  print_char('\n');
  {
    uint32_t * pun;
    pun = __OS_askPagesFrom((void*)0x1000000,1,0,0);
    *pun = 5;
    printk("free pages: ");
    print_uint(__number_of_free_physical_pages);
    print_char('\n');
    print_uint_hex(pun);
    print_char('\n');
    print_uint(*pun);
    print_char('\n');
    __OS_releasePages((void*)0x1000000, 1, 1, 0);
    printk("free pages: ");
    print_uint(__number_of_free_physical_pages);
    print_char('\n');
    *pun = 5;
    print_char('\n');
    print_uint_hex(pun);
    print_char('\n');
    print_uint(*pun);
    while(1);
  }
#endif

  /* (a 2004 debug print showed here whether the boot loader passed VBE
     graphics information, as SIIII... or NOOOO...) */


  /* CR0.WP: from now on the kernel's own writes respect read-only pages,
     so that a system call writing into a copy-on-write page copies it
     first (mynos-bvz) */
  arch_write_protect_kernel();
  tsksw();

  /* start the elf modules */
  {
    uint32_t i;
    //for (i = 0; i < boot_info->mods_count; i++) {
    for (i = 0; i < nmodules; i++) {
      //module = (module_t*)((uint32_t*)(boot_info->mods_addr) + i);
      modinfo[i].start = (uint32_t*)module[i].mod_start;
      modinfo[i].len = module[i].mod_end - module[i].mod_start;
      if (i < MAXMODULES && module_cut[i]) {
	printk("module command line cut at ");
	print_uint(MODULE_CMDLINE - 1);
	printk(" characters: ");
	printk(module_cmdline[i]);
	print_char('\n');
      }
      if ((*((char*)modinfo[i].start) == 0x7F) &&
	  !kmemcmp((char*)modinfo[i].start + 1, "ELF", 3)) {
	if (createProcess(modinfo[i].start, modinfo[i].len,
			  i < MAXMODULES ? module_args(i) : NULL, NULL, 0,
			  MYNOS_PRIV_IO) < 0)
	  printk("module is not a valid MyNOS program\n");
      }
    }
  }

  initIPC();

  printk("\n-----------------------\n");

  /* from now on the screen belongs to the programs: kernel messages go to
     the log port only (tools/run-tests.sh reads it), unless "verbose" */
  if (!cmdline_has("verbose"))
    kernel_on_screen = 0;


#if 0
  /* testing the external mem  */
  {
    uint32_t * a = __OS_askPages(1, 0, PF_READWRITE | PF_USER);
    *a = 56;
    __OS_mapPagesTo(1, ((uint32_t)a)>>12, 1, 0);
    //__OS_mapPagesTo(1, ((uint32_t)a)>>12, 1, 0);

    enable_irq(0);
    
    while(1) {
      int i;
      for (i = 0; i < 300000; i++);
      print_uint(*a);printk("\n");
    }
  }
#else
  enable_irq(0);
#endif

#ifdef RAMDISK
  if (ramdisk_present) {
    //uint32_t ramdisk = 0x40400000;
    //__OS_ipc_send(1, (char*)&ramdisk, sizeof(uint32_t), 1);
  }
#endif

  // this is the idle process: wait for the next interrupt
  while(1) {
    arch_wait_interrupt();
    //printk("idle\n");
#if 0
    // to try the softReset
    static int first = 1;
    delay(5000);
    if (first) {first = 0; softReset(); }
#endif

#if 0
    char a = getch();
    print_char(a);
    outportb(0x3F8, a);
#ifdef TRY_VGA
    switch (a) {
    case 'l': a = -1; break;
    case 'j': a = -2; break;
    case 'k': a = -3; break;
    case 'i': a = -4; break;
    case '1': a = -5; break;
    default: break;
    }
      
    __OS_ipc_send(1, &a, 1, 1);
#endif // TRY_VGA
#endif
  }

  KPANIC("\nEND OF KERNEL DEMO");
}

void calibratingDelayLoop() {
  ulong32_t delaycount = 0;

  printk("Calibrating delay loop... [");
  delaycount = calibrateDelayLoop();
  print_ulong(delaycount);
  printk("]\n");
}
