; MyNOS on x86-64: the other processors' first instructions
; (doc/decisions/smp.md). smp.c copies this code to TRAMP (below 1 MB),
; fills its data (the kernel's page tables, EFER, a stack, the C entry
; and its argument) and sends INIT and STARTUP to a processor, which
; starts here in real mode at TRAMP: protected mode, long mode with the
; kernel's tables (they map low memory at the same addresses), then C.

TRAMP	equ	0x7000
%define A(x) (TRAMP + (x) - ap_trampoline)

[BITS 16]
section .text

global ap_trampoline
global ap_trampoline_end
global ap_cr3, ap_efer, ap_stack, ap_entry, ap_arg

ap_trampoline:
	cli
	cld
	mov	ax, cs
	mov	ds, ax
	lgdt	[ap_gdtr - ap_trampoline]
	mov	eax, cr0
	or	eax, 1                  ; protection
	mov	cr0, eax
	jmp	dword 0x18:A(pm32)

[BITS 32]
pm32:
	mov	ax, 0x20
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	mov	eax, cr4
	or	eax, 1 << 5             ; PAE
	mov	cr4, eax
	mov	eax, [A(ap_cr3)]
	mov	cr3, eax
	mov	ecx, 0xC0000080         ; EFER: the boot processor's (long mode, syscall)
	mov	eax, [A(ap_efer)]
	xor	edx, edx
	wrmsr
	mov	eax, cr0
	or	eax, (1 << 31) | 1      ; paging, protection
	mov	cr0, eax
	jmp	0x08:A(lm64)

[BITS 64]
lm64:
	mov	ax, 0x10
	mov	ds, ax
	mov	es, ax
	mov	ss, ax
	mov	rsp, [A(ap_stack)]
	mov	rdi, [A(ap_arg)]
	mov	rax, [A(ap_entry)]
	call	rax
.halt:
	cli
	hlt
	jmp	.halt

align 8
ap_cr3:		dq 0
ap_efer:	dq 0
ap_stack:	dq 0
ap_entry:	dq 0
ap_arg:		dq 0
ap_gdt:
	dq 0
	dq 0x00AF9A000000FFFF           ; 0x08: code, 64 bits
	dq 0x00CF92000000FFFF           ; 0x10: data
	dq 0x00CF9A000000FFFF           ; 0x18: code, 32 bits
	dq 0x00CF92000000FFFF           ; 0x20: data
ap_gdtr:
	dw 5 * 8 - 1
	dd A(ap_gdt)
ap_trampoline_end:
