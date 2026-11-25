# MyNOS on x86-64 (doc/decisions/x86-64.md). For now, its first step only:
# boot-test.elf, a kernel that reaches long mode, prints and stops.
# Built in the dev-x86_64 container:
#   tools/in-container.sh dev-x86_64 make -C mynos-core/kernel/arch/x86_64

CC = gcc
CFLAGS = -m64 -ffreestanding -fno-pie -fno-stack-protector -mno-red-zone \
	-mgeneral-regs-only -mcmodel=small -O2 -Wall -nostdinc
LD = ld

all: boot-test.elf

start.o: start.asm
	nasm -f elf64 start.asm -o start.o

boot_test.o: boot_test.c
	$(CC) $(CFLAGS) -c boot_test.c -o boot_test.o

# linked at 2 MB, as on the i386; QEMU's -kernel (multiboot) takes only
# 32-bit ELF files: the 64-bit image is copied into one
boot-test.elf: start.o boot_test.o
	$(LD) -m elf_x86_64 -nostdlib -Ttext 0x200000 start.o boot_test.o -o boot-test64.elf
	objcopy -O elf32-i386 boot-test64.elf boot-test.elf

clean:
	rm -f *.o *.elf
