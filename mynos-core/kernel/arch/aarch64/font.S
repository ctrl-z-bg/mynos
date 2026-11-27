/*
 * The text console's font on a Raspberry Pi (MYNOS_RASPI: fbcon.c):
 * Terminus 8x16 (third_party/fonts, SIL Open Font License 1.1), its PSF
 * file as it is, in the kernel's image.
 */
#ifdef MYNOS_RASPI
	.section .rodata
	.global font_psf, font_psf_end
	.balign 4
font_psf:
	.incbin "terminus16.psf"
font_psf_end:
#endif
