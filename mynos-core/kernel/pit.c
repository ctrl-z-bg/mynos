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

#include "pit.h"
#include "idt.h"
#include "io.h"
#include "video.h"
#include "kutils.h"

void init_pit(float freq, unsigned char channel) {
  unsigned int temp;

  temp = PIT_INPUT_Hz/freq;
  outportb(PIT_CONTROL_WORD, (channel*0x40) + PIT_CW_RW_BOTH + PIT_CW_MODE3);
  outportb((0x40+channel), (unsigned char)temp);
  outportb((0x40+channel), (unsigned char)(temp>>8));
}

/* we can't use ISR_WRAPPER(pit) because it send EOI to pic, but we have to
   do it inside pit_handler, so we write a special (minimal) pit_ISR */
void pit_ISR();
__asm__ (\
	 ".globl pit_ISR         \n"\
	 "pit_ISR:               \n"\
	 "   pushal              \n"\
	 "   call pit_handler    \n"     /* call the ISR handler */\
	 "   popal               \n"\
	 "   iret                \n"\
	 );

#include "tss.h"
#include "process.h"
void pit_handler() {
  static uint32_t count = 1;
  uint32_t p_ts_time = 0;
  struct {long a ,b;} tmp = {0, 0};
  uint32_t oldProcess = currProcess;
  pid_t isForking;

  asm("int $0x1C"); /* Extra timer interrupt, 
		       used by floppy for timeout etc.. */

  /* a task switch any 55 msec */
  if ((count++) > 1) {
    p_ts_time = 1;
    count = 1;
    do {
      currProcess = (currProcess + 1) % numProcess;
    }
#ifdef IPC
    while ((!processTable[currProcess].isAlive) ||
	   (processTable[currProcess].isWaitingReceiver != -1) ||
	   (processTable[currProcess].isWaitingSender != -1));
#else
    while (!processTable[currProcess].isAlive);
#endif
    tmp.b = (long)processTable[currProcess].tssd_gdt_selector;
  }

  outportb(0x20, 0x20);

  /* terminate a forking action */
  if ((isForking = processTable[currProcess].isForking) != 0) {
    uint32_t** pgdir = processTable[isForking].pgdir;
    ushort16_t tssd = processTable[isForking].tssd_gdt_selector;
    kmemcpy((void*)&processTable[isForking], (void*)&processTable[currProcess],
	    sizeof(tss_t));
    processTable[isForking].pgdir = pgdir;
    processTable[isForking].tssd_gdt_selector = tssd;
    processTable[isForking].pid = isForking;
    processTable[isForking].ppid = currProcess;
    processTable[isForking].isForking = 0;
    processTable[isForking].isAlive = 1;
#ifdef IPC
    processTable[isForking].isWaitingSender = -1;
    processTable[isForking].isWaitingReceiver = -1;
    __OS_ipc_initChannelList(&(processTable[isForking].channels));
#endif
  }
  
  if (p_ts_time && (currProcess != oldProcess))
    __asm__ volatile ("ljmp *%0\n"::"m"(tmp.a));
}
