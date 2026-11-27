# C-BIOS

C-BIOS 0.29a (http://cbios.sourceforge.net), a free BIOS for MSX
computers, written from scratch, under the BSD licence of two clauses
(`LICENSE`, from its `doc/cbios.txt`). From
https://sourceforge.net/projects/cbios/files/cbios/0.29/cbios-0.29a.zip
(SHA-256 c585a2f4a10b397e460a95043d59ac79cf4442fbb45a6e14a1e27ef9febaed73),
unchanged: `roms/cbios_main_msx1.rom` (32 KB, SHA-1
2f997e8a57528518c82ab3693fdae243dbbcc508) and `roms/cbios_logo_msx1.rom`
(16 KB, 9fbbe400dbaf186aeba42e170d9424b032412c42), the international
MSX1 at 60 Hz, as openMSX's configuration `C-BIOS_MSX1` puts them (slot
0: the main ROM at 0x0000, the logo at 0x8000); for the MSX2,
`roms/cbios_main_msx2.rom` (32 KB, SHA-1
f929bd1d720b0ef7092c9add8accd0d56fc9c8a3), `roms/cbios_logo_msx2.rom`
(16 KB, d4e5b98ce23573669fb44447582d656e390791c0) and
`roms/cbios_sub.rom` (16 KB, 2fcb40413e7d373f0f2dbdc815ce18746ddf3684),
as `C-BIOS_MSX2` puts them (the main ROM and the logo in slot 0, the
SUB-ROM in slot 3-0).

It starts cartridges; it has no MSX-BASIC and no disk. The package msx
brings it.
