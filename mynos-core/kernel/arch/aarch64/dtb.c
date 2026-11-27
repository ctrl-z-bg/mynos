/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The boot on AArch64 (doc/decisions/aarch64.md, choice 2): what GRUB's
   multiboot information says on the PC, from QEMU's device tree (at the
   start of RAM: the memory's size) and from the modules' archive
   (tools/mkmodules.py), which QEMU puts at 64 MB into RAM
   (-device loader: its -initrd and -append reach only Linux kernels):
     "MYNOSMOD", u32 count, u32 0, 256 bytes of the kernel's command line,
     then per module: u32 offset (from the archive's start, a page's
     multiple), u32 length, 248 bytes of its command line (NUL-terminated);
     the modules' bytes at their offsets. A device tree's initrd, if any,
     is taken first. */

#define ARCHIVE_AT  0x04000000UL      /* MyNOS's physical: 64 MB into RAM */
#define ARCHIVE_HEAD (16 + 256)

#include "global.h"
#include "multiboot.h"
#include "mem/mem.h"
#include "kutils.h"
#ifdef MYNOS_RASPI
extern int raspi_pcie_present, raspi_genet_present;
#endif

int _asm_global_mem_size;
int _asm_first_free_physical_page_address = 0x400000;
int _asm_last_kernel_page_dir_entry_used;

void mynos_main(multiboot_info_t * boot_info);

static multiboot_info_t mbi;
static module_t mods[MAXMODULES];
static char cmdline[256];

static int streq(const char * a, const char * b)
{
  while (*a && *a == *b) a++, b++;
  return *a == *b;
}

static uint32_t be32(const uint8_t * p)
{
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static uint64_t be_cells(const uint8_t * p, uint32_t len)
{
  return len == 8 ? (uint64_t)be32(p) << 32 | be32(p + 4) : be32(p);
}

/* the properties wanted: the memory node's reg (two cells each, as on
   virt), chosen's initrd and bootargs */
static void read_fdt(const uint8_t * fdt, uint64_t * mem, uint64_t * rd_start,
		     uint64_t * rd_end)
{
  const uint8_t * s = fdt + be32(fdt + 8), * strings = fdt + be32(fdt + 12);
  int depth = 0, in_memory = 0, in_chosen = 0;
  uint32_t acells = 2, scells = 1;              /* the root's (its #...-cells) */
  for (;;) {
    uint32_t token = be32(s);
    s += 4;
    if (token == 1) {                              /* a node begins */
      const char * name = (const char *)s;
      depth++;
      if (depth == 2) {
        in_memory = !kmemcmp((char *)name, "memory", 6);
        in_chosen = !kmemcmp((char *)name, "chosen", 6);
      }
      s += (kstrlen((char *)name) + 4) & ~3;
    } else if (token == 2) {                       /* it ends */
      if (depth == 2) in_memory = in_chosen = 0;
      depth--;
    } else if (token == 3) {                       /* a property */
      uint32_t len = be32(s), nameoff = be32(s + 4);
      const char * pname = (const char *)strings + nameoff;
      const uint8_t * v = s + 8;
      if (depth == 1 && streq(pname, "#address-cells") && len == 4) acells = be32(v);
      if (depth == 1 && streq(pname, "#size-cells") && len == 4) scells = be32(v);
      /* the first region's size: after its address, in the root's cells
         (virt: 2 and 2; a Pi 3: 1 and 1; a Pi 4: 2 and 1) */
      if (in_memory && streq(pname, "reg") && acells <= 2 && scells >= 1 && scells <= 2 &&
          len >= 4 * (acells + scells))
        *mem = be_cells(v + 4 * acells, 4 * scells);
#ifdef MYNOS_RASPI
      if (streq(pname, "compatible") && len >= 17 &&
          !kmemcmp((char *)v, "brcm,bcm2711-pcie", 17))
        raspi_pcie_present = 1;                    /* a Pi 4's PCIe (pcie4.c) */
      if (streq(pname, "compatible") && len >= 21 &&
          !kmemcmp((char *)v, "brcm,bcm2711-genet-v5", 21))
        raspi_genet_present = 1;                   /* a Pi 4's Ethernet (raspi.c) */
#endif
      if (in_chosen && streq(pname, "linux,initrd-start"))
        *rd_start = be_cells(v, len);
      if (in_chosen && streq(pname, "linux,initrd-end"))
        *rd_end = be_cells(v, len);
      if (in_chosen && streq(pname, "bootargs")) {
        uint32_t i;
        for (i = 0; i < len && i < sizeof cmdline - 1 && v[i]; i++) cmdline[i] = v[i];
        cmdline[i] = 0;
      }
      s += 8 + ((len + 3) & ~3);
    } else if (token == 4) {                       /* nothing */
    } else break;                                  /* the end */
  }
}

void arch_pci_assign(void);
#ifdef MYNOS_RASPI
void raspi_detect(void);
void raspi_uart_init(void);
unsigned long raspi_ram_size(void);
void raspi_fb_init(void);
#endif

/* [dtb]: x0 at the entry, the device tree's real address (a Pi's
   firmware; QEMU virt's is at RAM's start) */
void arch_boot(uint64_t dtb)
{
  const uint8_t * fdt = PHYS_TO_VIRT(0);
  uint64_t mem = 0, rd_start = 0, rd_end = 0;
#ifdef MYNOS_RASPI
  raspi_detect();                           /* a Pi 3 or a Pi 4 (raspi.c) */
  raspi_uart_init();
  fdt = dtb && dtb < 0x3F000000UL ? PHYS_TO_VIRT(dtb) : 0;
  if (fdt && be32(fdt) == 0xd00dfeed) read_fdt(fdt, &mem, &rd_start, &rd_end);
  if (mem == 0) mem = raspi_ram_size();     /* QEMU's raspi3b: no device tree */
  if (mem == 0) mem = 0x3B400000UL;         /* (948 MB: a Pi 3's, gpu_mem=76) */
  raspi_fb_init();                          /* the screen's text (fbcon.c) */
#else
  (void)dtb;
  if (be32(fdt) == 0xd00dfeed) read_fdt(fdt, &mem, &rd_start, &rd_end);
#endif
  if (mem == 0 || mem > 0x40000000UL) mem = 0x40000000UL;   /* at most 1 GB (paging.h) */
  _asm_global_mem_size = mem >> 20;

  mbi.flags = 4;                                  /* a command line */
  mbi.cmdline = (uint32_t)(vaddr_t)cmdline;
  mbi.mods_addr = (uint32_t)(vaddr_t)mods;
  mbi.mods_count = 0;
  {
    paddr_t base = rd_start && rd_end > rd_start ? rd_start - ARCH_RAM_BASE : ARCHIVE_AT;
    const uint8_t * a = PHYS_TO_VIRT(base);
    if (base < mem && !kmemcmp((char *)a, "MYNOSMOD", 8)) {
      uint32_t n = *(const uint32_t *)(a + 8), i;
      if (!cmdline[0]) {
        for (i = 0; i < 255 && a[16 + i]; i++) cmdline[i] = a[16 + i];
        cmdline[i] = 0;
      }
      for (i = 0; i < n && i < MAXMODULES; i++) {
        const uint8_t * e = a + ARCHIVE_HEAD + 256 * i;
        uint32_t off = *(const uint32_t *)e, len = *(const uint32_t *)(e + 4);
        mods[i].mod_start = base + off;
        mods[i].mod_end = base + off + len;
        mods[i].string = base + ARCHIVE_HEAD + 256 * i + 8;
      }
      mbi.mods_count = i;
      mbi.flags |= 8;
    }
  }
  arch_pci_assign();
  mynos_main(&mbi);
}
