;  MyNOS
;  Copyright (C) 2002
;  MyNOS team (http://sourceforge.net/projects/mynos/)
;
;  This program is free software; you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation; either version 2 of the License, or
;  (at your option) any later version.
;
;  This program is distributed in the hope that it will be useful,
;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;  GNU General Public License for more details.
;
;  You should have received a copy of the GNU General Public License
;  along with this program; if not, write to the Free Software
;  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

[BITS 32]			; this isn't DOS! ;-)
extern mynos_main		; the real main is not in this file


;;; the bottom of each process linear memory will be aliased with
;;; kernel linear memory. This is the last index used in page directory
%define	KLAST_PAGE_DIR_ENTRY_USED	255	; 255 = 1GB
	
;;; last linear page frame will be mapped here
%define KERNEL_PAGE_DIR			0x100000

;;; some statically allocated page tables
%define KERNEL_FIRST_PAGE_TABLE		0x101000
%define KERNEL_LAST_BUT_ONE_PAGE_TABLE	0x102000
%define KERNEL_LAST_PAGE_TABLE		0x103000	; reserved to map
							; page tables

;;; some statically allocated page frames
%define KERNEL_STACK_PAGE		0x104000

%define KERNEL_FIRST_FREE_PHY_PAGE	0x105000

;;; flags in page table entries
%define FLAG_PAGE_PRESENT		0x1

%define FOUR_K				0x1000
%define ONE_M				0x100000

;;; SOME USEFULL MACROS
;;; this macro calculate the linear address of a table entry
%define PTABLE_ENTRY(base, index)	(base) + (index)*4

;;; this macro puts a new entry in the page directory
%macro NEW_ENTRY_IN_PAGE_DIR 2	; (index, page address)
  	mov	eax, %2
  	or	eax, FLAG_PAGE_PRESENT
	mov	edi, PTABLE_ENTRY(KERNEL_PAGE_DIR, %1)
  	mov	[edi], eax
%endmacro

;;; LET'S START!
global	_start
_start:

;;; now we calculate the amount of RAM you have by a read-back test
;;; the result, in eax, is in MB
	mov	ebx, 0x1FFFFC	; last DWORD of the second MB
	xor	eax, eax	; the counter
.count:	
	mov	ecx, 0x12345678	; test number
	mov	DWORD [ebx], 0
	mov	[ebx], ecx	; write the test number in memory
	xor	ecx, ecx
	mov	ecx, [ebx]	; read the test number from memory
	add	ebx, ONE_M
	add	eax, 1
	cmp	ecx, 0x12345678	; test if the test number was really there
	jz	.count
	mov	[_asm_global_mem_size], eax

;;; ENABLE PAGING
;  We put the page directory at 0x100000 (1MB). 

	;; let's clear the first page table and some page tables
	mov	edi, KERNEL_PAGE_DIR
	call	clear_page_table
	mov	edi, KERNEL_FIRST_PAGE_TABLE
	call	clear_page_table
	mov	edi, KERNEL_LAST_BUT_ONE_PAGE_TABLE
	call	clear_page_table
	mov	edi, KERNEL_LAST_PAGE_TABLE
	call	clear_page_table

	;; let's bind the page directory with the page tables
	NEW_ENTRY_IN_PAGE_DIR 0, KERNEL_FIRST_PAGE_TABLE
  	NEW_ENTRY_IN_PAGE_DIR (KLAST_PAGE_DIR_ENTRY_USED-1), KERNEL_LAST_BUT_ONE_PAGE_TABLE
	NEW_ENTRY_IN_PAGE_DIR KLAST_PAGE_DIR_ENTRY_USED, KERNEL_LAST_PAGE_TABLE

	;; we want to have the page directory and the page tables to be
	;; mapped in our linear space:
	;; - the last linear page table is reserved to map all page tables
	;; - the last entry in the last but one page table map the page dir
	;; - the last but one entry in the last but one page table is where
	;;   we put the stack
	
	;; we now map the page directory...
	mov	eax, PTABLE_ENTRY(KERNEL_LAST_BUT_ONE_PAGE_TABLE, 1023)
	mov	ebx, KERNEL_PAGE_DIR
	or	ebx, FLAG_PAGE_PRESENT
	mov	[eax], ebx

	;; ...now the the first page table...
	mov	eax, PTABLE_ENTRY(KERNEL_LAST_PAGE_TABLE, 0)
	mov	ebx, KERNEL_FIRST_PAGE_TABLE
	or	ebx, FLAG_PAGE_PRESENT
	mov	[eax], ebx
	
	;; ...then the last but one page table...
	mov	eax, PTABLE_ENTRY(KERNEL_LAST_PAGE_TABLE, (KLAST_PAGE_DIR_ENTRY_USED - 1))
	mov	ebx, KERNEL_LAST_BUT_ONE_PAGE_TABLE
	or	ebx, FLAG_PAGE_PRESENT
	mov	[eax], ebx
	
	;; ...and finally the last page table
	mov	eax, PTABLE_ENTRY(KERNEL_LAST_PAGE_TABLE, KLAST_PAGE_DIR_ENTRY_USED)
	mov	ebx, KERNEL_LAST_PAGE_TABLE
	or	ebx, FLAG_PAGE_PRESENT
	mov	[eax], ebx
	
	;; set the first 256 entry of the first page table
	;; to map the first MB of physical ram
	mov	ecx, 256
	mov	eax, 0x1
	mov	edi, KERNEL_FIRST_PAGE_TABLE
.load_pt:	
	mov	[edi], eax
	add	eax, FOUR_K
	add	edi, 4
	loop	.load_pt

	;; let the stack point to KERNEL_STACK_PAGE
	mov	eax, PTABLE_ENTRY(KERNEL_LAST_BUT_ONE_PAGE_TABLE, 1022)
	mov	ebx, KERNEL_STACK_PAGE
	or	ebx, FLAG_PAGE_PRESENT
	mov	[eax], ebx

	mov	eax, KLAST_PAGE_DIR_ENTRY_USED
	mov	ebx, 0x400000	; 4MB
	mul	ebx
	sub	eax, FOUR_K
	dec	eax

	;; linear address of stack is the page before the page dir linear page
  	mov	esp, eax
  	mov	ebp, esp
	
	;; move the page dir physical address in cr3
	mov	ebx, KERNEL_PAGE_DIR
	mov	cr3, ebx

	;; enable PG in cr0
  	mov	eax, cr0
  	or	eax, 0x80000000
  	mov	cr0, eax
;;; END OF PAGING CODE
	
;;; jump to main!!!
	call	mynos_main





;;; set all entries to not present. edi must have the page address
clear_page_table:
	add	edi, 3		; last byte of the first entry
	mov	ecx, 1024
.loop:	
	mov	BYTE [edi], 0
	add	edi, 4		; next entry
	loop	.loop
	ret


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;             GLOBAL SYMBOLS                  ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; amount of ram
global				_asm_global_mem_size
_asm_global_mem_size:		dd	0

global				_asm_last_page_dir_entry_used
_asm_last_page_dir_entry_used:	dd	KLAST_PAGE_DIR_ENTRY_USED

global				_asm_first_free_physical_page_address
_asm_first_free_physical_page_address:	dd	KERNEL_FIRST_FREE_PHY_PAGE
