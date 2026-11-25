/* MyNOS on AArch64: linked at 2 MB (the kernel's gigabyte, linear ==
   MyNOS's physical), loaded at RAM's 2 MB (0x40200000); QEMU starts the
   physical entry */
ENTRY(_start_phys)
SECTIONS
{
  . = 0x200000;
  _kernel_start = .;
  .text : AT(0x40200000) { *(.text.boot) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  . = ALIGN(4096);
  .bss : { __bss_start = .; *(.bss .bss.*) *(COMMON) . = ALIGN(16); __bss_end = .; }
  _kernel_end = .;
  _start_phys = _start + 0x40000000;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
