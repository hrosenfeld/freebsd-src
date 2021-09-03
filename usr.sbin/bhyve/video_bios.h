/*-
 * SPDX-License-Identifier: BSD-2-Clause-FreeBSD
 *
 * Copyright (c) 2019 Henrik Gulbrandsen <henrik@gulbra.net>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * $FreeBSD$
 */

#ifndef _VIDEO_BIOS_H_
#define _VIDEO_BIOS_H_

/*** Debug Code ***************************************************************/

/* Default debug output: COM2 */
#define	DEBUG_PORT	0x2f8
#define	DEBUGGING	1

/*** Splash Screen ************************************************************/

/* 1.5 seconds of delay */
#define	SPLASH_DELAY_S	1
#define	SPLASH_DELAY_MS	500

/*** Error Codes **************************************************************/

#define	BAD_ENTRY	0xffff
#define	BAD_MODE	0xff

/*** BIOS Data Area ***********************************************************/

#define	BDA_SEGMENT	0x0040

/* Video Control Data Area 1 */
#define	BDA_DISPLAY_MODE	0x49
#define	BDA_NUMBER_OF_COLUMNS	0x4A
#define	BDA_VIDEO_PAGE_SIZE	0x4C
#define	BDA_VIDEO_PAGE_OFFSET	0x4E
#define	BDA_CURSOR_POSITIONS	0x50
#define	BDA_CURSOR_TYPE		0x60
#define	BDA_DISPLAY_PAGE	0x62
#define	BDA_CRTC_BASE		0x63
#define	BDA_3X8_SETTING		0x65
#define	BDA_3X9_SETTING		0x66

/* Video Control Data Area 2 */
#define	BDA_LAST_ROW_INDEX	0x84
#define	BDA_CHARACTER_HEIGHT	0x85
#define	BDA_VIDEO_MODE_OPTIONS	0x87
#define	BDA_VIDEO_FEATURE_BITS	0x88
#define	BDA_VIDEO_DISPLAY_DATA	0x89
#define	BDA_DCC_TABLE_INDEX	0x8A

/* Save Pointer Data Area */
#define	BDA_SAVE_POINTER_TABLE	0xA8

/*** Video Parameter Table ****************************************************/

#define	VPT_NUMBER_OF_COLUMNS	0x00
#define	VPT_LAST_ROW_INDEX	0x01
#define	VPT_CHARACTER_HEIGHT	0x02
#define	VPT_PAGE_SIZE		0x03
#define	VPT_SEQUENCER_REGS	0x05
#define	VPT_MISC_OUTPUT_REG	0x09
#define	VPT_CRT_CTRL_REGS	0x0A
#define	VPT_ATR_CTRL_REGS	0x23
#define	VPT_GFX_CTRL_REGS	0x37

/*** VbeInfoBlock Structure ***************************************************/

#define	VBE1_VIB_SIZE		0x14
#define	VBE2_VIB_SIZE		0x22

#define	VIB_VbeSignature	0x00
#define	VIB_VbeVersion		0x04
#define	VIB_OemStringPtr	0x06
#define	VIB_Capabilities	0x0A
#define	VIB_VideoModePtr	0x0E
#define	VIB_TotalMemory		0x12
#define	VIB_OemSoftwareRev	0x14
#define	VIB_OemVendorNamePtr	0x16
#define	VIB_OemProductNamePtr	0x1A
#define	VIB_OemProductRevPtr	0x1E
#define	VIB_OemData		0x100

/*** ModeInfoArray ************************************************************/

#define	MIA_STRUCT_SIZE	8

#define	MIA_MODE	0x00
#define	MIA_WIDTH	0x02
#define	MIA_HEIGHT	0x04
#define	MIA_DEPTH	0x06

/*** ModeInfoBlock ************************************************************/

#define	MIB_STRUCT_SIZE	256

#define	MIB_MODE_ATTRIBUTES		0x00
#define	MIB_BYTES_PER_SCAN_LINE		0x10
#define	MIB_X_RESOLUTION		0x12
#define	MIB_Y_RESOLUTION		0x14
#define	MIB_BITS_PER_PIXEL		0x19
#define	MIB_RSVD_MASK_SIZE		0x25
#define	MIB_RSVD_FIELD_POSITION		0x26
#define	MIB_PHYS_BASE_PTR		0x28
#define	MIB_LIN_BYTES_PER_SCAN_LINE	0x32
#define	MIB_LIN_RSVD_MASK_SIZE		0x3c
#define	MIB_LIN_RSVD_FIELD_POSITION	0x3d
#define	MIB_MAX_PIXEL_CLOCK		0x3e

/*** Saved Video State ********************************************************/

/* Saved hardware state */
#define	SVS_SEQ_REGS		0x05
#define	SVS_CRTC_REGS		0x0A
#define	SVS_ATR_REGS		0x23
#define	SVS_GFX_REGS		0x37
#define	SVS_CRTC_BASE_LOW	0x40
#define	SVS_CRTC_BASE_HIGH	0x41
#define	SVS_LATCHES		0x42

/*** Bhyve Registers **********************************************************/

#define	FBUF_INDEX_PORT	0xfbfb
#define	FBUF_DATA_PORT	0xfbfc

#define	FBUF_REG_WIDTH		0x00
#define	FBUF_REG_HEIGHT		0x01
#define	FBUF_REG_DEPTH		0x02
#define	FBUF_REG_SCANWIDTH	0x04

/*** VGA Registers ************************************************************/

/* Ports for indexed registers */
#define	PORT_ATR	0x03C0
#define	PORT_SEQ	0x03C4
#define	PORT_GFX	0x03CE

/* Normal ports for VGA */
#define	PORT_CRTC_VGA	0x03D4
#define	PORT_ISR1_VGA	0x03DA
#define	PORT_FEAT_VGA	0x03DA

/* Alternative ports for MDA compatibility */
#define	PORT_CRTC_MDA	0x03B4
#define	PORT_ISR1_MDA	0x03BA
#define	PORT_FEAT_MDA	0x03BA

/* A separate read address due to sharing with ISR1 */
#define	PORT_FEAT_READ	0x03CA

/* Ports for video DAC registers */
#define	PORT_DAC_MASK	0x03C6
#define	PORT_DAC_STATE	0x03C7
#define	PORT_DAC_READ	0x03C7
#define	PORT_DAC_WRITE	0x03C8

/* Ports for Video DAC palette registers */
#define	PORT_PALETTE_READ	0x03C7
#define	PORT_PALETTE_WRITE	0x03C8
#define	PORT_PALETTE_DATA	0x03C9

/* Ports for individual registers */
#define	PORT_MISC	0x0C32

/* Register Counts */
#define	RCNT_ATR	20
#define	RCNT_SEQ	 4
#define	RCNT_GFX	 9
#define	RCNT_CRT	25

/* Attribute Controller Registers */
#define	ATRR_ATTR_MODE_CTRL	0x10

/* Sequencer Registers */
#define	SEQR_RESET		0x00
#define	SEQR_MAP_MASK		0x02
#define	SEQR_MEMORY_MODE	0x04

/* Graphics Controller Registers */
#define	GFXR_SET_RESET		0x00
#define	GFXR_DATA_ROTATE	0x03
#define	GFXR_READ_MAP_SELECT	0x04
#define	GFXR_GRAPHICS_MODE	0x05
#define	GFXR_MISCELLANEOUS	0x06
#define	GFXR_BIT_MASK		0x08

/* CRT Controller Registers */
#define	CRTR_CURSOR_START	0x0A
#define	CRTR_CURSOR_END		0x0B
#define	CRTR_START_ADDRESS_HIGH	0x0C
#define	CRTR_START_ADDRESS_LOW	0x0D
#define	CRTR_CURSOR_LOC_HIGH	0x0E
#define	CRTR_CURSOR_LOC_LOW	0x0F

/******************************************************************************/

#endif /* _VIDEO_BIOS_H_ */
