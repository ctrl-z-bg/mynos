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

%include "gdtnasm.inc"
	org 0x00000
[BITS 32]

	cli

  	lgdt	[gdtinfo]
	mov	esi, pmodemsg
	call	print
	call	newline
	mov	edx, 0
	mov	al, 5
	mov	BYTE [0x1000000], al	; 1000000h = 10MB
	mov	dl, BYTE [0x1000000]

myloop:	jmp	myloop


;;; 
;;; GDT
;;; 
gdtinfo:
	dw      gdtlength
	dd      gdt_table
gdt_table:
  null_desc       desc    0,0,0
  flat_code       desc    0, 0xFFFFF, D_CODE + D_READ + D_BIG + D_BIG_LIM
  flat_data       desc    0, 0xFFFFF, D_DATA + D_WRITE + D_BIG + D_BIG_LIM
gdtlength equ $ - gdt_table - 1

start_cursor	equ	0xB88c0
cursor:		dd	start_cursor

;;; Messages
pmodemsg:	db	"Kernel switched in protected mode", 0

	
;;; 
;;; printing functions
;;; 
	;; esi has the linear address of string
print:
	push	esi
	push	edi
	push	eax
	mov	edi, [cursor]
.rep:	mov	BYTE al, [esi]
	cmp	al, 0
	jz	.prend
	mov	BYTE [edi], al
	mov	BYTE [edi+1], 0x7
	inc	esi
	add	edi, 2
  	jmp	.rep

.prend:	
	mov	[cursor], edi
	pop	eax
	pop	edi
	pop	esi
	ret

newline:
	push	edx
	push	eax
	push	ecx
	mov	ecx, 0xA0
	mov	eax, [cursor]
	sub	eax, start_cursor
	xor	edx, edx
	div	ecx
	mul	ecx
  	add	eax, ecx
	add	eax, start_cursor
	mov	[cursor], eax
	pop	ecx
	pop	eax
	pop	edx
	ret	

kernel_len	equ	($-$$)
