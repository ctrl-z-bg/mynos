# the i386's flags and link (included by mynos-core/CommonHeader)
ASFLAGS = -f elf
# the kernel at 2 MB, an ELF32 file (multiboot)
ARCH_LINK = $(LD) $(START) $(OFILESC) $(ALL_OBJ) \
		--oformat elf32-i386 -Ttext 0x200000 -o kernel.elf
