# MyNOS: the i386 architecture (doc/decisions/arch.md): the processor's
# tables and modes, the task switch, port I/O, the PC's interrupt
# controller and timer, and the boot's first instructions (start.asm)

RELPATH    = kernel/arch/i386

include ../../../CommonHeader

CFLAGS += -I../../../../mynos-lib/include

MODULE_NAME	= arch_module.o

.PHONY: all clean

SRCS	= 	$(wildcard *.c)
OFILES	=	$(SRCS:%.c=%.o)

all: $(MODULE_NAME) start.o

$(MODULE_NAME): $(OFILES)
	ld -r $(OFILES) -o $(MODULE_NAME)

start.o: start.asm
	nasm -f elf start.asm -o start.o

clean:
	rm -f *.o *.d *~

-include $(OFILES:.o=.d)
