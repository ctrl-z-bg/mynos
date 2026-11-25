; MyNOS on x86-64: the ways into the kernel (doc/decisions/x86-64.md).
;
; Every entry leaves a struct frame (idt.h) on the thread's kernel stack:
; the general registers, a vector, an error code, and the processor's
; iretq frame; C gets its address. Every way out is trap_return: the
; registers back, iretq.

[BITS 64]
section .text

extern x86_trap
extern x86_syscall
extern kernel_enter
extern kernel_exit
extern smp_leave_if_dead

%macro SAVE 0
	cld
	push	rax
	push	rbx
	push	rcx
	push	rdx
	push	rsi
	push	rdi
	push	rbp
	push	r8
	push	r9
	push	r10
	push	r11
	push	r12
	push	r13
	push	r14
	push	r15
%endmacro

; an interrupt nobody expects
global int_null
int_null:
	iretq

; from a process (its cs's privilege 3, in the frame): GS's base the
; processor's (percpu.h); and back to one, the process's
%define FRAME_CS 144

; every way out leaves the big lock (smp.c), unless nested; a new thread
; comes here first, its depth 1
global trap_return
trap_return:
	test	byte [rsp + FRAME_CS], 3
	jz	.leave
	call	smp_leave_if_dead       ; back to a process that has ended: not
.leave:
	call	kernel_exit
	test	byte [rsp + FRAME_CS], 3
	jz	.kernel
	swapgs
.kernel:
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	r11
	pop	r10
	pop	r9
	pop	r8
	pop	rbp
	pop	rdi
	pop	rsi
	pop	rdx
	pop	rcx
	pop	rbx
	pop	rax
	add	rsp, 16                 ; vector, error code
	iretq

; the exceptions: those with an error code have it pushed by the processor
%macro EXC 1
exc%1:
%if %1 != 8 && %1 != 10 && %1 != 11 && %1 != 12 && %1 != 13 && %1 != 14 && %1 != 17
	push	0
%endif
	push	%1
	jmp	trap_common
%endmacro

%assign i 0
%rep 32
EXC i
%assign i i+1
%endrep

trap_common:
	SAVE
	test	byte [rsp + FRAME_CS], 3
	jz	.kernel
	swapgs
.kernel:
	call	kernel_enter            ; the big lock (smp.c)
	mov	rdi, rsp
	call	x86_trap
	jmp	trap_return

; MyNOS's native calls: int 0x90, the number in rax, the arguments in rdi,
; rsi, rdx, r10, r8 (as Linux's calls)
global native_call_entry
native_call_entry:
	push	0
	push	0x90
	jmp	trap_common

; another processor's interrupt (a thread to run, a TLB to flush), and
; this processor's local APIC timer (smp.c)
global ipi_entry
ipi_entry:
	push	0
	push	0xF0
	jmp	trap_common
global lapic_timer_entry
lapic_timer_entry:
	push	0
	push	0xF1
	jmp	trap_common

; Linux's calls: syscall (the processor saves rip in rcx, rflags in r11,
; and switches nothing else): GS the processor's, the kernel stack from
; its struct cpu (gs:8, the user's stack pointer kept at gs:16), then the
; same frame as an interrupt's, so that every way out is trap_return
global syscall_entry
syscall_entry:
	swapgs
	mov	[gs:16], rsp
	mov	rsp, [gs:8]
	push	0x23                    ; ss: user data
	push	qword [gs:16]           ; rsp
	push	r11                     ; rflags
	push	0x1B                    ; cs: user code
	push	rcx                     ; rip
	push	0
	push	0x80
	SAVE
	call	kernel_enter
	mov	rdi, rsp
	call	x86_syscall
	jmp	trap_return


; switch_stacks(&old->rsp, new rsp): the callee-saved registers of the
; thread switched out stay on its stack, its stack pointer in *old
global switch_stacks
switch_stacks:
	push	rbx
	push	rbp
	push	r12
	push	r13
	push	r14
	push	r15
	mov	[rdi], rsp
	mov	rsp, rsi
	pop	r15
	pop	r14
	pop	r13
	pop	r12
	pop	rbp
	pop	rbx
	ret

; copy_user(to, from, n): a copy that may fault; a fault at copy_user_insn
; resumes at copy_user_fault (mem.c), and the copy returns -1
global copy_user
global copy_user_insn
global copy_user_fault
copy_user:
	mov	rcx, rdx
copy_user_insn:
	rep movsb
	xor	eax, eax
	ret
copy_user_fault:
	mov	eax, -1
	ret

section .data
global exception_stubs
exception_stubs:
%assign i 0
%rep 32
	dq exc %+ i
%assign i i+1
%endrep
