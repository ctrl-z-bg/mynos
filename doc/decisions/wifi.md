# Decision: the Wi-Fi of the Raspberry Pis

- **Issues:** mynos-btq.9, in the version 2 line (mynos-btq)
- **Date:** 2026-11-27
- **Status:** accepted by the owner ("a tendere voglio il wifi"); begun:
  the chip powered, its firmware loaded and answering (first try on a
  Pi 400 pending).

## Why

A Raspberry Pi 400 is a computer in a keyboard: its natural network is
the Wi-Fi, not a cable. MyNOS has the cable (GENET, btq.8.4); the owner
wants the Wi-Fi.

## The hardware

- **The chip**: a Cypress (later Infineon, now Synaptics) FullMAC chip,
  chip id 0x4345: a CYW43455 (revision 6) on a Pi 4 and 3 B+, a CYW43456
  (revision 9) on a Pi 400 and some CM4s. FullMAC: the chip's own ARM
  (a Cortex-R4) runs the 802.11 stack, scanning, joining and WPA2; the
  host loads its firmware and exchanges commands, events and Ethernet
  frames with it.
- **The bus**: SDIO, 4 data lines, on the BCM2711's first SDHCI, Arasan's
  (`mmcnr`, 0xFE300000, the one a Pi 3's SD card uses), wired by GPIO
  34-39 (function ALT3, CMD and DAT0-3 pulled up). The SD card is on the
  other controller, EMMC2.
- **The power**: `WL_ON`, line 1 of the GPIO expander that the board's
  firmware drives: the mailbox's tag `SET_GPIO_STATE` (0x00038041) for
  GPIO 129. Hence the native call 105, `mynos_piFirmware`.
- **The device tree** says whether there is a Wi-Fi (`mmcnr`'s child
  `wifi@1`, `brcm,bcm4329-fmac`): native call 106, `mynos_piDevices`.
  QEMU's `raspi4b` has no Wi-Fi and puts the SD card on the Arasan
  controller: there wifid must not touch it, and sdhcid may use it.
- **No emulator** has the chip: everything is tried on the board.

## Choices

- **A service of its own, `wifid`** (`services/wifi/`, C, a `driver`):
  the SDIO host (`sdio.c`, the same techniques as `sdhcid`'s on the same
  controller: polled, PIO, the slow-clock write delay), the chip, the
  firmware, the protocols. It will serve `wifi/1` (scan, join, status)
  and give netd its frames (how: below, still open).
- **brcmfmac's way, its names kept**: Linux's driver (ISC licence) is the
  reference; Plan 9's `ether4330.c` (MIT) the compact one. Circle (GPL
  v3) is not used: MyNOS is GPL v2 or later.
- **The firmware is not MyNOS's.** Its licence (Synaptics: reproduction
  and distribution in object code only, for use with Synaptics's chips)
  allows it on the Pi's card, not in MyNOS's repository nor its
  packages. `tools/make-sd-raspi.sh` downloads the three files
  (`brcmfmac43456-sdio.bin`, `.txt` the board's NVRAM, `.clm_blob` the
  radio's rules by country) from RPi-Distro's `firmware-nonfree` at a
  fixed commit, checks their sums and puts them in the card's `/wifi`
  (`/disk/wifi`). The Pi 4's CYW43455 files: later.
- **WPA2 on the host** (`wpa.c`). First chosen in the firmware (its own
  supplicant, the passphrase given as a PMK: no EAPOL in MyNOS), but the
  Pi 400's firmware answers `sup_wpa` with -23, unsupported: it
  associates, and the AP's 4-way handshake times out (reason 15). The
  handshakes are wifid's, as wpa_supplicant's on Linux: PBKDF2, the PRF,
  HMAC-SHA1 MICs, AES key unwrap (SHA-1 and AES from mbedTLS, the rest
  checked against the standards' test vectors), the keys given to the
  firmware (`wsec_key`), our RSN element too (`wpaie`). WPA2-PSK with
  CCMP only; no WPA3 (SAE).
- **The network's name and passphrase** in `/disk/wifi.env`, written by
  the user on the Pi's card: never in git, never served (httpd serves
  only `/disk/web`, and never `.env` files).

## The steps

1. The chip powered, SDIO, its id; its cores from its enumeration ROM;
   the firmware and NVRAM written to its RAM, its ARM started; the fast
   clock, function 2; SDPCM (the frames' header) and BCDC (commands):
   its version and MAC address. *Done on a Pi 400, at the first try
   (firmware 7.45.96.252).*
2. The CLM loaded (`clmload`), the country set; a scan (`escan`): the
   networks logged. *The CLM and the country work; the scan's command
   was dropped (SDPCM's credit, below): written again.*
3. Joining a WPA2-PSK network (`wsec`, `wpa_auth`, `wpaie`,
   `WLC_SET_SSID`), the 4-way handshake on the host, the keys installed;
   the events (link up, down). *Associating works on the Pi 400; the
   host's handshake written.*
4. The frames: Ethernet frames on SDPCM's data channel (with BDC's
   4-byte header), to and from netd; DHCP over the air.
5. `wifi/1` and a `wifi` command: scan, join, status; the networks
   remembered in `/disk/wifi.env`.

## Open

- **netd and two networks**: netd has one interface today (virtio,
  GENET or NE2000). With both a cable and the Wi-Fi, either netd learns
  two lwIP interfaces, or the Wi-Fi is used only without a cable's link.
  To decide at step 4.
- **How frames reach netd**: in netd's process (the Wi-Fi driver a
  library, as GENET's), or wifid giving them over IPC. wifid in its own
  process is simpler to bring up and keeps the firmware's 600 KB out of
  netd; a frame per IPC message costs little at Wi-Fi's speeds.
