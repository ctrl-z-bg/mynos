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
[BITS 16]
  ORG	0

	jmp	bootup
;  	nop

OEM_ID			db	"MyNOS-LD"
nBytesPerSect		dw	0x0200
nSectPerClstr		db	0x01
nRsvdSect		dw	0x0001
nFATS			db	0x02
nRootDirEnts		dw	0x00E0
nTotalSectors		dw	0x0B40
bMedia			db	0xF0
nSectPerFAT		dw	0x0009
nSectPerTrack		dw	0x0012
nHeads			dw	0x0002
nHidden			dd	0x00000000
nTotalSect32		dd	0x00000000
bBootDrive		db	0x00
ResvdByte		db	0x00
ExtBootSig		db	0x29
nOSSectors		dw	0xc8		; c8 = 100KB
ResvdWord		dw	0x0000
Volname			db	"QUASI  BOOT"
FatType			db	"FAT12   "

bootup:
	cli				;{0}

	;; enable A20
	xor	cx, cx
IBEmm0:
	in	al, 0x64
	test	al, 0x2
	loopnz	IBEmm0
	mov	al, 0xd1
	out	0x64, al
	xor	cx, cx
IBEmm1:
	in	al, 0x64
	test	al, 2
	loopnz	IBEmm1
	mov	al, 0xdf
	out	0x60, al
	xor	cx, cx
IBEmm2:
	in	al, 0x64
	test	al, 2
	loopnz	IBEmm2
	;; A20 enabled

	
	;; stack at 0x98000
	mov	ax, 0x9000
	mov	ss, ax
	mov	sp, 0x8000

	;; move this boot sector up to DestBootup segment
	mov	ax, DestBootup
	mov	es, ax
	xor	di, di
	mov	ax, 0x7c0
	mov	ds, ax
	xor	si, si
	mov	cx, 512
	rep	movsb
	jmp	DestBootup:newbootup		; jump to DestBootup

  	org 0x90000
newbootup:
	
	;; adjust segment registers
  	mov	ax, DestBootup
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	mov	sp, 0xFFFF

	;; BIOS stuff...
	mov	cx, [nSectPerTrack]
	xor	ax, ax
	mov	ds, ax
	mov	bx, 0x0078
	lds	si, [ds:bx]

	mov	BYTE [si+4], cl
	mov	BYTE [si+9], 0x0f

	push	es
	pop	ds
	push	ds

	mov	dl, [bBootDrive]
	xor	ax, ax

	int	0x13
	jc	BadBoot

	pop	ds

	;; the controller is reset
	mov	si, MsgLoad
	call	PutChars

	;; the 3rd cluster is really the first allocated because the first 2 
	;; are unused
	xor	ax, ax
	mov	al, [nFATS]
	mul	WORD [nSectPerFAT]
	add	ax, WORD [nHidden]
	adc	dx, WORD [nHidden+2]
	add	ax, [nRsvdSect]
	mov	cx, ax

	;; cx has a word that contains the sector of the Root
	mov	ax, 0x0020		; size of Dir Entry
	mul	WORD [nRootDirEnts]
	mov	bx, [nBytesPerSect]
	div	bx
	add	ax, cx

	mov	cx, [nOSSectors]
	jmp	ContinueBoot
	
BadBoot:	
	mov	si, MsgBadDisk
	call	PutChars

	xor	ax, ax
	int	0x16			; wait a key
	int	0x19			; reboot

PutChars:
	push	ax
	push	bx
.putchars:
	lodsb
	or	al, al
	jz	.done
	mov	ah, 0x0e
	mov	bx, 0x0007
	int	0x10
	jmp	.putchars
.done:
	pop	bx
	pop	ax
	retn

ContinueBoot:
	mov	bx, TempSeg		; where we load the OS before 0x0000
	mov	es, bx

NextSector:
	push	ax
	push	cx
	push	dx
	push	es
	xor	bx, bx			; es:bx points to sector read address

	;; read a logical sector to es:bx
	;; ax has logical sector number
	mov	si, [nSectPerTrack]
	div	si
	inc	dl			; sector numbering begins at 1
	mov	[ResvdByte], dl
	xor	dx, dx
	div	WORD [nHeads]
	mov	dh, [bBootDrive]
	xchg	dl, dh
	mov	cx, ax
	xchg	cl, ch
	shl	cl, 6
	or	cl, BYTE [ResvdByte]
	mov	al, 0x1
	mov	ah, 0x2
	int	0x13
	jc	BadBoot

	mov	si, MsgDot
	call	PutChars

	pop	es
	pop	dx
	pop	cx
	pop	ax

	mov	bx, es
	add	bx, 0x20
	mov	es, bx
	inc	ax
	loop	NextSector
	;; kernel loaded

	;; turn off floppy motor
;  	push	ds
;  	mov	ax, 0x40
;  	mov	ds, ax
;  	xor	cx, cx
;  	mov	cl, BYTE [40]
;  	cmp	cx, 0
;  	jz	motoroff
;  .stop_motor:
;  	int	8
;  	loop	.stop_motor
;  motoroff:
;  	pop	ds
	

	;; move the kernel to 0x0 linear
	;; I can do it only if interrupts are disabled

	;; how many segments are to be moved?
	mov	ax, [nOSSectors]
	mov	cx, 0x7F		; 0xffff / 0x200 = 0x7F
	div	cx
	mov	cx, ax
	inc	cx			; now cx has the number of segments
					; to move
	mov	ax, TempSeg
	mov	bx, DestSeg
	xor dx, dx
movek:
	inc dx
    	call	move64
	add	ax, 0x1000
	add	bx, 0x1000
  	loop	movek

	lgdt	[gdtinfo]
  	mov	eax, cr0
  	or	eax, 1
  	mov	cr0, eax
      	jmp	pmode1		;  jump to flush pipeline
pmode1:	
	mov	bx, (flat_data-gdt_table)
    	mov	ds, bx
      	mov	ss, bx
	add	esp, 0x90000
	mov	ebp, esp
  	jmp DWORD (flat_code-gdt_table):pmode2	; jump to initialize CS
[BITS 32]
pmode2:
	;; jump to kernel
	jmp	(flat_code-gdt_table):0x0
	
[BITS 16]

;;; move a segment (64KB)
;;; ax = Start; bx = Target
move64:
	push	si
	push	di
	push	ds
	push	es
	push	cx
	mov	cx, 0x8000		; 32K (x2 with the follow movsw)
	mov	ds, ax			; source segment
	mov	es, bx			; destination segment
	xor	si, si
	xor	di, di
	cld
	rep	movsw
	pop	cx
	pop	es
	pop	ds
	pop	di
	pop	si
	ret
	

;;; 
;;; GDT
;;; 
gdtinfo:
	dw      gdtlength
	dd      gdt_table
gdt_table:
  null_desc       desc    0,0,0
  flat_code       desc    0, 0xFFFFF, D_CODE + D_BIG + D_BIG_LIM
  user_code       desc    0, 0xFFFFF, D_CODE + D_READ + D_BIG + D_BIG_LIM
  flat_data       desc    0, 0xFFFFF, D_DATA + D_WRITE + D_BIG + D_BIG_LIM
gdtlength equ $ - gdt_table - 1

	
MsgBadDisk	db	0x0d, 0x0a, "Bad Disk!", 0x00
MsgLoad		db	0x0d, 0x0a, "Loading", 0x00
MsgDot		db	'.', 0x00

DestBootup	equ	0x9000		; boot sector will be moved here
TempSeg		equ	0x3000		; kernel will be loaded here
DestSeg		equ	0x0000		; kernel will be moved here

  	TIMES 510-($-$$) DB 0
	DW 0xAA55
