# x86-64's flags and link (included by mynos-core/CommonHeader;
# doc/decisions/x86-64.md): built in the dev-x86_64 container
CFLAGS += -m64 -mno-red-zone -mcmodel=small -ffreestanding
ASFLAGS = -f elf64
# the kernel at 2 MB, as on the i386; QEMU's -kernel takes only 32-bit
# ELF files: the 64-bit image is copied into one
ARCH_LINK = $(LD) -m elf_x86_64 -nostdlib $(START) $(OFILESC) $(ALL_OBJ) \
		-Ttext 0x200000 -o kernel64.elf && \
	objcopy -O elf32-i386 kernel64.elf kernel.elf
