#!/usr/bin/env python3
"""The modules of a boot on AArch64, in one archive that QEMU loads at
64 MB into RAM (-device loader; doc/decisions/aarch64.md, choice 2; read
by arch/aarch64/dtb.c): "MYNOSMOD", u32 count, u32 0, 256 bytes of the
kernel's command line; per module u32 offset (from the archive's start,
a page's multiple), u32 length, 248 bytes of its command line
(NUL-terminated); the modules' bytes at their offsets.

    mkmodules.py [-c "kernel command line"] OUT "path arg..." ...

Each argument is a module's command line, as GRUB's module line: its first
word is the file, read from here; the whole line is its argv."""
import struct, sys

args = sys.argv[1:]
kcmd = b""
if args[:1] == ["-c"]:
    kcmd, args = args[1].encode()[:255], args[2:]
out, lines = args[0], args[1:]
if len(lines) > 10:
    sys.exit("mkmodules.py: at most 10 modules")
head = bytearray(b"MYNOSMOD" + struct.pack("<II", len(lines), 0) +
                 kcmd + b"\0" * (256 - len(kcmd)))
body, offset = [], (len(head) + 256 * len(lines) + 4095) & ~4095
for line in lines:
    data = open(line.split()[0], "rb").read()
    cmd = line.encode()[:247]
    head += struct.pack("<II", offset, len(data)) + cmd + b"\0" * (248 - len(cmd))
    body.append((offset, data))
    offset = (offset + len(data) + 4095) & ~4095
img = bytearray(offset)
img[:len(head)] = head
for off, data in body:
    img[off:off + len(data)] = data
open(out, "wb").write(img)
