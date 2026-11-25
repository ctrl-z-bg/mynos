; MyNOS on x86-64 (doc/decisions/x86-64.md): the first instructions.
;
; GRUB and QEMU start a multiboot kernel in 32-bit protected mode, paging
; off. Here, still in 32 bits: the first page tables, PAE, long mode,
; paging; then a jump to 64-bit code and to C.
;
; The first page tables (at fixed physical addresses, as on the i386):
;   0x100000  PML4: entry 0 the low 1 GB, entry 256 the direct map
;   0x101000  PDPT of the low half: entry 0 -> 0x102000
;   0x102000  PD: the first 1 GB, identity-mapped in 2 MB pages (the
;             kernel at 2 MB, as on the i386)
;   0x103000  PDPT of the direct map (0xFFFF800000000000): 4 entries
;   0x104000  4 PDs: the first 4 GB of physical memory, in 2 MB pages

[BITS 32]
section .text.boot
extern arch_start64
global _start

MB_MAGIC equ 0x1BADB002
MB_FLAGS equ 3                   ; pages aligned, memory information
align 4
	dd MB_MAGIC, MB_FLAGS, -(MB_MAGIC + MB_FLAGS)

PML4      equ 0x100000
PDPT_LOW  equ 0x101000
PD_LOW    equ 0x102000
PDPT_HIGH equ 0x103000
PD_HIGH   equ 0x104000          ; four of them
PRESENT_RW equ 3
HUGE      equ 0x80              ; a 2 MB page

_start:
	cli
	mov	esp, boot_stack_top
	mov	esi, ebx                ; the multiboot information
	mov	edi, eax                ; its magic

	; clear the tables: 8 pages
	push	edi
	mov	edi, PML4
	mov	ecx, 8 * 1024
	xor	eax, eax
	rep stosd
	pop	edi

	mov	dword [PML4], PDPT_LOW | PRESENT_RW
	mov	dword [PML4 + 256 * 8], PDPT_HIGH | PRESENT_RW
	mov	dword [PDPT_LOW], PD_LOW | PRESENT_RW

	; the low 1 GB, identity
	mov	ecx, 0
.low:	mov	eax, ecx
	shl	eax, 21
	or	eax, PRESENT_RW | HUGE
	mov	[PD_LOW + ecx * 8], eax
	inc	ecx
	cmp	ecx, 512
	jne	.low

	; the direct map: 4 PDPT entries, 4 x 512 pages of 2 MB
	mov	ecx, 0
.pdpt:	mov	eax, ecx
	shl	eax, 12
	add	eax, PD_HIGH | PRESENT_RW
	mov	[PDPT_HIGH + ecx * 8], eax
	inc	ecx
	cmp	ecx, 4
	jne	.pdpt
	mov	ecx, 0
.high:	mov	eax, ecx                ; page number, in 2 MB
	shl	eax, 21
	or	eax, PRESENT_RW | HUGE
	mov	[PD_HIGH + ecx * 8], eax
	mov	eax, ecx                ; the high half of the address
	shr	eax, 11
	mov	[PD_HIGH + ecx * 8 + 4], eax
	inc	ecx
	cmp	ecx, 2048
	jne	.high

	mov	eax, cr4
	or	eax, 1 << 5             ; PAE
	mov	cr4, eax
	mov	eax, PML4
	mov	cr3, eax
	mov	ecx, 0xC0000080         ; EFER
	rdmsr
	or	eax, 1 << 8             ; long mode
	wrmsr
	mov	eax, cr0
	or	eax, (1 << 31) | 1      ; paging, protection
	mov	cr0, eax

	lgdt	[gdt64_ptr]
	jmp	0x08:long_mode

[BITS 64]
long_mode:
	mov	ax, 0x10
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	xor	ax, ax
	mov	fs, ax
	mov	gs, ax
	mov	rsp, boot_stack_top
	; arch_start64(magic, multiboot information)
	mov	edi, edi
	mov	esi, esi
	call	arch_start64
.halt:	cli
	hlt
	jmp	.halt

section .data
align 16
gdt64:
	dq 0
	dq 0x00AF9A000000FFFF           ; kernel code, 64 bits
	dq 0x00CF92000000FFFF           ; kernel data
gdt64_ptr:
	dw $ - gdt64 - 1
	dd gdt64

section .bss
align 16
boot_stack:
	resb 16384
boot_stack_top:
