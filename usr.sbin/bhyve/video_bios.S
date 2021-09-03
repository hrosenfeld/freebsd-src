/******************************************************************************/
/*  Video BIOS for bhyve - Handles int 10h interrupts for VGA and VESA modes  */
/******************************************************************************/
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

/*
 * The following resources may be useful when working on this video BIOS.
 *
 * Old manuals available at archive.org:
 *   The 8086 Family User's Manual, October 1979
 *   IBM PS/2 and PC BIOS Interface Technical Reference, 2nd Edition, May 1988
 *   IBM VGA XGA Technical Reference Manual, Preliminary Draft, May 1992
 *
 * Specifications:
 *   Plug and Play BIOS Specification, Version 1.0A, May 1994
 *   BIOS Boot Specification, Version 1.01, January 1996
 *   VESA BIOS Extension (VBE) Core Functions, Version 3.0, September 1998
 *   PCI Local Bus Specification, Revision 2.2, December 1998 [Expansion ROMs]
 *   VESA Enhanced EDID, Release A, Revision 1, February 2000
 *
 * Technical Details:
 *   Ralf Brown's Interrupt List (RBIL), Release 61, July 2000
 */

#include "video_bios.h"

.section .bios, "ax", @progbits
.arch i8086
.code16

#ifndef	TESTING
#define	SPLASH
#endif

/*** Definitions **************************************************************/

/* Code revision, for use in PCI Data Structure */
.set	REV,	1

/* Total size of Option ROM, in 512-byte blocks */
.set	SIZE,	(TAIL - HEAD) >> 9

/* Null-terminated ASCII strings */
.set	VENDOR,	(Manufacturer - HEAD)
.set	DEVICE,	(ProductName - HEAD)

/* Offsets to information structures */
.set	PCI_OFFSET,	(PCI_Data_Structure - HEAD)
.set	PNP_OFFSET,	(PnP_Expansion_Header - HEAD)

/* Plug and Play Vendor ID (for both PnP Expansion Header and EDID) */
#define	PNP_VENDOR_ID(A, B, C) (((A-'A'+1)<<10)|((B-'A'+1)<<5)|((C-'A'+1)<<0))
.set	PNP_ID,	PNP_VENDOR_ID('B', 'S', 'D')

/* Different ways of saying the same thing */
.set	PCIVID,	0xFB5D	/* PCI Vendor ID */
.set	PCIDID,	0x40FB	/* PCI Device ID */
.set	PNPVID,	PNP_ID	/* PNP Vendor ID */
.set	PNPDID,	0xFBFB	/* PNP Device ID */

.set	BCV,	(BootConnectionVector - HEAD)

/*** Macros *******************************************************************/

/*
 * Prints a single literal character. This is useful for debugging.
 *
 * Required Arguments:
 *   ch - The char to print
 *
 * Clobbers: Nothing
 */
.macro print ch
	push	%ax
	push	%dx
	mov	$DEBUG_PORT, %dx
	mov	$(\ch), %al
	outb	%al, %dx
	pop	%dx
	pop	%ax
.endm

/*
 * Prints the AX register value and an extra text message.
 * This is meant for tracing of interesting BIOS calls.
 *
 * Required Arguments:
 *   Text - Typically a function name
 */
.macro DHeader Text
#ifdef	DEBUGGING

	/*
	 * This bit has no documented use, so we borrow it to signal that
	 * a debug header has already been printed. It is reset by the call
	 * to INT 10h and allows us to ignore internal function calls.
	 */
	testb	$0x10, BDA_VIDEO_FEATURE_BITS
	jnz	0f
	orb	$0x10, BDA_VIDEO_FEATURE_BITS

	/* Print the given text to DEBUG_PORT */
	call	PrintDebugHeader
	jmp	0f
	.asciz	"\Text\r\n"
0:
#endif
.endm

.macro	PrintByte Byte
	mov	$STR_\Byte, %ax
	call	PrintString
	mov	\Byte, %al
	call	PrintAlRegister
	mov	$STR_EOL, %ax
	call	PrintString
.endm

.macro	PrintWord Word
	mov	$STR_\Word, %ax
	call	PrintString
	mov	\Word, %ax
	call	PrintAxRegister
	mov	$STR_EOL, %ax
	call	PrintString
.endm

.macro	PrintCursors Word
	mov	$STR_\Word, %ax
	call	PrintString
	xor	%bx, %bx
	mov	$8, %cx
\@:	mov	\Word(%bx), %ax
	call	PrintAxRegister
	print	' '
	inc	%bx
	inc	%bx
	loop	\@b
	mov	$STR_EOL, %ax
	call	PrintString
.endm

.macro JmpNotImplemented Text
	push	%ax
	mov	$\@f, %ax
	call	PrintString
	pop	%ax
	jmp	NotImplemented
\@:	.asciz	"\Text: "
.endm
/*
 * Pushes the given arguments from left to right.
 * This is nice when you have many things to push.
 */
.macro PushSet Head, Tail:vararg
.ifnb	\Head
	push	\Head
PushSet	\Tail
.endif
.endm

/*
 * Pops the given arguments from right to left.
 * This is nice when you have many things to pop.
 */
.macro PopSet Head, Tail:vararg
.ifnb	\Head
PopSet	\Tail
	pop	\Head
.endif
.endm

/*
 * Swaps the values of two arguments by using the stack.
 * This is like an xchg operation, but works for seg-regs.
 */
.macro Swap arg1, arg2
	push	\arg1
	push	\arg2
	pop	\arg1
	pop	\arg2
.endm

/*
 * Sets a VGA Register specified by Port and Index to the given Value.
 * Port is for the index register. Data is written to the next port.
 *
 * Required Arguments:
 *   Port  - Address for the index register
 *   Index - Index for the register to update
 *   Value - The new register value
 *
 * Clobbers: AL, DX
 */
.macro SetReg Port, Index, Value
	movw	\Port, %dx
	movb	\Index, %al
	outb	%al, %dx
	inc	%dx
	movb	\Value, %al
	outb	%al, %dx
.endm

/*
 * Sets a range of VGA registers from data stored in memory.
 *
 * Required Arguments:
 *   Port  - Address for the index register
 *   Count - The number of registers to write
 *   Data  - Offset of data array from pointer in BX
 *
 * Optional Arguments:
 *   StartIndex - Register index for the byte at Data[0] (default: 0)
 *   PortOffset - Offset of data port from index port (default: 1)
 *
 * Input Registers:
 *   CS:BX - Pointer to an element in the Video Parameter Table
 *
 * Clobbers:
 *   AX, CX, DX, SI
 */
.macro SetRegs Port, Count, Data, StartIndex=$0, PortOffset=$1
	xor	%si, %si
	mov	\StartIndex, %ah
	mov	\Count, %cx
0:	mov	\Port, %dx
	mov	%ah, %al
	out	%al, %dx
	mov	%cs:(\Data)(%bx, %si), %al
	add	\PortOffset, %dx
	out	%al, %dx
	inc	%ah
	inc	%si
	loop	0b
.endm

/*
 * Pushes the current value of a VGA register to the stack.
 *
 * Required Arguments:
 *   Port  - Address for the index register
 *   Index - Index for the register to update
 *
 * Clobbers: AX, DX
 */
.macro PushReg Port, Index
	movw	\Port, %dx
	movb	\Index, %al
	outb	%al, %dx
	inc	%dx
	inb	%dx, %al
	xor	%ah, %ah
	push	%ax
.endm

/*
 * Restores a previously stored VGA register value
 *
 * Required Arguments:
 *   Port  - Address for the index register
 *   Index - Index for the register to update
 *
 * Clobbers: AX, DX
 */
.macro PopReg Port, Index
	movw	\Port, %dx
	movb	\Index, %al
	outb	%al, %dx
	inc	%dx
	pop	%ax
	outb	%al, %dx
.endm

/*
 * Enters 32-bit protected mode.
 */
.macro Enter32
	call	EnterProtectedMode
.arch i386
.code32
.endm

/*
 * Leaves 32-bit protected mode.
 */
.macro Leave32
	call	LeaveProtectedMode
.arch i8086
.code16
.endm

/*
 * Works around a missing bhyve feature to run "es lodsb" or "es lodsw".
 *
 * Only stos, movs, and mov between a fixed address and %ax will work
 * in emulated real mode on the current kernel (FreeBSD 11.3). Changes
 * to bhyve are already extensive, so I prefer to use a workaround.
 * This rearranges segment registers so we can movsx to the stack.
 *
 * Arguments:
 *   x - the instruction suffix (b or w)
 *
 * Clobbers:  Only SI, as expected
 */
.macro es_lodsx x
#ifdef	FIXED_IN_KERNEL
	lods\x	%es:(%si)
#else
	PushSet	%di, %ds, %es, %ax
	mov	%es, %ax	# Move %es to %ds
	mov	%ax, %ds
	mov	%ss, %ax	# Move %ss to %es
	mov	%ax, %es
	mov	%sp, %ax	# Write to top of stack
	mov	%ax, %di
	movs\x	%ds:(%si), %es:(%di)
	PopSet	%di, %ds, %es, %ax
#endif
.endm

/*
 * A more convenient way to call "es_lodsx b".
 */
.macro es_lodsb
	es_lodsx b
.endm

/*
 * A more convenient way to call "es_lodsx w".
 */
.macro es_lodsw
	es_lodsx w
.endm

/*** Initial Data *************************************************************/

.global VideoBIOS
VideoBIOS:

HEAD:
.word	0xAA55	/* Option ROM signature */
.byte	SIZE	/* Length in 512-byte blocks */
	jmp	Init

BiosChecksum:
.org 0x06
.byte	0x00	/* Option ROM checksum */

.zero	5	/* Reserved/Unknown */

#ifndef NOT_PS2
/* ROM Signature for PS/2 video cards; obsolete? */
.org 0x0C
.word	0xCC77
.ascii	"VIDEO "
#else
.zero	8
#endif

/* Physical address to the non-VGA framebuffer */
PhysBasePtr:
.org 0x14
.long	0

.org 0x18
.word	PCI_OFFSET	/* Offset to PCI data structure */
.word	PNP_OFFSET	/* Offset to PnP expansion header */

#ifndef NOT_PS2
/* POS parameters for PS/2 video cards; obsolete? */
.org 0x30
.byte	0x00	/* POS Byte 102 */
.byte	0x00	/* POS Byte 103 */
.byte	0x00	/* POS Byte 104 */
.byte	0x00	/* POS Byte 105 */
#else
.zero	4
#endif

/*** Detailed Info ************************************************************/

Manufacturer:
.asciz	"The FreeBSD Project"

ProductName:
.asciz	"bhyve Framebuffer"

OemString:
.asciz	"FreeBSD bhyve"

OemProductRev:
.asciz	"2.0"

.align 4

PCI_Data_Structure:
.ascii	"PCIR"	# Signature
.word	PCIVID	# Vendor ID: FreeBSD
.word	PCIDID	# Device ID: FrameBuffer
.word	0x0000	# Pointer to Vital Product Data
.word	0x0018	# PCI Data Structure Length
.byte	0x00	# PCI Data Structure Revision
.byte	0x03	# Class: Display Controller
.byte	0x00	# Subclass: VGA-Compatible
.byte	0x00	# Interfaces: Only VGA
.word	SIZE	# Image Length: copy of ROM length
.word	REV	# Revision Level of Code/Data
.byte	0x00	# Code Type: Intel x86, PC-AT Compatible
.byte	0x80	# Indicator: Last image in this ROM
.word	0x0000	# Reserved

PnP_Expansion_Header:
.ascii	"$PnP"	# Signature
.byte	0x01	# Structure Revision
.byte	0x02	# Length (in 16-byte increments)
.word	0x0000	# Offset of next header from this header
.byte	0x00	# Reserved
.byte	0x00	# Checksum
.word	PNPVID	# Vendor ID: BSD
.word	PNPDID	# Device ID
.word	VENDOR	# Pointer to manufacturer string
.word	DEVICE	# Pointer to product name string
.byte	0x03	# Class: Display Controller
.byte	0x00	# Subclass: VGA-Compatible
.byte	0x00	# Interfaces: Only VGA
.byte	0xE1	# Indicators: DDIM, Shadow RAM, Cacheable, Display Device
.word	BCV	# Boot Connection Vector (BCV)
.word	0x0000	# Disconnect Vector (DV; obsolete)
.word	0x0000	# Bootstrap Entry Vector (BEV; not used)
.word	0x0000	# Reserved
.word	0x0000	# Static resource information vector for non-PnP devices

PageCountArray: # This array contains the number of pages for each valid mode
# Mode: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, A, B, C, D, E, F, 10, 11, 12, 13
.byte   8, 8, 8, 8, 1, 1, 1, 8, 0, 0, 0, 0, 0, 8, 4, 2,  2,  1,  1,  1

ColorCountArray:# This array contains the number of colors for each valid mode
# Mode: 0,  1,  2,  3, 4, 5, 6, 7, 8, 9, A, B, C,  D,  E, F, 10, 11, 12,  13
.word  16, 16, 16, 16, 4, 4, 2, 0, 0, 0, 0, 0, 0, 16, 16, 0, 16,  2, 16, 256

/* The 8254 timer runs at 1.193182 MHz */
SubticksPerMillisecond:
.word	1193

DisplayWidth:
.word	0x0000

DisplayHeight:
.word	0x0000

/*** VESA BIOS Extension (VBE) Data *******************************************/

VBE2:
.ascii	"VBE2"

RefreshRateHz:
.word	60

VbeInfoBlock:
.ascii	"VESA"		# VbeSignature
.word	0x0300		# VbeVersion		; 3.0
.long	OemString	# OemStringPtr		; "FreeBSD bhyve"
.long	0x02		# Capabilities		; Not VGA compatible
.long	VbeVideoModes	# VideoModePtr
.word	0x0100		# TotalMemory		; 16 MiB
.word	0x0200		# OemSoftwareRev	; 2.0
.long	Manufacturer	# OemVendorNamePtr	; "The FreeBSD Project"
.long	ProductName	# OemProductNamePtr	; "bhyve Framebuffer"
.long	OemProductRev	# OemProductRevPtr	; "2.0"

VbeVideoModes:	# This array contains a list of the valid VESA modes
.word	0x0112	# 640x480x24
.word	0x0115	# 800x600x24
.word	0x0118	# 1024x768x24
.word	0x011b	# 1280x1024x24
.word	0x0132	# 1280x720x24
.word	0x0134	# 1600x900x24
.word	0x0135	# 1600x1200x24
.word	0x0136	# 1920x1080x24
.word	0x0137	# 1920x1200x24
.word	0x013f	# 640x480x32
.word	0x0140	# 800x600x32
.word	0x0141	# 1024x768x32
.word	0x0142	# 1280x720x32
.word	0x0143	# 1280x1024x32
.word	0x0144	# 1600x900x32
.word	0x0145	# 1600x1200x32
.word	0x0146	# 1920x1080x32
.word	0x0147	# 1920x1200x32
.word	0xffff

ModeInfoArray:	# This gives the resolution for each mode
.word	0x0112,  640,  480, 24	# 640x480x24
.word	0x0115,  800,  600, 24	# 800x600x24
.word	0x0118, 1024,  768, 24	# 1024x768x24
.word	0x011b, 1280, 1024, 24	# 1280x1024x24
.word	0x0132, 1280,  720, 24	# 1280x720x24
.word	0x0134, 1600,  900, 24	# 1600x900x24
.word	0x0135, 1600, 1200, 24	# 1600x1200x24
.word	0x0136, 1920, 1080, 24	# 1920x1080x24
.word	0x0137, 1920, 1200, 24	# 1920x1200x24
.word	0x013f,  640,  480, 32	# 640x480x32
.word	0x0140,  800,  600, 32	# 800x600x32
.word	0x0141, 1024,  768, 32	# 1024x768x32
.word	0x0142, 1280,  720, 32	# 1280x720x32
.word	0x0143, 1280, 1024, 32	# 1280x1024x32
.word	0x0144, 1600,  900, 32	# 1600x900x32
.word	0x0145, 1600, 1200, 32	# 1600x1200x32
.word	0x0146, 1920, 1080, 32	# 1920x1080x32
.word	0x0147, 1920, 1200, 32	# 1920x1200x32
.word	0x0000

ModeInfoBlock:
.word	0x00FB	# ModeAttributes (Non-VGA linear color graphics; no TTY output)
.byte	0x00	# WinAAttributes
.byte	0x00	# WinBAttributes
.word	0x0000	# WinGranularity
.word	0x0000	# WinSize
.word	0x0000	# WinASegment
.word	0x0000	# WinBSegment
.long	0	# WinFuncPtr
.word	0x0000	# BytesPerScanLine
.word	0x0000	# XResolution
.word	0x0000	# YResolution
.byte	8	# XCharSize
.byte	16	# YCharSize
.byte	1	# NumberOfPlanes
.byte	0x00	# BitsPerPixel
.byte	1	# NumberOfBanks
.byte	0x06	# MemoryModel (Direct Color)
.byte	0	# BankSize
.byte	0	# NumberOfImagePages
.byte	1	# Reserved for page function
.byte	0x08	# RedMaskSize
.byte	0x10	# RedFieldPosition
.byte	0x08	# GreenMaskSize
.byte	0x08	# GreenFieldPosition
.byte	0x08	# BlueMaskSize
.byte	0x00	# BlueFieldPosition
.byte	0x08	# RsvdMaskSize
.byte	0x18	# RsvdFieldPosition
.byte	0x00	# DirectColorModeInfo
.long	0	# PhysBasePtr
.long	0	# Reserved
.word	0x0000	# Reserved
.word	0x0000	# LinBytesPerScanLine
.byte	0	# BnkNumberOfImagePages
.byte	0	# LinNumberOfImagePages
.byte	0x08	# LinRedMaskSize
.byte	0x10	# LinRedFieldPosition
.byte	0x08	# LinGreenMaskSize
.byte	0x08	# LinGreenFieldPosition
.byte	0x08	# LinBlueMaskSize
.byte	0x00	# LinBlueFieldPosition
.byte	0x08	# LinRsvdMaskSize
.byte	0x18	# LinRsvdFieldPosition
.long	0	# MaxPixelClock
.zero	188

/*** Extended Display Identification Data (EDID) ******************************/

#define	DISPLAY_DATA_SIZE	128

/* Flags according to the read-edid package (get-edid + parse-edid) */
#define	DDC_DDC1_SUPPORTED	0x0001 /* Support for DDC1 transfers */
#define	DDC_DDC2_SUPPORTED	0x0002 /* Support for DDC2 transfers */
#define	DDC_BLANK_TRANSFER	0x0004 /* Screen blanked during transfer */

#define	SECONDS_PER_EDID_BLOCK	0

/* This is the same as PNP_VENDOR_ID, but the EDID word is big endian */
#define	EdidVendorId(A, B, C) \
    ( ((A-'A'+1)<<2) | ((B-'A'+1)>>3) | (((B-'A'+1)&7)<<13) | ((C-'A'+1)<<8) )

/*
 * CIE 1931 xy coordinates for the sRGB color space
 */
#define	sRGB_R_x	6400	/* 0.64 */
#define	sRGB_R_y	3300	/* 0.33 */
#define	sRGB_G_x	3000	/* 0.30 */
#define	sRGB_G_y	6000	/* 0.60 */
#define	sRGB_B_x	1500	/* 0.15 */
#define	sRGB_B_y	 600	/* 0.06 */
#define	sRGB_W_x	3127	/* 0.3127 */
#define	sRGB_W_y	3290	/* 0.3290 */

/*
 * Extracts bits from (index - count) to (index) in the binary fraction of
 * (value) and shifts the result (shift) bits left to fill a wanted position.
 */
#define	CHROMA_BITS(value, index, count, shift) \
    (((((value * (1 << 10) + 5000) / 10000) >> (10 - index)) & \
	((1 << count) - 1)) << shift)

/* They had to squeeze these into single bytes... */
#define	X_RES(value)	( (value) / 8 - 31 )
#define	FREQ(value)	( (value) - 60 )

/* ...and combine the aspect ratio with the frequency. */
#define	ASPECT_16_10	0x00
#define	ASPECT_4_3	0x40
#define	ASPECT_5_4	0x80
#define	ASPECT_16_9	0xc0

/*
 * Fake the monitor EDID until bhyve supports an I2C interface.
 */
DisplayData:

.byte	0x00, 0xff, 0xff, 0xff		# Header
.byte	0xff, 0xff, 0xff, 0x00		# ...
.word	EdidVendorId('B', 'S', 'D')	# VendorID (BSD)
.word	0xfbfb				# ProductID (FreeBSD Framebuffer)
.long	0xffffffff			# No serial number
.byte	35, 31				# Made in week 15 of year 2019
.byte	1, 3				# EDID version 1.3
.byte	0xa0				# Digital input; 8 bits/color
.byte	51, 29				# 51 x 29 cm; that's my monitor
.byte	120				# Gamma value: 2.2

/* Features */
.byte	0x0d	# RGB display; sRGB color space; has preferred timing

/* Chroma Information */
.byte	CHROMA_BITS(sRGB_R_x, 10, 2, 6) | CHROMA_BITS(sRGB_R_y, 10, 2, 4) | \
	CHROMA_BITS(sRGB_G_x, 10, 2, 2) | CHROMA_BITS(sRGB_G_y, 10, 2, 0)
.byte	CHROMA_BITS(sRGB_B_x, 10, 2, 6) | CHROMA_BITS(sRGB_B_y, 10, 2, 4) | \
	CHROMA_BITS(sRGB_W_x, 10, 2, 2) | CHROMA_BITS(sRGB_W_y, 10, 2, 0)
.byte	CHROMA_BITS(sRGB_R_x,  8, 8, 0) , CHROMA_BITS(sRGB_R_y,  8, 8, 0)
.byte	CHROMA_BITS(sRGB_G_x,  8, 8, 0) , CHROMA_BITS(sRGB_G_y,  8, 8, 0)
.byte	CHROMA_BITS(sRGB_B_x,  8, 8, 0) , CHROMA_BITS(sRGB_B_y,  8, 8, 0)
.byte	CHROMA_BITS(sRGB_W_x,  8, 8, 0) , CHROMA_BITS(sRGB_W_y,  8, 8, 0)

.byte	0xff, 0xdf, 0x00			# TimingBits

/* Standard Timing Identification */
.byte	X_RES(1280), ASPECT_16_9  | FREQ(60)	# 1280x720  @ 60Hz
.byte	X_RES(1280), ASPECT_5_4   | FREQ(60)	# 1280x1024 @ 60Hz
.byte	X_RES(1600), ASPECT_16_9  | FREQ(60)	# 1600x900  @ 60Hz
.byte	X_RES(1600), ASPECT_4_3   | FREQ(60)	# 1600x1200 @ 60Hz
.byte	X_RES(1920), ASPECT_16_9  | FREQ(60)	# 1920x1080 @ 60Hz
.byte	X_RES(1920), ASPECT_16_10 | FREQ(60)	# 1920x1200 @ 60Hz
.byte	0x01, 0x01
.byte	0x01, 0x01

/*
 * Detailed Timing Section: EDID Descriptors
 */

/* Preferred: 1920x1080 @ 60Hz; 510x287 mm display; blanking 280H, 45V */
.byte	0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58
.byte	0x2c, 0x45, 0x00, 0xfe, 0x1f, 0x11, 0x00, 0x00, 0x1e

/* Limits: 56-120 Hz vertical, 31-95 kHz horizontal, 250 MHz pixel clock */
.byte	0x00, 0x00, 0x00, 0xfd, 0x00,   56,  120,   31,   95
.byte	  25, 0x00, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20

/* Monitor Name: "VNC1" */
.byte	0x00, 0x00, 0x00, 0xfc, 0x00,  'V',  'N',  'C', '1'
.byte	'\n',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ', ' '

/* Blank for future use */
.byte	0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

.byte	0x00	# No extension blocks
.byte	0x00	# Checksum

/*** Strings ******************************************************************/

STR_AX:
.asciz	"AX: 0x"
STR_BX:
.asciz	"BX: 0x"
STR_CX:
.asciz	"CX: 0x"
STR_DX:
.asciz	"DX: 0x"
STR_SP:
.asciz	"SP: 0x"
STR_BP:
.asciz	"BP: 0x"
STR_SI:
.asciz	"SI: 0x"
STR_DI:
.asciz	"DI: 0x"
STR_CS:
.asciz	"CS: 0x"
STR_DS:
.asciz	"DS: 0x"
STR_SS:
.asciz	"SS: 0x"
STR_ES:
.asciz	"ES: 0x"
STR_EOL:
.asciz	"\r\n"
STR_SEMICOLON:
.asciz	"; "
STR_BSOD_HEADER:
.asciz	"BHYVE VIDEO BIOS - Blue Screen of Death\r\n\r\n"
STR_BSOD_MESSAGE:
.asciz	"\r\nThis BIOS function has been left unimplemented.\r\n"
STR_INCORRECT_CHECKSUM:
.asciz	"Incorrect checksum: 0x"
STR_INITIALIZING:
.asciz	"Initializing Video BIOS.\r\n"
STR_NOT_IMPLEMENTED:
.asciz	"Not implemented!\r\n"
STR_FAILED:
.asciz	"Failed!\r\n"
STR_GOT_HERE:
.asciz	"Got here!\r\n"
STR_VCDA1:
.asciz	"Video Control Data Area 1:\r\n"
STR_VCDA2:
.asciz	"Video Control Data Area 2:\r\n"

.macro	String Label, Text
STR_\Label:
.asciz	"\Text"
.endm

String	BDA_DISPLAY_MODE,	"Current Video Mode:  "
String	BDA_NUMBER_OF_COLUMNS,	"Numer of Columns:    "
String	BDA_VIDEO_PAGE_SIZE,	"Video Page Size:     "
String	BDA_VIDEO_PAGE_OFFSET,	"Video Page Offset:   "
String	BDA_CURSOR_POSITIONS,	"Cursor Positions:    "
String	BDA_CURSOR_TYPE,	"Cursor Type:         "
String	BDA_DISPLAY_PAGE,	"Active Display Page: "
String	BDA_CRTC_BASE,		"CRTC Base I/O Port:  "
String	BDA_3X8_SETTING,	"3x8h I/O Port Value: "
String	BDA_3X9_SETTING,	"3x9h I/O Port Value: "
String	BDA_LAST_ROW_INDEX,	"Last Row Index:      "
String	BDA_CHARACTER_HEIGHT,	"Character Height:    "
String	BDA_VIDEO_MODE_OPTIONS,	"Video Mode Options:  "
String	BDA_VIDEO_FEATURE_BITS,	"EGA Feature Bits:    "
String	BDA_VIDEO_DISPLAY_DATA,	"Video Display Data:  "
String	BDA_DCC_TABLE_INDEX,	"DCC Table Index:     "

/*** Functions ****************************************************************/

/*
 * The main list of implemented BIOS functions.
 *
 * A few functions with higher AH values are handled specially in INT_10h.
 * Note that this array must be immediately followed by the Init function,
 * which is used as the upper array limit in INT_10h.
 */
FunctionArray:
.word	SetVideoMode			# INT 0x10, AH = 0x00
.word	SetCursorType			# INT 0x10, AH = 0x01
.word	SetCursorPosition		# INT 0x10, AH = 0x02
.word	GetCursorPosition		# INT 0x10, AH = 0x03
.word	GetLightPenPosition		# INT 0x10, AH = 0x04
.word	SelectActiveDisplayPage		# INT 0x10, AH = 0x05
.word	ScrollActivePageUp		# INT 0x10, AH = 0x06
.word	ScrollActivePageDown		# INT 0x10, AH = 0x07
.word	ReadCharacterAndAttribute	# INT 0x10, AH = 0x08
.word	WriteCharacterAndAttribute	# INT 0x10, AH = 0x09
.word	WriteCharacter			# INT 0x10, AH = 0x0A
.word	SetColorPalette			# INT 0x10, AH = 0x0B
.word	WriteDot			# INT 0x10, AH = 0x0C
.word	ReadDot				# INT 0x10, AH = 0x0D
.word	WriteTeletypeToActivePage	# INT 0x10, AH = 0x0E
.word	ReadCurrentVideoState		# INT 0x10, AH = 0x0F
.word	HandlePalette			# INT 0x10, AH = 0x10
.word	HandleFont			# INT 0x10, AH = 0x11
.word	AlternateSelect			# INT 0x10, AH = 0x12
.word	WriteString			# INT 0x10, AH = 0x13

/*
 * Power-on initialization.
 *
 * Hooks INT 10h for legacy non-PnP systems.
 *
 * Parameters according to the BIOS Boot Specification version 1.01:
 *
 * ES:DI  Pointer to PnP Installation Check Structure in System BIOS
 *    AX  PFA - PCI Bus/Device/Function (PCI devices only)
 *    CS  Segment address of this option ROM
 *
 * Return values according to Plug and Play BIOS Specification 1.0A:
 *    AX  Status flags; for now, the display is always seen as attached
 */
Init:
	/* Note: Store the PCI Function Address (PFA) for later use */
	/* Note: The option ROM has been shadowed and is write-enabled */
	/* Note: PnP expansion headers can still be modified at this point */

	mov	$STR_INITIALIZING, %ax
	call	PrintString

	/* Use the BIOS Data Area by default */
	push	%ds
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds

	/* Initialize the BIOS Data Area */
	movb	$0x60, BDA_VIDEO_MODE_OPTIONS	# Lots of memory; active; color
	movb	$0x19, BDA_VIDEO_DISPLAY_DATA	# 400-line mode; load palette
	movb	$0x00, BDA_DCC_TABLE_INDEX	# One display with Color VGA
	movw	$SavePointerTable1, BDA_SAVE_POINTER_TABLE
	mov	%cs, (BDA_SAVE_POINTER_TABLE + 0x02)

	/* Fill in the correct segment for ROM pointers */
	mov	%cs, %cs:(SavePointerTable1 + 0x02)
	mov	%cs, %cs:(SavePointerTable1 + 0x12)
	mov	%cs, %cs:(SavePointerTable2 + 0x04)
	mov	%cs, %cs:(VbeInfoBlock + VIB_OemStringPtr + 2)
	mov	%cs, %cs:(VbeInfoBlock + VIB_VideoModePtr + 2)
	mov	%cs, %cs:(VbeInfoBlock + VIB_OemVendorNamePtr + 2)
	mov	%cs, %cs:(VbeInfoBlock + VIB_OemProductNamePtr + 2)
	mov	%cs, %cs:(VbeInfoBlock + VIB_OemProductRevPtr + 2)
	mov	%cs, %cs:(PatchedJump2 + 3)

	/* 32-bit pointers are tricky */
	call	AdjustLongPointers

	/* Keep track of the monitor size */
	call	SaveDisplaySize

	/* Update the checksums */
	call	UpdateChecksums

#ifdef	SPLASH
	call	ShowSplashScreen
#endif
	/* The power-on default mode is 3 */
	mov	$0x0003, %ax
	call	SetVideoMode

#ifndef	TESTING
	/* Don't hook INT 10h here for PnP boots; see BootConnectionVector */
	mov	%es, %ax
	or	%di, %ax
	jnz	0f
#endif
	/* Register INT 10h */
	xor	%ax, %ax
	mov	%ax, %ds
	movw	$INT_10h, 0x40
	mov	%cs, 0x42

#ifdef	TESTING
	call	TestVideoBios
#endif
0:	mov	$0x48, %ax	/* Character output; Display attached */
	pop	%ds
	lret

/*
 * Hooks INT 10h for PnP systems.
 *
 * Parameters according to the Plug and Play BIOS Specification 1.0A:
 *
 *    AX  Bit 1 should be set to connect as primary video (INT 10h)
 * ES:DI  Pointer to PnP Installation Check Structure in System BIOS
 */
BootConnectionVector:
	PushSet	%ax, %ds

	/* Only connect if bit 1 of AX is set */
	test	$0x01, %al
	jz	0f

	/* Register INT 10h */
	xor	%ax, %ax
	mov	%ax, %ds
	movw	$INT_10h, 0x40
	mov	%cs, 0x42

0:	PopSet	%ax, %ds
	lret

/*
 * The main entry point for all graphics support functions.
 *
 * Arguments:
 *      AH - The graphics function to invoke
 */
INT_10h:
	push	%bp
	mov	%sp, %bp
	sub	$6, %sp

	/* Stack variables */
	#define	svBasePointer	-0(%bp)
	#define	svDataSegment	-2(%bp)
	#define	svFunction	-4(%bp)
	#define	svReturnAddress	-6(%bp)

#ifdef	DEBUGGING
	/* Writing to the wrong segment is not unheard of... */
	call	VerifyBiosChecksum

	/* This character will warn us if we forgot a DHeader */
	print	'|'
#endif
	/* Use BIOS Data Area as the default segment */
	mov	%ds, svDataSegment
	push	%ax
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds
	pop	%ax

	/* Reset the bit that blocks debug headers */
	andb	$0xef, BDA_VIDEO_FEATURE_BITS

	/* Push a return address for the function we're jumping to */
	push	%ax
	lea	ReturnFromInterrupt, %ax
	mov	%ax, svReturnAddress
	pop	%ax

	/* Select an entry from the array */
	push	%ax
	mov	%ah, %al
	xor	%ah, %ah
	movw	$FunctionArray, svFunction
	shl	$1, %ax
	add	%ax, svFunction
	pop	%ax
	cmpw	$Init, svFunction
	jae	0f

	/* Read an address from that entry */
	push	%bx
	mov	svFunction, %bx
	mov	%cs:(%bx), %bx
	mov	%bx, svFunction
	pop	%bx

	/* Call the function at that address */
	jmp	*svFunction

0:	/* Try other functions if that didn't work */
	cmp	$0x1a, %ah
	je	HandleDisplayCombinationCode
	cmp	$0x1b, %ah
	je	ReturnFunctionalityAndStateInfo
	cmp	$0x1c, %ah
	je	HandleVideoState
	cmp	$0x4f, %ah
	je	HandleVesaBiosExtension

	/* Block if the function was not implemented */
	JmpNotImplemented	"INT_10h"

/*
 * Restores the original state before returning.
 */
ReturnFromInterrupt:
	add	$2, %sp	# Skip svFunction
	pop	%ds
	pop	%bp
	iret

/*** Official BIOS Functions **************************************************/

/*
 * INT 0x10, AH = 0x00
 *
 * Sets a VGA video mode.
 *
 * Use VBE_SetMode (INT 0x10, AH = 0x4f, AL = 0x02) to set VESA modes.
 *
 * Arguments:
 *      AL - Requested video mode; if bit 7 is set, the buffer is not cleared
 */
SetVideoMode:
	DHeader	"SetVideoMode"
	PushSet	%ax, %bx, %cx, %dx

	/* Save bit 7 of AL in bit 7 of CL */
	mov	%al, %cl
	and	$0x7f, %al
	and	$0x80, %cl

	/* Keep the original mode number */
	mov	%al, %ah

	/* Convert mode number to an entry in the Video Parameter Table */
	call	GetModeEntry
	cmp	$BAD_ENTRY, %bx
	je	5f

	/* Complain if this mode entry is blank */
	movb	%cs:VPT_NUMBER_OF_COLUMNS(%bx), %al
	test	%al, %al
	jnz	0f
	mov	%ah, %al # Restore the original AX state
	or	%cl, %al
	xor	%ah, %ah
	jnz	0f
	JmpNotImplemented	"SetVideoMode"

	/* The new mode looks OK; update the BDA and registers */
0:	call	UpdateBiosDataArea
	call	DisableVideoDisplay
	call	UpdateVgaRegisters

	/* Load a default palette, unless that feature is disabled */
	testb	$0x08, BDA_VIDEO_DISPLAY_DATA
	jz	1f
	call	LoadDefaultPalette

	/* Load the default font if this is an alphanumeric mode */
1:	call	IsTextMode
	jne	2f
	call	LoadDefaultFont

	/* Don't clear the buffer if the retain bit is set */
2:	testb	$0x80, BDA_VIDEO_MODE_OPTIONS
	jnz	3f
	call	ClearVideoBuffer
	call	ClearTextPages

	/* Reset the cursor on all pages */
3:	xor	%dx, %dx	# Cursor to (0,0)
	xor	%bh, %bh	# Start at page 0
	mov	$8, %cx		# At most eight pages
4:	call	SetCursorPosition
	inc	%bh
	loop	4b

	/* Everything is ready; turn on the display */
	call	EnableVideoDisplay

5:	PopSet	%ax, %bx, %cx, %dx
	ret

/*
 * INT 0x10, AH = 0x01
 *
 * Sets the shape of the text cursor. The same shape is used for all pages.
 *
 * Arguments:
 *      CH - Top line for the cursor (0-31)
 *      CL - Bottom line for the cursor (0-31)
 */
SetCursorType:
	DHeader	"SetCursorType"
	PushSet	%ax, %cx, %dx

	/* Save our new type in the BIOS Data Area */
	and	$0x1f1f, %cx
	mov	%cx, BDA_CURSOR_TYPE

	/* Set the new cursor; the macro clobbers AL and DX */
	SetReg	BDA_CRTC_BASE, $CRTR_CURSOR_START, %ch
	SetReg	BDA_CRTC_BASE, $CRTR_CURSOR_END, %cl

	PopSet	%ax, %cx, %dx
	ret

/*
 * INT 0x10, AH = 0x02
 *
 * Sets the cursor position for a given page.
 *
 * Invalid pages are silently ignored. Invalid cursor positions are clamped
 * to the horizontal and vertical ranges allowed for the current video mode.
 * The cursor position specified in DX is left unchanged when this happens.
 *
 * Arguments:
 *      BH - Page number (zero-based)
 *      DH - Row (zero-based)
 *      DL - Column (zero-based)
 */
SetCursorPosition:
	DHeader	"SetCursorPosition"
	PushSet	%ax, %bx, %cx, %dx

	/* Silently ignore page numbers too high for the current mode */
	call	GetPageCount
	cmp	%al, %bh
	jae	3f

	/* Clamp column to the allowed interval */
	cmp	BDA_NUMBER_OF_COLUMNS, %dl
	jb	0f
	mov	BDA_NUMBER_OF_COLUMNS, %dl
	dec	%dl

	/* Clamp row to the allowed interval */
0:	cmp	BDA_LAST_ROW_INDEX, %dh
	jbe	1f
	mov	BDA_LAST_ROW_INDEX, %dh

	/*
	 * Skip the next two blocks if a different page is active.
	 */
1:	cmp	BDA_DISPLAY_PAGE, %bh
	jne	2f

	/*
	 * Calculate a new cursor location for the VGA card. This assumes
	 * that our column count < 256, which means width < 2048 pixels.
	 */
	mov	%dh, %al
	mulb	BDA_NUMBER_OF_COLUMNS
	add	%dl, %al
	adc	$0, %ah

	/* Update the current cursor; the macro clobbers AL and DX */
	mov	%ax, %cx
	mov	%bh, %ah
	mov	%dx, %bx
	SetReg	BDA_CRTC_BASE, $CRTR_CURSOR_LOC_HIGH, %ch
	SetReg	BDA_CRTC_BASE, $CRTR_CURSOR_LOC_LOW, %cl
	mov	%bx, %dx
	mov	%ah, %bh

	/* Update the BIOS Data Area */
2:	mov	%bh, %bl
	xor	%bh, %bh
	shl	$1, %bx
	mov	%dx, BDA_CURSOR_POSITIONS(%bx)

3:	PopSet	%ax, %bx, %cx, %dx
	ret

/*
 * INT 0x10, AH = 0x03
 *
 * Returns row, column, and type of the cursor on a given page.
 *
 * Arguments:
 *      BH - Page number (zero-based)
 *
 * Returns:
 *      DH - Row of the cursor
 *      DL - Column of the cursor
 *      CH - Top scanline of cursor
 *      CL - Bottom scanline of cursor
 */
GetCursorPosition:
	DHeader	"GetCursorPosition"
	PushSet	%ax, %bx

	/* Silently ignore page numbers too high for the current mode */
	call	GetPageCount	# -> %al
	cmp	%al, %bh
	jae	0f

	/* Read data from the BIOS Data Area */
	mov	%bh, %bl
	xor	%bh, %bh
	shl	$1, %bx
	mov	BDA_CURSOR_POSITIONS(%bx), %dx
	mov	BDA_CURSOR_TYPE, %cx

0:	PopSet	%ax, %bx
	ret

/*
 * INT 0x10, AH = 0x04
 *
 * For completeness, says that light pens are indeed not supported.
 *
 * Returns:
 *      AH - Light pen is not supported (0x00)
 *      BX - Pixel column (0x0000)
 *      CX - Raster line (0x0000)
 *      DX - Row/column of character (0,0)
 */
GetLightPenPosition:
	DHeader	"GetLightPenPosition"

	xor	%ah, %ah
	xor	%bx, %bx
	xor	%cx, %cx
	xor	%dx, %dx

	ret

/*
 * INT 0x10, AH = 0x05
 *
 * Selects a page for those VGA modes that have multiple pages in the buffer.
 *
 * Arguments:
 *      AL - The new page number
 */
SelectActiveDisplayPage:
	DHeader	"SelectActiveDisplayPage"
	PushSet	%ax, %bx, %dx

	/* Silently ignore page numbers too high for the current mode */
	mov	%al, %bh
	call	GetPageCount
	cmp	%al, %bh
	jae	0f

	/* Store the page number in the BIOS Data Area */
	mov	%bh, BDA_DISPLAY_PAGE

	/* Store the page offset in bytes */
	mov	%bh, %al
	xor	%ah, %ah
	mulw	BDA_VIDEO_PAGE_SIZE
	mov	%ax, BDA_VIDEO_PAGE_OFFSET

	/* The start address is specified in words */
	mov	%ax, %bx
	shr	$1, %bx

	/* Set the new start address; the macro clobbers AL and DX */
	SetReg	BDA_CRTC_BASE, $CRTR_START_ADDRESS_HIGH, %bh
	SetReg	BDA_CRTC_BASE, $CRTR_START_ADDRESS_LOW, %bl

0:	PopSet	%ax, %bx, %dx
	ret

/*
 * INT 0x10, AH = 0x06
 *
 * Scrolls text upwards on the display. The range for AL is from 0 to +127.
 *
 * Arguments:
 *      AL - Number of lines to scroll; 0x00 to blank the entire window
 *      BH - Attribute to use on blank lines scrolled in at the bottom
 *      CX - Unsigned row/column for upper left corner of the scroll area
 *      DX - Unsigned row/column for lower right corner of the scroll area
 */
ScrollActivePageUp:
	DHeader	"ScrollActivePageUp"
	PushSet	%ax

	test	%al, %al
	jl	0f
	neg	%al
	call	ScrollActivePage

0:	PopSet	%ax
	ret

/*
 * INT 0x10, AH = 0x07
 *
 * Scrolls text downwards on the display. The range for AL is from 0 to +127.
 *
 * Arguments:
 *      AL - Number of lines to scroll; 0x00 to blank the entire window
 *      BH - Attribute to use on blank lines scrolled in at the top
 *      CX - Unsigned row/column for upper left corner of the scroll area
 *      DX - Unsigned row/column for lower right corner of the scroll area
 */
ScrollActivePageDown:
	DHeader	"ScrollActivePageDown"

	test	%al, %al
	jl	0f
	call	ScrollActivePage

0:	ret

/*
 * INT 0x10, AH = 0x08
 *
 * Reads character and attribute at the current cursor position.
 *
 * Arguments:
 *      BH - Page number (zero-based)
 *
 * Returns:
 *      AL - The character
 *      AH - The attribute
 */
ReadCharacterAndAttribute:
	DHeader	"ReadCharacterAndAttribute"
	PushSet	%es, %si

	/* Abort for page numbers too high for the current mode */
	call	GetCharacterAddress	# -> %es:%ax
	jnc	0f

	/* Use source index for address */
	mov	%ax, %si

	/* Read character and attribute */
	es_lodsw

0:	PopSet	%es, %si
	ret

/*
 * INT 0x10, AH = 0x09
 *
 * Writes a given character and attribute at the current cursor position.
 *
 * The cursor position does not change.
 *
 * Arguments:
 *      AL - Character to write
 *      BL - Attribute of character (or color, for graphics modes)
 *      BH - Page number (zero-based)
 *      CX - Count of characters to write
 */
WriteCharacterAndAttribute:
	DHeader	"WriteCharacterAndAttribute"
	PushSet	%ax, %cx, %dx, %es, %di

	/* Check if a text mode is active */
	call	IsTextMode
	je	0f

	/* Otherwise, use a special function */
	call	DrawRepeatedCharacter
	jmp	1f

	/* Store character and attribute in DX for now */
0:	mov	%al, %dl	# %dl = Character
	mov	%bl, %dh	# %dh = Attribute

	/* Abort for page numbers too high for the current mode */
	call	GetCharacterAddress	# -> %es:%ax
	jnc	1f

	/* Write character and attribute */
	mov	%ax, %di
	mov	%dx, %ax
	rep	stosw

1:	PopSet	%ax, %cx, %dx, %es, %di
	ret

/*
 * INT 0x10, AH = 0x0A
 *
 * Writes a given character at the current cursor position.
 *
 * Note: This function should not be used for graphics modes.
 *
 * Arguments:
 *      AL - Character to write
 *      BH - Page number (zero-based)
 *      CX - Count of characters to write
 */
WriteCharacter:
	DHeader	"WriteCharacter"
	PushSet	%ax, %bx, %cx, %di, %es

	/*
	 * According to IBM's BIOS Interface Technical Reference, this function
	 * should not be used in graphics modes, but RBIL suggests that it works
	 * exactly like WriteCharacterAndAttribute if it is, so handle it here.
	 */
	call	IsTextMode
	je	0f
	call	WriteCharacterAndAttribute
	jmp	2f

	/* Store the start position in %es:%di */
0:	mov	%al, %bl
	call	GetCharacterAddress	# -> %es:%ax
	jnc	2f
	mov	%ax, %di
	mov	%bl, %al

	/* Write the character every other byte */
1:	stosb
	inc	%di
	loop	1b

2:	PopSet	%ax, %bx, %cx, %di, %es
	ret

/*
 * INT 0x10, AH = 0x0B
 *
 * Sets color values for 320x200 and 640x200 graphics modes.
 * This will only be relevant if we ever implement those.
 */
SetColorPalette:
	JmpNotImplemented	"SetColorPalette"

/*
 * INT 0x10, AH = 0x0C
 *
 * Writes a pixel to the given display location.
 *
 * This function is only valid for graphics modes up to 256 colors.
 *
 * Arguments:
 *      AL - Color value (bit 7 means XOR except for mode 0x13)
 *      BH - Page number (ignored for single-page modes)
 *      CX - Column number
 *      DX - Row number
 */
WriteDot:
	DHeader	"WriteDot"
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	WriteDot_0x12
	JmpNotImplemented "WriteDot"

/*
 * INT 0x10, AH = 0x0D
 *
 * Reads a pixel from the given display location.
 *
 * This function is only valid for graphics modes up to 256 colors.
 *
 * Arguments:
 *      BH - Page number (ignored for single-page modes)
 *      CX - Column number
 *      DX - Row number
 *
 * Returns:
 *      AL - Color value
 */
ReadDot:
	DHeader	"ReadDot"
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	ReadDot_0x12
	JmpNotImplemented	"ReadDot"

/*
 * INT 0x10, AH = 0x0E
 *
 * Writes a character to the screen with cursor updating and scrolling.
 *
 * The following special characters are handled and do what you might expect:
 *   0x07 (BEL: "\a"), 0x08 (BS: "\b"), 0x0A (LF: "\n"), and 0x0D (CR: "\r")
 *
 * All other characters are simply printed using the current font.
 *
 * Arguments:
 *      AL - Character to write
 *      BL - Foreground color in graphics mode
 */
WriteTeletypeToActivePage:
	DHeader	"WriteTeletypeToActivePage"
	PushSet	%ax, %bx, %cx, %dx

	/* Get the current cursor position */
	mov	%bl, %cl
	mov	BDA_DISPLAY_PAGE, %bl
	xor	%bh, %bh
	shl	$1, %bx
	mov	BDA_CURSOR_POSITIONS(%bx), %dx
	mov	%cl, %bl

	/* Handle carriage return etc. */
	mov	$0x01, %ah	# Update cursor
	call	HandleSpecialChar
	jnc	1f

	/* Write a single character */
	mov	$1, %cx
	call	WriteCharacter

	/* Advance the cursor */
	inc	%dl
	cmp	BDA_NUMBER_OF_COLUMNS, %dl
	jb	0f
	xor	%dl, %dl
	inc	%dh
0:	call	SetCursorPosition

1:	PopSet	%ax, %bx, %cx, %dx
	ret

/*
 * INT 0x10, AH = 0x0F
 *
 * Returns information about the current video state.
 *
 * Returns:
 *      AL - Mode currently set (includes bit 7 if set)
 *      AH - Number of character columns on screen
 *      BH - Current active page number (zero-based)
 */
ReadCurrentVideoState:
	DHeader	"ReadCurrentVideoState"

	/* According to RBIL, bit 7 should be in the mode */
	mov	BDA_VIDEO_MODE_OPTIONS, %al
	and	$0x80, %al
	or	BDA_DISPLAY_MODE, %al

	/* Set number of columns and page number */
	mov	BDA_NUMBER_OF_COLUMNS, %ah
	mov	BDA_DISPLAY_PAGE, %bh

	ret

/*
 * INT 0x10, AH = 0x10
 *
 * Branches off to one of several functions, not all of which are implemented.
 *
 * AL - Subfunction
 *     0x00 - Set individual palette register
 *     0x01 - Set overscan register
 *     0x02 - Set all palette registers and overscan
 *     0x03 - Toggle intensify/blinking bit
 *     0x07 - Read individual palette register
 *     0x08 - Read overscan register
 *     0x09 - Read all palette registers and overscan
 *     0x10 - Set individual color register
 *     0x12 - Set block of color registers
 *     0x13 - Select color page (not valid for mode 0x13)
 *     0x15 - Read individual color register
 *     0x17 - Read block of color registers
 *     0x1A - Read color page state
 *     0x1B - Sum color values to gray shades
 */
HandlePalette:
	cmp	$0x00, %al
	je	HandlePalette_SetIndividualPaletteRegister
	cmp	$0x02, %al
	je	HandlePalette_SetAllPaletteRegistersAndOverscan
	cmp	$0x10, %al
	je	HandlePalette_SetIndividualColorRegister
	cmp	$0x12, %al
	je	HandlePalette_SetBlockOfColorRegisters
	JmpNotImplemented	"HandlePalette"

/*
 * INT 0x10, AH = 0x10, AL = 0x00
 *
 * Sets one of the 16 VGA palette registers (0x00 - 0x0F).
 *
 * Also, since we're trying to be backwards compatible with the
 * original unconstrained implementation, this function can be
 * used to set any other Attribute Controller register.
 *
 * Arguments:
 *      BL - Palette register to set
 *      BH - Value to set
 */
HandlePalette_SetIndividualPaletteRegister:
	DHeader	"HandlePalette_SetIndividualPaletteRegister"
	PushSet	%ax, %dx

	/* Reset the flip-flop before writing anything */
	call	ClearAttributeFlipFlop

	/* Write to the register */
	mov	$PORT_ATR, %dx
	mov	%bl, %al
	outb	%al, %dx
	mov	%bh, %al
	outb	%al, %dx

	PopSet	%ax, %dx
	ret

/*
 * INT 0x10, AH = 0x10, AL = 0x02
 *
 * Sets all VGA palette registers plus the overscan (border) color register.
 *
 * Note that this BIOS currently configures a zero-pixel border width.
 *
 * Arguments:
 *   ES:DX - Pointer to 17-byte table (16 palette bytes + 1 overscan byte)
 */
HandlePalette_SetAllPaletteRegistersAndOverscan:
	DHeader	"HandlePalette_SetAllPaletteRegistersAndOverscan"
	PushSet	%ax, %bx, %cx, %dx, %si

	/* Reset the flip-flop before writing anything */
	call	ClearAttributeFlipFlop

	/* Prepare for the loop */
	mov	%dx, %si
	mov	$PORT_ATR, %dx
	xor	%bl, %bl
	mov	$17, %cx

	/* Select register */
0:	mov	%bl, %al
	outb	%al, %dx	# Write index

	/* Read byte from table */
	es_lodsb

	/* Write byte to register */
	outb	%al, %dx	# Write data
	inc	%bl
	cmp	$0x10, %bl	# Skip Attribute Mode Control Register
	jne	1f
	inc	%bl
1:	loop	0b
	inc	%bl

	PopSet	%ax, %bx, %cx, %dx, %si
	ret

/*
 * INT 0x10, AH = 0x10, AL = 0x10
 *
 * Sets RGB values for an individual video DAC color register.
 *
 * The Digital-to-Analog Converter (DAC) has 256 18-bit color registers.
 * These are sometimes known as palette registers, but should not be
 * confused with the 16 internal palette registers originally used for
 * EGA graphics. The value of each internal 6-bit palette register is
 * used as an address to one of the initial 64 DAC color registers.
 *
 * Arguments:
 *      BX - Color register to set
 *      CL - Blue value to set
 *      CH - Green value to set
 *      DH - Red value to set
 */
HandlePalette_SetIndividualColorRegister:
	DHeader	"HandlePalette_SetIndividualColorRegister"
	PushSet	%ax, %dx

	/* Select the color register */
	mov	$PORT_PALETTE_WRITE, %dx
	mov	%bl, %al
	outb	%al, %dx

	/* Write the red value */
	mov	$PORT_PALETTE_DATA, %dx
	mov	%dh, %al
	outb	%al, %dx

	/* Write the green value */
	mov	%ch, %al
	outb	%al, %dx

	/* Write the blue value */
	mov	%cl, %al
	outb	%al, %dx

	PopSet	%ax, %dx
	ret

/*
 * INT 0x10, AH = 0x10, AL = 0x12
 *
 * Sets RGB values for multiple DAC color registers at once.
 *
 * Arguments:
 *      BX - First color register to set
 *      CX - Number of color registers to set
 *   ES:DX - Pointer to table of color values (Order: RGB)
 */
HandlePalette_SetBlockOfColorRegisters:
	DHeader	"HandlePalette_SetBlockOfColorRegisters"
	PushSet	%ax, %bx, %cx, %dx, %si

	/* Move the pointer to a more useful register */
	mov	%dx, %si

	/* Select the color register */
0:	mov	$PORT_PALETTE_WRITE, %dx
	mov	%bl, %al
	outb	%al, %dx
	inc	%bl

	/* Write the color data */
	mov	$PORT_PALETTE_DATA, %dx
	es	lodsb
	outb	%al, %dx
	es	lodsb
	outb	%al, %dx
	es	lodsb
	outb	%al, %dx

	loop	0b

	PopSet	%ax, %bx, %cx, %dx, %si
	ret

/*
 * INT 0x10, AH = 0x11
 *
 * Branches off to one of several functions, not all of which are implemented.
 *
 * AL - Subfunction
 *     0x00 - User alpha load
 *     0x01 - ROM 8x14 font
 *     0x02 - ROM 8x8 double dot font
 *     0x03 - Set block specifier (valid in alpha modes)
 *     0x04 - ROM 8x16 font
 *     0x10 - User alpha load
 *     0x11 - ROM 8x14 font
 *     0x12 - ROM 8x8 double dot font
 *     0x14 - ROM 8x16 font
 *     0x20 - Set user graphics characters pointer at INT 0x1F
 *     0x21 - Set user graphics characters pointer at INT 0x43
 *     0x22 - ROM 8x14 font
 *     0x23 - ROM 8x8 double dot font
 *     0x24 - ROM 8x16 font
 *     0x30 - Information
 */
HandleFont:
	cmp	$0x00, %al
	je	HandleFont_UserAlphaLoad
	cmp	$0x30, %al
	je	HandleFont_Information
	JmpNotImplemented	"HandleFont"

/*
 * INT 0x10, AH = 0x11, AL = 0x00
 *
 * Loads a user-specified font.
 *
 * This function causes a mode set, resetting the video environment
 * without clearing the video buffer.
 *
 * Arguments:
 *   ES:BP - Pointer to user table
 *      BL - Block to load
 *      BH - Number of bytes per character
 *      CX - Count to store
 *      DX - Character offset into block
 */
HandleFont_UserAlphaLoad:
	PushSet	%ax, %bx, %dx, %bp, %di, %ds

	/* Restore the original %bp value */
	mov	svBasePointer, %bp

	/* Load the new font */
	mov	%es, %ax
	mov	%ax, %ds
	mov	%bp, %ax
	mov	%dx, %di
	mov	%bl, %dh
	mov	%bh, %dl
	mov	$EmptyTable, %bx
	call	LoadFont

	/* Reset without clearing the buffer */
	mov	BDA_DISPLAY_MODE, %al
	or	$0x80, %al
	call	SetVideoMode

	PopSet	%ax, %bx, %dx, %bp, %di, %ds
	ret

/*
 * INT 0x10, AH = 0x11, AL = 0x30
 *
 * Returns the pointer to a requested font table.
 *
 * Arguments:
 *      BH - Font pointer selector
 *          0x00 - Return current INT 0x1F pointer
 *          0x01 - Return current INT 0x43 pointer
 *          0x02 - Return ROM 8x14 font pointer
 *          0x03 - Return ROM 8x8 font pointer
 *          0x04 - Return ROM 8x8 font pointer (top)
 *          0x05 - Return ROM 9x14 font alternate
 *          0x06 - Return ROM 8x16 font pointer
 *          0x07 - Return ROM 9x16 font alternate
 *
 * Returns:
 *   ES:BP - Pointer to table
 *      CX - Points (bytes per character of on-screen font)
 *      DL - Rows (number of character rows on screen - 1)
 */
HandleFont_Information:
	DHeader	"HandleFont_Information"

	/* Handle the fonts we have */

	cmp	$0x00, %bh	# Current INT 0x1F pointer
	jne	0f
	push	%ds
	xor	%cx, %cx
	mov	%cx, %ds
	mov	0x007c, %cx
	mov	%cx, svBasePointer
	mov	0x007e, %es
	pop	%ds
	jmp	9f

0:	cmp	$0x01, %bh	# Current INT 0x43 pointer
	jne	5f
	push	%ds
	xor	%cx, %cx
	mov	%cx, %ds
	mov	0x010c, %cx
	mov	%cx, svBasePointer
	mov	0x010e, %es
	pop	%ds
	jmp	9f

5:	cmp	$0x06, %bh	# ROM 8x16 font
	jne	6f
	movw	$Font_8x16, svBasePointer
	jmp	8f

6:	cmp	$0x07, %bh	# ROM 9x16 font alternate
	jne	7f
	movw	$Font_9x16, svBasePointer
	jmp	8f

	/* Would it be better to return a NULL pointer? */
7:	JmpNotImplemented	"HandleFont_Information"

	/* Set the remaining return values */
8:	mov	%cs, %cx
	mov	%cx, %es
9:	movw	BDA_CHARACTER_HEIGHT, %cx
	movb	BDA_LAST_ROW_INDEX, %dl

	ret

/*
 * INT 0x10, AH = 0x12
 *
 * Branches off to one of several functions, not all of which are implemented.
 *
 * BL - Subfunction
 *     0x10 - Return EGA information
 *     0x20 - Select alternate print screen routine
 *     0x30 - Select scan lines for alphanumeric modes
 *     0x31 - Default palette loading during set mode
 *     0x32 - Video addressing
 *     0x33 - Summing to gray shades
 *     0x34 - Cursor emulation
 *     0x35 - Display switch
 */
AlternateSelect:
	cmp	$0x10, %bl	# Return EGA information
	je	AlternateSelect_ReturnEgaInformation
	cmp	$0x30, %bl	# Select scan lines for alphanumeric modes
	je	AlternateSelect_ScanLines
	cmp	$0x31, %bl	# Default palette loading during set mode
	je	AlternateSelect_DefaultPaletteLoading
	cmp	$0x34, %bl	# Cursor emulation
	je	AlternateSelect_CursorEmulation
	JmpNotImplemented	"AlternateSelect"

/*
 * INT 0x10, AH = 0x12, BL = 0x10
 *
 * Returns some potentially interesting EGA-related information.
 *
 * This function can be used to check for the presence of EGA+ graphics cards.
 *
 * Returns:
 *      BH - 0x00 for color modes; 0x01 for monochrome modes
 *      BL - Memory: 0 for 64 KiB, 1 for 128 KiB, 2 for 192 KiB, 3 for 256 KiB
 *      CH - Adapter bits
 *      CL - Switch setting
 */
AlternateSelect_ReturnEgaInformation:
	DHeader	"AlternateSelect_ReturnEgaInformation"

	/* Set the BH register value */
	cmpb	$0x07, BDA_DISPLAY_MODE
	jne	0f
	mov	$0x01, %bh
0:	cmpb	$0x0F, BDA_DISPLAY_MODE
	jne	1f
	mov	$0x01, %bh
	jmp	2f
1:	xor	%bh, %bh

2:	mov	$0x03, %bl	# 256 KiB
	xor	%cx, %cx	# Not implemented

	ret

/*
 * INT 0x10, AH = 0x12, BL = 0x30
 *
 * Select scan lines for alphanumeric modes.
 *
 * Arguments:
 *      AL - Code for the number of scan lines
 *          0 - 200 scan lines
 *          1 - 350 scan lines
 *          2 - 400 scan lines
 *
 * Returns:
 *      AL - 0x12 (Function supported)
 */
AlternateSelect_ScanLines:
	DHeader	"AlternateSelect_ScanLines"

	/* The number of scan lines is coded in this byte */
	mov	BDA_VIDEO_DISPLAY_DATA, %ah

	cmp	$0, %al		# 200 scan lines
	jne	2f
	or	$0x80, %ah	# Bit 7 = 1
	and	$0xef, %ah	# Bit 4 = 0
	jmp	4f

2:	cmp	$1, %al		# 350 scan lines
	jne	3f
	and	$0x5f, %ah	# Bit 7 = 0; Bit 4 = 0
	jmp	4f

3:	cmp	$2, %al		# 400 scan lines
	jne	5f
	and	$0x7f, %ah	# Bit 7 = 0
	or	$0x10, %ah	# Bit 4 = 1

4:	mov	%ah, BDA_VIDEO_DISPLAY_DATA
	mov	$0x1212, %ax
5:	ret

/*
 * INT 0x10, AH = 0x12, BL = 0x31
 *
 * Specifies whether a default palette should be loaded by SetDisplayMode.
 *
 * Arguments:
 *      AL - 0x00 to enable; 0x01 to disable
 *
 * Returns:
 *      AL - 0x12 (Function supported)
 */
AlternateSelect_DefaultPaletteLoading:
	DHeader	"AlternateSelect_DefaultPaletteLoading"

	/* Check for illegal AL values */
	test	$0xfe, %al
	jnz	2f

	/* Store this setting in the BIOS Data Area */
	test	%al, %al
	jz	0f
	andb	$0xf7, BDA_VIDEO_DISPLAY_DATA
	jmp	1f
0:	orb	$0x08, BDA_VIDEO_DISPLAY_DATA

1:	mov	$0x12, %al
2:	ret

/*
 * INT 0x10, AH = 0x12, BL = 0x34
 *
 * Specifies whether the BIOS should automatically remap cursor start/end
 * according to the current character height in text modes.
 *
 * TODO: We store the setting, but don't actually use it at the moment.
 *
 * Arguments:
 *      AL - 0x00 to enable; 0x01 to disable
 *
 * Returns:
 *      AL - 0x12 (Function supported)
 */
AlternateSelect_CursorEmulation:
	DHeader	"AlternateSelect_CursorEmulation"

	/* Check for illegal AL values */
	test	$0xfe, %al
	jnz	0f

	/* Store this setting in the BIOS Data Area */
	andb	$0xfe, BDA_VIDEO_MODE_OPTIONS
	or	%al, BDA_VIDEO_MODE_OPTIONS

	mov	$0x12, %al
0:	ret

/*
 * INT 0x10, AH = 0x13
 *
 * Writes a string to the screen with cursor updating and scrolling.
 *
 * The following special characters are handled and do what you might expect:
 *   0x07 (BEL: "\a"), 0x08 (BS: "\b"), 0x0A (LF: "\n"), and 0x0D (CR: "\r")
 *
 * All other characters are simply printed using the current font.
 *
 * Arguments:
 *   ES:BP - Pointer to string
 *      AL - Write mode (bit 0: update cursor; bit 1: attributes in string)
 *      BH - Page number (zero-based)
 *      CX - Character count
 *      DH - Start row
 *      DL - Start column
 */
WriteString:
	DHeader	"WriteString"
	PushSet	%ax, %bx, %cx, %dx, %bp

	/* Restore the original %bp value */
	mov	svBasePointer, %bp

	/* Temporarily change the page */
	mov	BDA_DISPLAY_PAGE, %bl
	mov	%bh, BDA_DISPLAY_PAGE
	push	%bx

	/* Possibly save the cursor position */
	test	$0x01, %al
	jnz	0f
	push	%cx
	call	GetCursorPosition
	pop	%cx
	push	%dx

	/* Write the string one character at a time */
0:	call	WriteSingleStringCharacter
	loop	0b

	/* Restore the cursor position if it was saved */
	test	$0x01, %al
	jnz	6f
	pop	%dx
	call	SetCursorPosition

	/* Restore the original BDA values */
6:	pop	%bx
	mov	%bl, BDA_DISPLAY_PAGE

	PopSet	%ax, %bx, %cx, %dx, %bp
	ret

/*
 * INT 0x10, AH = 0x1A
 *
 * AL - Subfunction
 *     0x00 - Read display combination code
 *     0x01 - Write display combination code
 */
HandleDisplayCombinationCode:
	cmp	$0x00, %al
	je	ReadDisplayCombinationCode
	cmp	$0x01, %al
	je	WriteDisplayCombinationCode
	JmpNotImplemented	"HandleDisplayCombinationCode"

/*
 * INT 0x10, AH = 0x1A, AL = 0x00
 *
 * Returns codes describing the active display and any alternate display.
 *
 * This function is sometimes used to check for the presence of VGA.
 * The other display codes are obsolete.
 *
 * Returns:
 *      AL - 0x1A (Function supported)
 *      BL - Active display code
 *      BH - Alternate display code
 */
ReadDisplayCombinationCode:
	DHeader	"ReadDisplayCombinationCode"

	mov	$0x0008, %bx	# VGA with color analog display
	mov	$0x1a, %al	# Function supported

	ret

/*
 * INT 0x10, AH = 0x1A, AL = 0x01
 *
 * Does not write the display combination code.
 *
 * This function is here for completeness, but is left unimplemented.
 * My best guess is that the expected behavior is to update the value
 * in BDA_DCC_TABLE_INDEX and have a long list of valid combinations
 * stored in DisplayCombinationCodeTable, but I'm just guessing.
 *
 * Arguments:
 *      BL - Active display code
 *      BH - Alternate display code
 *
 * Returns:
 *      AL - 0x1A (Function supported)
 */
WriteDisplayCombinationCode:
	JmpNotImplemented	"WriteDisplayCombinationCode"

/*
 * INT 0x10, AH = 0x1B
 *
 * Returns functionality/state information better documented elsewhere.
 *
 * Arguments:
 *   ES:DI - 64-byte buffer for state information
 *      BX - Implementation type (must be 0x0000)
 *
 * Returns:
 *      AL - 0x1B (Function supported)
 */
ReturnFunctionalityAndStateInfo:
	DHeader	"ReturnFunctionalityAndStateInfo"
	PushSet	%bx, %cx, %si, %di

	cmp	$0x0000, %bx
	jne	0f

	/* Write location of static functionality */
	movw	$StaticFunctionalityTable, %es:0x00(%di)
	movw	%cs, %es:0x02(%di)

	/* Copy Video Control Data Area 1 */
	push	%di
	add	$4, %di
	mov	BDA_DISPLAY_MODE, %si
	mov	$16, %cx
	rep	movsb
	pop	%di

	/* Unfortunately, this is not just VCDA2 */
	movb	BDA_LAST_ROW_INDEX, %bl
	movb	%bl, %es:0x22(%di)
	movw	BDA_CHARACTER_HEIGHT, %bx
	movw	%bx, %es:0x23(%di)
	movb	$0x08, %es:0x25(%di)	# Active DCC
	movb	$0x00, %es:0x26(%di)	# Alternate DCC
	movb	BDA_DISPLAY_MODE, %bl
	xor	%bh, %bh
	shl	$1, %bx
	movw	%cs:ColorCountArray(%bx), %bx
	movw	%bx, %es:0x27(%di)
	call	GetPageCount	# -> al
	movb	%al, %es:0x29(%di)

	/* Write a code for the number of scan lines */
	mov	BDA_VIDEO_DISPLAY_DATA, %bl
	and	$0x90, %bl
	cmp	$0x80, %bl	# 200 scan lines
	jne	0f
	movb	$0x00, %es:0x2a(%di)
	jmp	3f
0:	cmp	$0x00, %bl	# 350 scan lines
	jne	1f
	movb	$0x01, %es:0x2a(%di)
	jmp	3f
1:	cmp	$0x10, %bl	# 400 scan lines
	jne	2f
	movb	$0x02, %es:0x2a(%di)
	jmp	3f
2:	movb	$0xff, %es:0x2a(%di)

	/* Write the remaining info */
3:	movb	$0x00, %es:0x2b(%di)	# Primary character block
	movb	$0x00, %es:0x2c(%di)	# Secondary character block
	mov	$0x01, %bl		# All modes on all displays
	testb	$0x08, BDA_VIDEO_DISPLAY_DATA
	jnz	4f
	or	$0x08, %bl		# Default palette loading disabled
4:	testb	$0x01, BDA_VIDEO_MODE_OPTIONS
	jnz	5f
	or	$0x10, %bl		# Cursor emulation enabled
5:	movb	%bl, %es:0x2d(%di)
	movb	$0x00, %es:0x2e(%di)	# Unsupported features
	movb	$0x00, %es:0x2f(%di)	# Reserved
	movb	$0x00, %es:0x30(%di)	# Reserved
	movb	$0x03, %es:0x31(%di)	# 256 KiB VGA memory
	movb	$0x00, %es:0x32(%di)	# Unsupported features
	movb	$0x04, %es:0x33(%di)	# Color display

	/* Clear twelve reserved bytes */
	xor	%al, %al
	mov	$12, %cx
	add	$0x34, %di
	rep	stosb

	mov	$0x1b, %al

0:	PopSet	%bx, %cx, %si, %di
	ret

/*
 * INT 0x10, AH = 0x1C
 *
 * AL - Subfunction
 *     0x00 - Return save/restore state buffer size
 *     0x01 - Save state
 *     0x02 - Restore state
 */
HandleVideoState:
	cmp	$0x00, %al
	je	ReturnStateBufferSize
	cmp	$0x01, %al
	je	SaveVideoState
	cmp	$0x02, %al
	je	RestoreVideoState
	JmpNotImplemented	"HandleVideoState"

/*
 * INT 0x10, AH = 0x1C, AL = 0x00
 *
 * Returns the buffer size needed for SaveVideoState.
 *
 * Arguments:
 *      CX - Requested states
 *          0x01 - Video hardware state
 *          0x02 - Video BIOS Data Area
 *          0x04 - Video DAC state and color registers
 *
 * Returns:
 *      AL - 0x1c (Function supported)
 *      BX - Number of 64-byte blocks for buffer
 */
ReturnStateBufferSize:
	DHeader	"ReturnStateBufferSize"
	PushSet	%cx

	xor	%bx, %bx

	/* 70 bytes of VGA hardware state (see RBIL for layout) */
	test	$0x01, %cx
	jz	0f
	add	$70, %bx

	/* 96 bytes of BIOS Data Area (including non-video stuff) */
0:	test	$0x02, %cx
	jz	1f
	add	$96, %bx

	/* 772 bytes of DAC state and color registers */
1:	test	$0x04, %cx
	jz	2f
	add	$772, %bx

	/* 6 bytes of bhyve register state (for VBE_ReturnStateBufferSize) */
2:	cmp	$0x4f04, %ax	# Only do this for that function
	jne	3f
	test	$0x08, %cx
	jz	3f
	add	$6, %bx

	/* Calculate the number of 64-byte blocks */
3:	add	$63, %bx
	mov	$6, %cl
	shr	%cl, %bx

	mov	$0x1c, %al
	PopSet	%cx
	ret

/*
 * INT 0x10, AH = 0x1C, AL = 0x01
 *
 * Saves the current video state for later use with RestoreVideoState.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      CX - Requested states
 *          0x01 - Video hardware state
 *          0x02 - Video BIOS Data Area
 *          0x04 - Video DAC state and color registers
 *
 * Returns:
 *      AL - 0x1c (Function supported)
 */
SaveVideoState:
	DHeader	"SaveVideoState"
	PushSet	%di

	/* This index is passed between the subfunctions */
	xor	%di, %di

	test	$0x01, %cx
	jne	0f
	call	SaveVideoState_Hardware

0:	test	$0x02, %cx
	jne	1f
	call	SaveVideoState_BiosDataArea

1:	test	$0x04, %cx
	jne	2f
	call	SaveVideoState_DacAndColor

2:	mov	$0x1c, %al
	PopSet	%di
	ret

/*
 * INT 0x10, AH = 0x1C, AL = 0x02
 *
 * Restores a video state previously saved by SaveVideoState.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      CX - Requested states
 *          0x01 - Video hardware state
 *          0x02 - Video BIOS Data Area
 *          0x04 - Video DAC state and color registers
 *
 * Returns:
 *      AL - 0x1c (Function supported)
 */
RestoreVideoState:
	DHeader	"RestoreVideoState"
	PushSet	%si

	/* This index is passed between the subfunctions */
	xor	%si, %si

	test	$0x01, %cx
	jne	0f
	call	RestoreVideoState_Hardware

0:	test	$0x02, %cx
	jne	1f
	call	RestoreVideoState_BiosDataArea

1:	test	$0x04, %cx
	jne	2f
	call	RestoreVideoState_DacAndColor

2:	mov	$0x1c, %al
	PopSet	%si
	ret

/*** VESA BIOS Extension ******************************************************/

/*
 * INT 0x10, AH = 0x4f
 *
 * Video Electronics Standards Association (VESA) BIOS Extension (VBE).
 *
 * AL - Subfunction
 *     0x00 - Return VBE Controller Information
 *     0x01 - Return VBE Mode Information
 *     0x02 - Set VBE Mode
 *     0x03 - Return Current VBE Mode
 *     0x04 - Save/Restore State
 *     0x05 - Display Window Control
 *     0x06 - Set/Get Logical Scan Line Length
 *     0x07 - Set/Get Display Start
 *     0x08 - Set/Get DAC Palette Format
 *     0x09 - Set/Get Palette Data
 *     0x0A - Return VBE Protected Mode Interface
 *     0x0B - Get/Set Pixel Clock
 *
 * AL - Supplemental Specifications
 *     0x10 - Power Management Extensions (PM)
 *     0x11 - Flat Panel Interface Extensions (FP)
 *     0x13 - Audio Interface Extensions (AI)
 *     0x14 - OEM Extensions
 *     0x15 - Display Data Channel (DDC)
 */
HandleVesaBiosExtension:
	cmp	$0x00, %al
	je	VBE_ReturnControllerInfo
	cmp	$0x01, %al
	je	VBE_ReturnModeInfo
	cmp	$0x02, %al
	je	VBE_SetMode
	cmp	$0x03, %al
	je	VBE_ReturnCurrentMode
	cmp	$0x04, %al
	je	VBE_HandleState
	cmp	$0x05, %al
	je	VBE_DisplayWindowControl
	cmp	$0x06, %al
	je	VBE_HandleLogicalScanLineLength
	cmp	$0x07, %al
	je	VBE_HandleDisplayStart
	cmp	$0x08, %al
	je	VBE_HandleDacPaletteFormat
	cmp	$0x09, %al
	je	VBE_HandlePaletteData
	cmp	$0x0b, %al
	je	VBE_HandlePixelClock
	cmp	$0x10, %al
	je	VBE_PowerManagement
	cmp	$0x14, %al
	je	VBE_OemExtensions
	cmp	$0x15, %al
	je	VBE_DisplayDataChannel
	/* Not supported, return 0 in AL. */
	xor	%al, %al
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x00
 *
 * Provides general information about installed VBE software and hardware.
 *
 * Arguments:
 *   ES:DI - Pointer to buffer for VbeInfoBlock structure
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_ReturnControllerInfo:
	DHeader	"VBE_ReturnControllerInfo"
	PushSet	%cx, %si, %di, %ds
	cld

	/*
	 * This function is called by the X11 int10 module, with an internal
	 * x86 emulator that seems to have a problem with double instruction
	 * prefixes like in "repe cs cmpsb" or "rep cs movsb", so we change
	 * the default data segment instead. We don't need the BDA anyway.
	 */
	mov	%cs, %ax
	mov	%ax, %ds

	/* Check how many bytes we should return */
	lea	VBE2, %si
	mov	$4, %cx
	mov	%di, %ax
	rep	cmpsb
	je	1f
	mov	$VBE1_VIB_SIZE, %cx
	jmp	2f
1:	mov	$VBE2_VIB_SIZE, %cx

	/* Copy the VbeInfoBlock data */
2:	mov	%ax, %di
	lea	VbeInfoBlock, %si
	rep	movsb

	mov	$0x004f, %ax
	PopSet	%cx, %si, %di, %ds
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x01
 *
 * Returns detailed information about a specific VBE display mode.
 *
 * Arguments:
 *   ES:DI - Pointer to buffer for ModeInfoBlock structure
 *      CX - Mode number
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_ReturnModeInfo:
	DHeader	"VBE_ReturnModeInfo"
	PushSet	%bx, %cx, %dx, %si, %di, %ds
	cld

	/*
	 * This function is called by the X11 int10 module, with an internal
	 * x86 emulator that seems to have a problem with double instruction
	 * prefixes like in "repe cs cmpsb" or "rep cs movsb", so we change
	 * the default data segment instead. We don't need the BDA anyway.
	 */
	mov	%cs, %ax
	mov	%ax, %ds

	/* Find the mode information */
	call	GetVbeModeInfo	# -> %cs:%bx
	jnc	3f

	/* Copy the information */
1:	lea	ModeInfoBlock, %si
	mov	$MIB_STRUCT_SIZE, %cx
	mov	%di, %ax
	rep	movsb
	mov	%ax, %di

	/* Update the framebuffer pointer */
	mov	(PhysBasePtr+0), %ax
	mov	%ax, %es:(MIB_PHYS_BASE_PTR+0)(%di)
	mov	(PhysBasePtr+2), %ax
	mov	%ax, %es:(MIB_PHYS_BASE_PTR+2)(%di)

	/* Update width, height, depth, and bytes per scan line */
	mov	MIA_HEIGHT(%bx), %ax
	mov	%ax, %es:MIB_Y_RESOLUTION(%di)
	mov	MIA_WIDTH(%bx), %ax
	mov	%ax, %es:MIB_X_RESOLUTION(%di)
	mov	MIA_DEPTH(%bx), %dx
	mov	%dx, %es:MIB_BITS_PER_PIXEL(%di)
	shr	$1, %dx
	shr	$1, %dx
	shr	$1, %dx
	mul	%dx	# %ax *= (bits_per_pixel / 8)
	mov	%ax, %es:MIB_BYTES_PER_SCAN_LINE(%di)
	mov	%ax, %es:MIB_LIN_BYTES_PER_SCAN_LINE(%di)
	call	UpdateModeAttributes

	/* Clear the reserved bits for 24-bit modes */
	cmp	$24, %ax
	jne	2f
	xor	%al, %al
	mov	%al, %es:MIB_RSVD_MASK_SIZE(%di)
	mov	%al, %es:MIB_RSVD_FIELD_POSITION(%di)
	mov	%al, %es:MIB_LIN_RSVD_MASK_SIZE(%di)
	mov	%al, %es:MIB_LIN_RSVD_FIELD_POSITION(%di)

	/* Calculate max pixel clock */
2:	mov	MIA_WIDTH(%bx), %ax
	mulw	MIA_HEIGHT(%bx)
	mov	%dx, %cx
	mulw	RefreshRateHz
	mov	%ax, %bx
	mov	%cx, %ax
	mov	%dx, %cx
	mulw	RefreshRateHz
	add	%ax, %cx

	/* Update max pixel clock */
	mov	%bx, %es:(MIB_MAX_PIXEL_CLOCK+0)(%di)
	mov	%cx, %es:(MIB_MAX_PIXEL_CLOCK+2)(%di)
	jmp	4f

	/* Complain if the mode was invalid */
3:	mov	$0x014f, %ax
	jmp	5f

4:	mov	$0x004f, %ax
5:	PopSet	%bx, %cx, %dx, %si, %di, %ds
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x02
 *
 * Initializes the controller and sets a VBE mode.
 *
 * Arguments:
 *   ES:DI - Pointer to CRTCInfoBlock structure
 *      BX - Mode to set
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SetMode:
	DHeader	"VBE_SetMode"
	PushSet	%bx, %cx, %dx

	/* Keep bit D15 */
	mov	%bx, %ax
	and	$0x8000, %ax

	/* Ignore all other flags */
	and	$0x01ff, %bx

	/* Find the information for this mode */
	mov	%bx, %cx
	call	GetVbeModeInfo	# -> %bx
	jnc	1f

#ifdef	ALLOW_PROTECTED_MODE
	/* Clear the buffer unless bit D15 was set */
	test	$0x8000, %ax
	jnz	0f
	call	ClearVesaBuffer
#endif
	/* Set the framebuffer dimensions */
0:	PushSet	%bx, %bp
	mov	%bx, %bp
	mov	%cs:MIA_WIDTH(%bp), %ax
	mov	%cs:MIA_HEIGHT(%bp), %bx
	mov	%cs:MIA_DEPTH(%bp), %cx
	call	SetBufferShape
	PopSet	%bx, %bp

	/* Remember the mode index */
	lea	ModeInfoArray, %ax
	sub	%bx, %ax
	neg	%ax
	mov	$MIA_STRUCT_SIZE, %cl
	div	%cl		# %al = (%bx - ModeInfoArray) / $MIA_STRUCT_SIZE
	or	$0x40, %al	# A bit to distinguish VBE modes
	mov	%al, BDA_DISPLAY_MODE

	/* Complain if the mode was invalid */
	jmp	2f
1:	mov	$0x014f, %ax
	jmp	3f

2:	mov	$0x004f, %ax
3:	PopSet	%bx, %cx, %dx
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x03
 *
 * Returns the mode number as previously set via VBE_SetMode.
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Mode number
 */
VBE_ReturnCurrentMode:
	DHeader	"VBE_ReturnCurrentMode"

	/* Check if a VBE mode is set */
	movb	BDA_DISPLAY_MODE, %al
	test	$0x40, %al
	jz	0f

	/* Find the corresponding mode entry */
	and	$0x3f, %al
	mov	$MIA_STRUCT_SIZE, %bl
	mulb	%bl
	add	$ModeInfoArray, %ax
	mov	%ax, %bx

	/* Extract the mode number */
	mov	%cs:MIA_MODE(%bx), %bx
	or	$0x4000, %bx	# Linear frame buffer
	jmp	1f

	/* "Function call invalid in current video mode" */
0:	mov	$0x034f, %ax
	jmp	2f

1:	mov	$0x004f, %ax
2:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x04
 *
 * DL - Subfunction
 *     0x00 - Return Save/Restore State buffer size
 *     0x01 - Save state
 *     0x02 - Restore state
 */
VBE_HandleState:
	cmp	$0x00, %dl
	je	VBE_ReturnStateBufferSize
	cmp	$0x01, %dl
	je	VBE_SaveState
	cmp	$0x02, %dl
	je	VBE_RestoreState
	JmpNotImplemented	"VBE_HandleState"

/*
 * INT 0x10, AH = 0x4f, AL = 0x04, DL = 0x00
 *
 * Returns the buffer size needed for saving and restoring state.
 *
 * Arguments:
 *      CX - Requested states
 *          0x01 - Controller hardware state
 *          0x02 - BIOS data state
 *          0x04 - DAC state
 *          0x08 - Register state
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Number of 64-byte blocks for the state buffer
 */
VBE_ReturnStateBufferSize:
	DHeader	"VBE_ReturnStateBufferSize"

	/* We only need six bytes at the end of this... */
	call	ReturnStateBufferSize

	mov	$0x004f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x04, DL = 0x01
 *
 * Saves the display controller hardware state.
 *
 * Arguments:
 *   ES:BX - Pointer to buffer
 *      CX - Requested states
 *          0x01 - Controller hardware state
 *          0x02 - BIOS data state
 *          0x04 - DAC state
 *          0x08 - Register state
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SaveState:
	DHeader	"VBE_SaveState"
	PushSet	%bx, %cx, %dx, %di

	/* Save the basic video state */
	call	SaveVideoState
	test	$0x08, %cx
	jz	0f

	/* Find the (hopefully free) end of that data */
	push	%bx
	call	ReturnStateBufferSize
	mov	$6, %cl
	shl	%cl, %bx
	sub	$6, %bx
	mov	%bx, %di
	pop	%bx

	/* Save the framebuffer width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_WIDTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax
	mov	%ax, %es:(%bx, %di)
	add	$2, %di

	/* Save the framebuffer height */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_HEIGHT, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax
	mov	%ax, %es:(%bx, %di)
	add	$2, %di

	/* Save the framebuffer depth */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_DEPTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax
	mov	%ax, %es:(%bx, %di)
	add	$2, %di

0:	mov	$0x004f, %ax
	PopSet	%bx, %cx, %dx, %di
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x04, DL = 0x02
 *
 * Restores a previously saved display controller hardware state.
 *
 * Arguments:
 *   ES:BX - Pointer to buffer
 *      CX - Requested states
 *          0x01 - Controller hardware state
 *          0x02 - BIOS data state
 *          0x04 - DAC state
 *          0x08 - Register state
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_RestoreState:
	DHeader	"VBE_RestoreState"
	PushSet	%bx, %cx, %dx, %si

	/* Restore the basic video state */
	call	RestoreVideoState
	test	$0x08, %cx
	jz	0f

	/* Find the end of that data (hopefully ours) */
	push	%bx
	call	ReturnStateBufferSize
	mov	$6, %cl
	shl	%cl, %bx
	sub	$6, %bx
	mov	%bx, %si
	pop	%bx

	/* Restore the framebuffer width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_WIDTH, %al
	outb	%al, %dx
	mov	%es:(%bx, %si), %ax
	add	$2, %si
	mov	$FBUF_DATA_PORT, %dx
	outw	%ax, %dx

	/* Restore the framebuffer height */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_HEIGHT, %al
	outb	%al, %dx
	mov	%es:(%bx, %si), %ax
	add	$2, %si
	mov	$FBUF_DATA_PORT, %dx
	outw	%ax, %dx

	/* Restore the framebuffer depth */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_DEPTH, %al
	outb	%al, %dx
	mov	%es:(%bx, %si), %ax
	add	$2, %si
	mov	$FBUF_DATA_PORT, %dx
	outw	%ax, %dx

0:	mov	$0x004f, %ax
	PopSet	%bx, %cx, %dx, %si
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x05
 *
 * Fails with AX=0x034f because we only support linear modes.
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_DisplayWindowControl:
	DHeader	"VBE_DisplayWindowControl"
	mov	$0x034f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x06
 *
 * BL - Subfunction
 *     0x00 - Set Scan Line Length in Pixels
 *     0x01 - Get Scan Line Length
 *     0x02 - Set Scan Line Length in Bytes
 *     0x03 - Get Maximum Scan Line Length
 */
VBE_HandleLogicalScanLineLength:
	cmp	$0x00, %bl
	je	VBE_SetScanLineLengthInPixels
	cmp	$0x01, %bl
	je	VBE_GetScanLineLength
	cmp	$0x02, %bl
	je	VBE_SetScanLineLengthInBytes
	cmp	$0x03, %bl
	je	VBE_GetMaximumScanLineLength
	JmpNotImplemented	"VBE_HandleLogicalScanLineLength"

/*
 * INT 0x10, AH = 0x4f, AL = 0x06, BL = 0x00
 *
 * Sets the desired logical scan-line length, measured in pixels.
 *
 * The actual length set may be larger than the desired value.
 *
 * Arguments:
 *      CX - Desired Width in Pixels
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Actual Bytes Per Scan Line
 *      CX - Actual Pixels Per Scan Line
 *      DX - Maximum Number of Scan Lines
 */
VBE_SetScanLineLengthInPixels:
	DHeader	"VBE_SetScanLineLengthInPixels"

	/* Get the current mode info */
	call	GetCurrentModeInfo
	jnc	2f

	/* Ensure width <= scanwidth <= DisplayWidth */
	cmp	%cs:MIA_WIDTH(%bx), %cx
	jb	0f
	cmp	%cs:DisplayWidth, %cx
	ja	1f

	/* Set the scan width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_SCANWIDTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	mov	%cx, %ax
	outw	%ax, %dx

	/* Get bytes per pixel */
	mov	%cs:MIA_DEPTH(%bx), %bx
	shr	$1, %bx
	shr	$1, %bx
	shr	$1, %bx

	/* Fill in return values */
	mov	%cx, %ax
	mul	%bx
	mov	%ax, %bx
	mov	%cs:DisplayHeight, %dx
	mov	$0x004f, %ax
	jmp	3f

	/* Complain if something went wrong */
0:	mov	$0x014f, %ax	# General failure
	jmp	3f
1:	mov	$0x024f, %ax	# Unsupported in current hardware
	jmp	3f
2:	mov	$0x034f, %ax	# Invalid in current mode
3:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x06, BL = 0x01
 *
 * Returns the current logical scan-line length.
 *
 * The logical scan line may be wider than the visible display area.
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Bytes Per Scan Line
 *      CX - Pixels Per Scan Line
 *      DX - Maximum Number of Scan Lines
 */
VBE_GetScanLineLength:
	DHeader	"VBE_GetScanLineLength"

	/* Get the current mode info */
	call	GetCurrentModeInfo
	jnc	1f

	/* Get the scan width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_SCANWIDTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax

	/* Ensure width <= scanwidth */
	cmp	%cs:MIA_WIDTH(%bx), %ax
	jae	0f
	mov	%cs:MIA_WIDTH(%bx), %ax

	/* Get bytes per pixel */
0:	mov	%cs:MIA_DEPTH(%bx), %bx
	shr	$1, %bx
	shr	$1, %bx
	shr	$1, %bx

	/* Fill in return values */
	mov	%ax, %cx
	mul	%bx
	mov	%ax, %bx
	mov	%cs:DisplayHeight, %dx
	mov	$0x004f, %ax
	jmp	2f

	/* Complain if this is not a VESA mode */
1:	mov	$0x034f, %ax
2:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x06, BL = 0x02
 *
 * Sets the desired logical scan-line length, measured in bytes.
 *
 * The actual length set may be larger than the desired value.
 *
 * Arguments:
 *      CX - Desired Width in Bytes
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Actual Bytes Per Scan Line
 *      CX - Actual Pixels Per Scan Line
 *      DX - Maximum Number of Scan Lines
 */
VBE_SetScanLineLengthInBytes:
	DHeader	"VBE_SetScanLineLengthInBytes"
	PushSet	%bx, %cx, %dx

	/* Get the current mode info */
	call	GetCurrentModeInfo
	jnc	0f

	/* Get number of bytes per pixel */
	mov	%cs:MIA_DEPTH(%bx), %bx
	shr	$1, %bx
	shr	$1, %bx
	shr	$1, %bx

	/* Calculate desired width in pixels */
	mov	%cx, %ax
	add	%bx, %ax
	dec	%ax
	div	%bx
	mov	%bx, %cx

	/* Delegate the hard work */
	call	VBE_SetScanLineLengthInPixels
	test	%ah, %ah
	jnz	1f
	add	$6, %sp
	jmp	2f

	/* Restore registers on failure */
0:	mov	$0x034f, %ax
1:	PopSet	%bx, %cx, %dx
2:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x06, BL = 0x03
 *
 * Returns the maximum length of a logical scan line.
 *
 * This is currently equal to the original display width.
 *
 * Returns:
 *      AX - VBE Return Status
 *      BX - Maximum Bytes Per Scan Line
 *      CX - Maximum Pixels Per Scan Line
 */
VBE_GetMaximumScanLineLength:
	DHeader	"VBE_GetMaximumScanLineLength"

	/* Get the current mode info */
	call	GetCurrentModeInfo
	jnc	0f

	/* Get number of bytes per pixel */
	mov	%cs:MIA_DEPTH(%bx), %bx
	shr	$1, %bx
	shr	$1, %bx
	shr	$1, %bx

	/* Fill in the return values */
	mov	%cs:DisplayWidth, %cx
	mov	%cx, %ax
	push	%dx
	mul	%bx
	pop	%dx
	mov	%ax, %bx
	mov	$0x004f, %ax
	jmp	1f

	/* Complain if this is not a VESA mode */
0:	mov	$0x034f, %ax
1:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x07
 *
 * BL - Subfunction
 *     0x00 - Set Display Start
 *     0x01 - Get Display Start
 *     0x02 - Schedule Display Start (Alternate)
 *     0x03 - Schedule Stereoscopic Display Start
 *     0x04 - Get Scheduled Display Start Status
 *     0x05 - Enable Stereoscopic Mode
 *     0x06 - Disable Stereoscopic Mode
 *     0x80 - Set Display Start during Vertical Retrace
 *     0x82 - Set Display Start during Vertical Retrace (Alternate)
 *     0x83 - Set Stereoscopic Display Start during Vertical Retrace
 */
VBE_HandleDisplayStart:
	cmp	$0x00, %bl
	je	VBE_SetDisplayStart
	cmp	$0x80, %bl
	je	VBE_SetDisplayStartDuringVerticalRetrace
	JmpNotImplemented	"VBE_HandleDisplayStart"

/*
 * INT 0x10, AH = 0x4f, AL = 0x07, BL = 0x00
 *
 * Selects pixel in the upper left corner of the display.
 *
 * Arguments:
 *      CX - First displayed pixel in scan line
 *      DX - First displayed scan line
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SetDisplayStart:
	DHeader	"SetDisplayStart"

	/* Check if this is just a reset */
	test	%cx, %cx
	jnz	0f
	test	%dx, %dx
	jnz	0f

	/* Complain about anything else */
	jmp	1f
0:	mov	$0x014f, %ax
	jmp	2f

1:	mov	$0x004f, %ax
2:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x07, BL = 0x80
 *
 * Selects pixel in the upper left corner of the display.
 *
 * Arguments:
 *      CX - First displayed pixel in scan line
 *      DX - First displayed scan line
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SetDisplayStartDuringVerticalRetrace:
	DHeader	"SetDisplayStartDuringVerticalRetrace"

	/* Hah! Like we care about the difference... */
	call	VBE_SetDisplayStart
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x08
 *
 * Fails with AX=0x034f because we only support direct color.
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_HandleDacPaletteFormat:
	DHeader	"VBE_HandleDacPaletteFormat"
	mov	$0x034f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x09
 *
 * BL - Subfunction
 *     0x00 - Set Palette Data
 *     0x01 - Get Palette Data
 *     0x02 - Set Secondary Palette Data
 *     0x03 - Get Secondary Palette Data
 *     0x80 - Set Palette Data during Vertical Retrace
 */
VBE_HandlePaletteData:
	cmp	$0x00, %bl
	je	VBE_SetPaletteData
	cmp	$0x01, %bl
	je	VBE_GetPaletteData
	cmp	$0x02, %bl
	je	VBE_SetSecondaryPaletteData
	cmp	$0x03, %bl
	je	VBE_GetSecondaryPaletteData
	cmp	$0x80, %bl
	je	VBE_SetPaletteDataDuringVerticalRetrace
	JmpNotImplemented	"VBE_HandlePaletteData"

/*
 * INT 0x10, AH = 0x4f, AL = 0x09, BL = 0x00
 *
 * Sets RGB values for a block of DAC color registers.
 *
 * This is very similar to HandlePalette_SetBlockOfColorRegisters
 * (INT 0x10, AH = 0x10, AL = 0x12), but that function should
 * only be used for VGA-compatible modes.
 *
 * Arguments:
 *   ES:DI - Table of palette values
 *      CX - Number of palette registers to update
 *      DX - First palette register to update
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SetPaletteData:
	DHeader	"VBE_SetPaletteData"
	PushSet	%cx, %dx, %di

	/* Validate index values */
	cmp	$256, %dx
	jae	1f
	mov	%dx, %ax
	add	%cx, %ax
	cmp	$256, %ax
	ja	1f

	/* Select the palette index */
	mov	%dl, %al
	mov	$PORT_PALETTE_WRITE, %dx
	outb	%al, %dx

	/* Store the color data */
	mov	$PORT_PALETTE_DATA, %dx
0:	mov	%es:2(%di), %al
	outb	%al, %dx
	mov	%es:1(%di), %al
	outb	%al, %dx
	mov	%es:0(%di), %al
	outb	%al, %dx
	add	$4, %di
	loop	0b

	/* Complain if some argument was wrong */
	jmp	2f
1:	mov	$0x014f, %ax
	jmp	3f

2:	mov	$0x004f, %ax
3:	PopSet	%cx, %dx, %di
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x09, BL = 0x01
 *
 * Not implemented, since it's not mandatory in VBE 3.0.
 */
VBE_GetPaletteData:
	DHeader	"VBE_GetPaletteData"
	mov	$0x024f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x09, BL = 0x02
 *
 * Returns an error code, since no secondary palette exists.
 */
VBE_SetSecondaryPaletteData:
	DHeader	"VBE_SetSecondaryPaletteData"
	mov	$0x024f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x09, BL = 0x03
 *
 * Returns an error code, since no secondary palette exists.
 */
VBE_GetSecondaryPaletteData:
	DHeader	"VBE_GetSecondaryPaletteData"
	mov	$0x024f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x09, BL = 0x80
 *
 * Sets RGB values for a block of DAC color registers.
 *
 * Arguments:
 *   ES:DI - Table of palette values
 *      CX - Number of palette registers to update
 *      DX - First palette register to update
 *
 * Returns:
 *      AX - VBE Return Status
 */
VBE_SetPaletteDataDuringVerticalRetrace:
	DHeader	"VBE_SetPaletteDataDuringVerticalRetrace"

	/* Hah! Like we care about the difference... */
	call	VBE_SetPaletteData
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x0b
 *
 * BL - Subfunction
 *     0x00 - Get closest pixel clock
 */
VBE_HandlePixelClock:
	cmp	$0x00, %bl
	je	VBE_GetClosestPixelClock
	JmpNotImplemented	"VBE_HandlePixelClock"

/*
 * INT 0x10, AH = 0x4f, AL = 0x0b, BL = 0x00
 *
 * Returns the requested value, since we accept all pixel clocks.
 *
 * Arguments:
 *     ECX - Requested pixel clock in Hz
 *      DX - Mode number
 *
 * Returns:
 *      AX - VBE Return Status
 *     ECX - Closest pixel clock
 */
VBE_GetClosestPixelClock:
	DHeader	"VBE_GetClosestPixelClock"
	mov	$0x004f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x10
 *
 * BL - Subfunction
 *     0x00 - Get Capabilities
 *     0x01 - Set Display Power State
 *     0x02 - Get Display Power State
 */
VBE_PowerManagement:
	cmp	$0x00, %bl
	je	PM_GetCapabilities
	cmp	$0x01, %bl
	je	PM_SetDisplayPowerState
	cmp	$0x02, %bl
	je	PM_GetDisplayPowerState
	JmpNotImplemented	"VBE_PowerManagement"

/*
 * INT 0x10, AH = 0x4f, AL = 0x10, BL = 0x00
 *
 * Returns the set of supported Power Management states.
 *
 * Arguments:
 *   ES:DI - Pointer to info block (typically NULL)
 *
 * Returns:
 *      AX - VBE Return Status
 *      BL - VBE/PM version (major/minor in high/low nybble)
 *      BH - Supported states
 *          0x01 - Standby
 *          0x02 - Suspend
 *          0x04 - Off
 *          0x08 - Reduced On (for flat screens)
 */
PM_GetCapabilities:
	DHeader	"PM_GetCapabilities"
	mov	$0x004f, %ax
	mov	$0x0010, %bx
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x10, BL = 0x01
 *
 * Sets one of the supported Power Management states.
 *
 * Arguments:
 *      BH - New state
 *          0x00 - On
 *          0x01 - Standby
 *          0x02 - Suspend
 *          0x04 - Off
 *          0x08 - Reduced On (for flat screens)
 *
 * Returns:
 *      AX - VBE Return Status
 */
PM_SetDisplayPowerState:
	DHeader	"PM_SetDisplayPowerState"
	test	%bh, %bh
	jz	0f
	mov	$0x024f, %ax
	jmp	1f
0:	mov	$0x004f, %ax
1:	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x10, BL = 0x02
 *
 * Returns the currently active Power Management state.
 *
 * Returns:
 *     AX - VBE Return Status
 *     BH - Current power state
 *          0x00 - On
 *          0x01 - Standby
 *          0x02 - Suspend
 *          0x04 - Off
 *          0x08 - Reduced On (for flat screens)
 */
PM_GetDisplayPowerState:
	DHeader	"PM_GetDisplayPowerState"
	mov	$0x004f, %ax
	mov	$0x00, %bh
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x14
 *
 * Currently an empty dummy function.
 *
 * This is presumably where bhyve-specific BIOS calls should be added.
 * There is a corresponding CallVideoBiosOemExtension function in the
 * BhyveCsm16.c file of the sysutils/uefi-edk2-bhyve-csm port, just
 * in case some data must be passed down from higher software layers.
 *
 * BL - Subfunction (not used)
 */
VBE_OemExtensions:
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x15
 *
 * Main entry point for Display Data Channel (VBE/DDC).
 *
 * BL - Subfunction
 *     0x00 - Report DDC Capabilities
 *     0x01 - Read EDID
 */
VBE_DisplayDataChannel:
	cmp	$0x00, %bl
	je	DDC_ReportCapabilities
	cmp	$0x01, %bl
	je	DDC_ReadEDID
	JmpNotImplemented	"VBE_DisplayDataChannel"

/*
 * INT 0x10, AH = 0x4f, AL = 0x15, BL = 0x00
 *
 * Checks if VBE/DDC is available and returns capability info.
 *
 * Returns:
 *     AX - VBE Return Status
 *     BX - Capabilities
 */
DDC_ReportCapabilities:
	DHeader	"DDC_ReportCapabilities"

	mov	$DDC_DDC2_SUPPORTED, %bl
	mov	$SECONDS_PER_EDID_BLOCK, %bh

	mov	$0x004f, %ax
	ret

/*
 * INT 0x10, AH = 0x4f, AL = 0x15, BL = 0x01
 *
 * Provides Extended Display Identification Data (EDID).
 *
 * This is how things like the monitor size is determined.
 *
 * Arguments:
 *   ES:DI - Pointer to buffer for DisplayData structure
 *
 * Returns:
 *      AX - VBE Return Status
 */
DDC_ReadEDID:
	DHeader	"DDC_ReadEDID"
	PushSet	%cx, %si, %di, %ds
	cld

	/* Use CS as the default data segment */
	mov	%cs, %ax
	mov	%ax, %ds

	/* Copy the DisplayData struct */
	mov	$DISPLAY_DATA_SIZE, %cx
	lea	DisplayData, %si
	rep	movsb

	mov	$0x004f, %ax
	PopSet	%cx, %si, %di, %ds
	ret

/*** Help Functions ***********************************************************/

/*
 * Saves the display size to keep track of maximum resolution.
 */
SaveDisplaySize:
	PushSet	%ax, %dx

	/* Save the display width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_WIDTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax
	mov	%ax, %cs:DisplayWidth

	/* Save the display height */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_HEIGHT, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	inw	%dx, %ax
	mov	%ax, %cs:DisplayHeight

	PopSet	%ax, %dx
	ret

/*
 * Updates checksum bytes for the BIOS and individual structs.
 */
UpdateChecksums:
	PushSet	%ax, %cx, %si

	/* Update checksum for the PnP Expansion header */
	lea	PnP_Expansion_Header, %si
	xor	%ax, %ax
	mov	$32, %cx
0:	cs lodsb
	add	%al, %ah
	loop	0b
	sub	%ah, %cs:(PnP_Expansion_Header + 0x09)

	/* Update checksum for the DisplayData (EDID) */
	lea	DisplayData, %si
	xor	%ax, %ax
	mov	$128, %cx
1:	cs lodsb
	add	%al, %ah
	loop	1b
	sub	%ah, %cs:(DisplayData + 0x7f)

	/* Update checksum for the entire Video BIOS */
	lea	VideoBIOS, %si
	lea	VideoBIOS_end, %cx
	xor	%ax, %ax
2:	cs lodsb
	add	%al, %ah
	loop	2b
	sub	%ah, %cs:BiosChecksum

	PopSet	%ax, %cx, %si
	ret

/*
 * Stops and complains if the BIOS checksum is incorrect.
 *
 * This might happen if data is written to the CS segment by mistake.
 */
VerifyBiosChecksum:
	PushSet	%ax, %cx, %si
	cld

	/* Verify checksum for the entire Video BIOS */
	lea	VideoBIOS, %si
	lea	VideoBIOS_end, %cx
	xor	%ax, %ax
1:	cs lodsb
	add	%al, %ah
	loop	1b
	test	%ah, %ah
	jz	3f

	/* Block if the checksum is incorrect */
	push	%ax
	mov	$STR_INCORRECT_CHECKSUM, %ax
	call	PrintString
	pop	%ax
	call	PrintAxRegister
	call	PrintEndOfLine
2:	jmp	2b

3:	PopSet	%ax, %cx, %si
	ret

/*
 * Converts a mode number stored in AL to a mode index stored in AL.
 *
 * Arguments:
 *      AL - VGA mode number
 *
 * Returns:
 *      AL - VideoParameterTable index
 */
GetModeIndex:

	/* Function prologue */
	push	%bx

	/* Get scan-line settings from the BIOS Data Area */
	mov	BDA_VIDEO_DISPLAY_DATA, %bh
	and	$0x90, %bh

	/* Modes 0x00 to 0x03 depend on the number of scan lines */
	cmp	$0x03, %al
	jg	1f
	cmp	$0x80, %bh	# 200 scan lines
	je	5f
	cmp	$0x00, %bh	# 350 scan lines
	jne	0f
	add	$0x13, %al
	jmp	5f
0:	cmp	$0x10, %bh	# 400 scan lines
	je	0f
	JmpNotImplemented	"GetModeIndex"
0:
	shr	$1, %al
	add	$0x17, %al
	jmp	5f
1:
	/* Modes 0x04 to 0x06 are mapped directly */
	cmp	$0x06, %al
	jle	5f

	/* Mode $0x07 has a special 400-line version */
	cmp	$0x07, %al
	jg	2f
	cmp	$0x10, %bh	# 400 scan lines
	jne	5f
	add	$0x12, %al
	jmp	5f
2:
	/* Modes 0x08 to 0x0E are mapped directly */
	cmp	$0x0e, %al
	jle	5f

	/* Modes 0x0F to 0x10 have special versions for > 64 KiB RAM */
	cmp	$0x10, %al
	jg	3f
	mov	BDA_VIDEO_MODE_OPTIONS, %bh # Bits 6-4 are zero for <= 64 KiB
	test	$0x70, %bh
	jz	5f
	add	$0x02, %al
	jmp	5f
3:
	/* Modes 0x11-0x13 are mapped to 0x1A-0x1C */
	cmp	$0x13, %al
	jg	4f
	add	$0x09, %al
	jmp	5f
4:
	/* Complain about modes above 0x13, which is the highest VGA mode */
	mov	$BAD_MODE, %al
5:
	/* Function epilogue */
	pop	%bx
	ret
 
/*
 * Returns the Video Parameter Table (VPT) entry for a given mode number.
 *
 * Arguments:
 *      AL - Mode number
 *
 * Returns:
 *   CS:BX - Pointer to the corresponding VPT entry
 */
GetModeEntry:
	PushSet	%ax

	/* Convert mode number to an index for the Video Parameter Table */
	call	GetModeIndex
	cmp	$BAD_MODE, %al
	je	0f

	/* Set BX to the address of the corresponding entry */
	mov	%al, %bh
	xor	%bl, %bl
	shr	$1, %bx
	shr	$1, %bx
	add	$VideoParameterTable, %bx
	jmp	1f

0:	mov	$BAD_ENTRY, %bx
1:	PopSet	%ax
	ret

/*
 * Returns the ModeInfoArray (MIA) entry for a given VBE mode number.
 *
 * Arguments:
 *      CX - Mode number
 *
 * Returns:
 *   CS:BX - The entry
 *      CF - Set if and only if the entry was found
 */
GetVbeModeInfo:
	PushSet	%ax

	/* Check if there is another mode entry */
	lea	ModeInfoArray, %bx
0:	mov	%cs:(%bx), %ax
	test	%ax, %ax
	jz	2f

	/* Keep looping until we have the right one */
	cmp	%cs:(%bx), %cx
	je	1f
	add	$MIA_STRUCT_SIZE, %bx
	jmp	0b

	/* Set the carry flag if and only if we found it */
1:	stc
	jmp	3f
2:	clc

3:	PopSet	%ax
	ret

/*
 * Returns the ModeInfoArray (MIA) entry for the current VESA mode.
 *
 * Returns:
 *   CS:BX - The entry
 *      CF - Set if and only if the entry was found
 */
GetCurrentModeInfo:
	PushSet	%ax, %cx

	/* Get the current mode number */
	push	%bx
	call	VBE_ReturnCurrentMode
	test	%ah, %ah
	jz	0f
	pop	%bx
	jmp	1f

	/* Find the mode information */
0:	add	$2, %sp
	mov	%bx, %cx
	and	$0x07ff, %cx
	call	GetVbeModeInfo	# -> %cs:%bx

1:	PopSet	%ax, %cx
	ret

/*
 * Updates a ModeInfoBlock to enable or disable the mode.
 *
 * This decision is made based on whether the resolution fits in the
 * display size that was detected when the BIOS was initialized.
 *
 * Arguments:
 *   ES:DI - Pointer to ModeInfoBlock structure
 */
UpdateModeAttributes:
	PushSet	%ax

	/* Enable the mode by default */
	orw	$0x0001, %es:MIB_MODE_ATTRIBUTES(%di)

	/* Disable the mode if it's too wide */
	mov	%es:MIB_X_RESOLUTION(%di), %ax
	cmp	%cs:DisplayWidth, %ax
	jbe	0f
	andw	$0xfffe, %es:MIB_MODE_ATTRIBUTES(%di)
	jmp	1f

	/* Disable the mode if it's too high */
0:	mov	%es:MIB_Y_RESOLUTION(%di), %ax
	cmp	%cs:DisplayHeight, %ax
	jbe	1f
	andw	$0xfffe, %es:MIB_MODE_ATTRIBUTES(%di)

1:	PopSet	%ax
	ret

/*
 * Sets width, height, and depth of the framebuffer.
 *
 * Arguments:
 *      AX - Buffer width
 *      BX - Buffer height
 *      CX - Buffer depth
 */
SetBufferShape:
	PushSet	%ax, %dx
	PushSet	%cx, %bx, %ax

	/* Set the framebuffer width */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_WIDTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	pop	%ax
	outw	%ax, %dx

	/* Set the framebuffer height */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_HEIGHT, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	pop	%ax
	outw	%ax, %dx

	/* Set the framebuffer depth */
	mov	$FBUF_INDEX_PORT, %dx
	mov	$FBUF_REG_DEPTH, %al
	outb	%al, %dx
	mov	$FBUF_DATA_PORT, %dx
	pop	%ax
	outw	%ax, %dx

	PopSet	%ax, %dx
	ret

/*
 * Scrolls the active page upwards (AL < 0) or downwards (AL > 0).
 * The allowed range for AL is from -127 to +127; -128 does nothing.
 *
 * Arguments:
 *      AL - Number of lines to scroll; 0x00 to blank the entire window
 *      BH - Attribute to use on blank lines scrolled in at the edge
 *      CX - Unsigned row/column for upper left corner of the scroll area
 *      DX - Unsigned row/column for lower right corner of the scroll area
 */
ScrollActivePage:
	PushSet	%ax, %bx, %cx, %dx, %si, %di, %es, %bp
	mov	%sp, %bp
	cld

	/* Adjust register values */
	call	ClampScrollParameters
	mov	%al, %bl	# %bl is now number of lines to scroll
	jnc	8f

	/* Get the page buffer */
	push	%bx
	mov	BDA_DISPLAY_PAGE, %bh
	call	GetPageAddress	# Sets %es
	pop	%bx

	/* Calculate the number of characters per row */
	mov	%dl, %al
	sub	%cl, %al
	xor	%ah, %ah
	add	$1, %al
	adc	$0, %ah		# %ax = %dl - %cl + 1

	/* Keep this on the stack */
	push	%ax		# -2(%bp) = %ax; Number of characters per row

	/* Calculate the destination offset */
0:	test	%bl, %bl	# Check if we're scrolling up or down
	jg	1f
	mov	%ch, %al	# Start from the top for upward scrolls
	jmp	2f
1:	mov	%dh, %al	# Start from the bottom for downward scrolls
2:	mulb	BDA_NUMBER_OF_COLUMNS
	add	%cl, %al
	adc	$0, %ah
	shl	$1, %ax
	mov	%ax, %di	# %di = 2 * (BDA_NUMBER_OF_COLUMNS * %xh + %cl)

	/* Check if the source would fall outside the scroll window */
	mov	%bl, %al
	test	%al, %al
	jge	3f
	neg	%al		# Get the absolute value of lines to scroll
3:	add	%ch, %al
	push	%cx
	mov	-2(%bp), %cx
	cmp	%dh, %al
	ja	4f

	/* Copy one row from source to destination */
	mov	%bl, %al
	cbw			# Multiply signed %bl with unsigned BDA word
	push	%dx	
	imulw	BDA_NUMBER_OF_COLUMNS
	pop	%dx		# Ignore the upper word; it's either 0 or -1
	shl	$1, %ax
	mov	%di, %si
	sub	%ax, %si	# %si = %di - 2 * BDA_NUMBER_OF_COLUMNS * %bl
	call	CopyRow		# Copy %cx characters
	jmp	5f

	/* Clear the destination row */
4:	call	ClearRow	# Clear %cx characters

	/* Go on until we come to the end */
5:	pop	%cx
	test	%bl, %bl	# Negative shift means scrolling upwards
	jg	6f
	inc	%ch		# Increment %ch for upward scrolls
	jmp	7f
6:	dec	%dh		# Decrement %dh for downward scrolls
7:	cmp	%dh, %ch
	jle	0b		# Break when they have passed each other

8:	mov	%bp, %sp
	PopSet	%ax, %bx, %cx, %dx, %si, %di, %es, %bp
	ret

/*
 * Validates and clamps parameters for the scroll functions.
 *
 * Updates AL to the actual number of lines. Clamps CH, CL, DH, and DL.
 * Sets the carry flag if parameters are valid enough to carry on.
 *
 * In/Out Arguments:
 *      AL - Number of lines to scroll; 0x00 to blank the entire window
 *      CX - Unsigned row/column for upper left corner of the scroll area
 *      DX - Unsigned row/column for lower right corner of the scroll area
 */
ClampScrollParameters:
	PushSet	%bx
	clc

	/* Silently ignore inverted scroll areas */
	cmp	%dl, %cl
	ja	8f
	cmp	%dh, %ch
	ja	8f

	/* Silently ignore the one incorrect scroll length (-128) */
	cmp	$0x80, %al
	je	8f

	/* Clamp row to the allowed interval */
0:	cmp	BDA_LAST_ROW_INDEX, %dh
	jna	1f
	mov	BDA_LAST_ROW_INDEX, %dh

	/* Clamp column to the allowed interval */
1:	cmp	BDA_NUMBER_OF_COLUMNS, %dl
	jb	2f
	mov	BDA_NUMBER_OF_COLUMNS, %dl
	dec	%dl

	/* Calculate the scroll limit */
2:	mov	%dh, %bl
	sub	%ch, %bl
	inc	%bl		# %bl = %dh - %ch + 1
	jge	3f
	mov	$0x7f, %bl	# Limit to +127 on overflow
3:	test	%al, %al
	jge	4f
	neg	%bl		# Use negative limit if scrolling up

	/* Translate the special scroll length zero */
4:	cmp	$0, %al		# 0 means all
	je	6f

	/* Check if we're scrolling up or down */
	test	%al, %al
	jg	5f

	/* Up: clamp to %bl if %al < %bl */
	cmp	%bl, %al
	jge	7f
	jmp	6f

	/* Down: clamp to %bl if %al > %bl */
5:	cmp	%bl, %al
	jle	7f

	/* Clamp and/or set the carry flag */
6:	mov	%bl, %al
7:	stc

	/* Check if we're scrolling up or down */
8:	PopSet	%bx
	ret

/*
 * Copies a row of characters to another place in the display buffer.
 *
 * This is a support function to extend ScrollActivePage
 * to graphics modes with as few changes as possible.
 *
 * Arguments:
 *   ES:SI - The source in a text-mode buffer
 *   ES:DI - The destination in a text-mode buffer
 *      CX - The number of characters to copy
 */
CopyRow:
	call	IsTextMode
	je	CopyRow_Text
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	CopyRow_0x12
	JmpNotImplemented	"CopyRow"

/*
 * Clears a row of characters in the display buffer.
 *
 * This is a support function to extend ScrollActivePage
 * to graphics modes with as few changes as possible.
 *
 * Arguments:
 *   ES:DI - The destination in a text-mode buffer
 *      BH - The text attribute (background color for graphics modes)
 *      CX - The number of characters to clear
 */
ClearRow:
	call	IsTextMode
	je	ClearRow_Text
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	ClearRow_0x12
	JmpNotImplemented	"ClearRow"

/*
 * CopyRow implementation for text modes.
 *
 * Arguments:
 *   ES:SI - The source in a text-mode buffer
 *   ES:DI - The destination in a text-mode buffer
 *      CX - The number of characters to copy
 */
CopyRow_Text:
	PushSet	%cx, %si, %di

	rep	es movsw	# Copy %cx words from %es:%si to %es:%di

	PopSet	%cx, %si, %di
	ret

/*
 * ClearRow implementation for text modes.
 *
 * Arguments:
 *   ES:DI - The destination in a text-mode buffer
 *      BH - The text attribute (background color for graphics modes)
 *      CX - The number of characters to clear
 */
ClearRow_Text:
	PushSet	%ax, %cx, %di

	mov	$' ', %al
	mov	%bh, %ah
	rep	stosw

	PopSet	%ax, %cx, %di
	ret

/*
 * Converts a text-mode index to an index for VGA mode 0x12.
 *
 * Arguments:
 *   ES:AX - A location in a text-mode buffer
 *
 * Returns:
 *   ES:AX - The corresponding location for mode 0x12
 */
ConvertBufferIndex_0x12:
	PushSet	%bx, %dx

	/* Store row in %al and column in %bl */
	shr	$1, %ax
	divb	BDA_NUMBER_OF_COLUMNS
	mov	%ah, %bl

	/* Multiply %al by the number of bytes per row */
	mulb	BDA_NUMBER_OF_COLUMNS
	mulw	BDA_CHARACTER_HEIGHT

	/* Add one byte per column */
	xor	%bh, %bh
	add	%bx, %ax

	PopSet	%bx, %dx
	ret

/*
 * CopyRow implementation for VGA mode 0x12.
 *
 * Arguments:
 *   ES:SI - The source in a text-mode buffer
 *   ES:DI - The destination in a text-mode buffer
 *      CX - The number of characters to copy
 */
CopyRow_0x12:
	PushSet	%ax, %bx, %cx, %dx, %si, %di

	/* Make sure that we write what was read */
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x01

	/* Convert the source index */
	mov	%si, %ax
	call	ConvertBufferIndex_0x12
	mov	%ax, %si

	/* Convert the destination index */
	mov	%di, %ax
	call	ConvertBufferIndex_0x12
	mov	%ax, %di

	/* Prepare for the loop */
	mov	BDA_CHARACTER_HEIGHT, %ax	# %ax is the loop counter
	mov	%cx, %bx			# %bx is bytes per line
	mov	BDA_NUMBER_OF_COLUMNS, %dx	# %dx is bytes to next line...
	sub	%cx, %dx			# ...minus what movsb adds

	/* Loop over each line in the character row */
0:	mov	%bx, %cx
	rep	es movsb	# Copy %cx bytes from %es:%si to %es:%di
	add	%dx, %si
	add	%dx, %di
	dec	%ax
	test	%ax, %ax
	jnz	0b

	PopSet	%ax, %bx, %cx, %dx, %si, %di
	ret

/*
 * ClearRow implementation for VGA mode 0x12.
 *
 * Arguments:
 *   ES:DI - The destination in a text-mode buffer
 *      BH - The background color
 *      CX - The number of characters to clear
 */
ClearRow_0x12:
	PushSet	%ax, %bx, %cx, %dx, %di

	/* Make sure that we write colored pixels */
	SetReg	$PORT_GFX, $GFXR_SET_RESET, %bh		# Color
	SetReg	$PORT_GFX, $GFXR_DATA_ROTATE, $0x00	# Replace
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x03	# Mode 3

	/* Convert the destination index */
	mov	%di, %ax
	call	ConvertBufferIndex_0x12
	mov	%ax, %di

	/* Prepare for the loop */
	mov	$0xff, %al			# %al is the bits to write
	movb	BDA_CHARACTER_HEIGHT, %ah	# %ah is the loop counter
	mov	%cx, %bx			# %bx is bytes per line
	movw	BDA_NUMBER_OF_COLUMNS, %dx	# %dx is bytes to next line...
	sub	%cx, %dx			# ...minus what stosb adds

	/* Loop over each line in the character row */
0:	mov	%bx, %cx
	rep	es stosb	# Clear %cx bytes
	add	%dx, %di
	dec	%ah
	test	%ah, %ah
	jnz	0b

	PopSet	%ax, %bx, %cx, %dx, %di
	ret

/*
 * Returns an address for the cursor-marked character on a given page.
 *
 * This aborts and clears the carry flag for invalid page numbers.
 * If the carry flag is set, it's safe to carry on.
 * Otherwise, ES:AX is a NULL pointer.
 *
 * Arguments:
 *      BH - Page number (zero-based)
 *
 * Returns:
 *   ES:AX - Address to the first character byte
 *      CF - Set if and only if the page is OK
 */
GetCharacterAddress:
	PushSet	%bx, %dx

	/* Complain if the page number is too high for the current mode */
	call	GetPageCount
	cmp	%al, %bh
	jae	1f

	/* Get an address for the given page */
	call	GetPageAddress	# Sets %es

	/* Read cursor position from the BIOS Data Area */
	mov	%bh, %bl
	xor	%bh, %bh
	shl	$1, %bx
	mov	BDA_CURSOR_POSITIONS(%bx), %dx

	/* Get a byte offset to the given character */
	call	GetCharacterOffset

	/* Set the carry flag before returning */
0:	stc
	jmp	2f

	/* Return a NULL pointer for invalid pages */
1:	xor	%ax, %ax
	mov	%ax, %es
	clc

2:	PopSet	%bx, %dx
	ret

/*
 * Calculates the offset to a given character in the display buffer.
 *
 * Arguments:
 *      DH - Row number
 *      DL - Column number
 *
 * Returns:
 *      AX - Byte offset
 */
GetCharacterOffset:
	call	IsTextMode
	je	GetCharacterOffset_Text
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	GetCharacterOffset_0x12
	JmpNotImplemented	"GetCharacterOffset"

/*
 * GetCharacterOffset implementation for text modes.
 *
 * Arguments:
 *      DH - Row number
 *      DL - Column number
 *
 * Returns:
 *      AX - Byte offset
 */
GetCharacterOffset_Text:
	/*
	 * Calculate character offset. This assumes a column count < 256,
	 * meaning width < 2048 pixels. The BIOS can't handle more anyway.
	 * A theoretical 1920x1200 text-mode display should work, and that
	 * is the maximum resolution currently supported by bhyve.
	 */
	mov	%dh, %al
	mulb	BDA_NUMBER_OF_COLUMNS
	add	%dl, %al
	adc	$0, %ah
	shl	$1, %ax
	ret

/*
 * GetCharacterOffset implementation for VGA mode 0x12.
 *
 * Arguments:
 *      DH - Row number
 *      DL - Column number
 *
 * Returns:
 *      AX - Byte offset
 */
GetCharacterOffset_0x12:
	mov	%dh, %al
	mulb	BDA_NUMBER_OF_COLUMNS
	push	%dx
	mulw	BDA_CHARACTER_HEIGHT
	pop	%dx
	add	%dl, %al
	adc	$0, %ah
	ret

/*
 * Draws a given character at the current cursor position.
 *
 * The character can be repeated, but this will not give
 * a valid result unless the text fits on a single line.
 *
 * Arguments:
 *      AL - Character to draw
 *      BL - Color of the character
 *      BH - Page number (zero-based)
 *      CX - Count of characters to draw
 */
DrawRepeatedCharacter:
	PushSet	%ax, %bx, %cx, %es

	mov	%al, %dl	# Character
	mov	%bl, %dh	# Color

	/* Store the character address in %es:%bx */
	call	GetCharacterAddress	# -> %es:%ax
	mov	%ax, %bx

	/* "Continuation to succeeding rows produces invalid results" */
0:	call	DrawCharacter
	call	StepCharacter
	loop	0b

	PopSet	%ax, %bx, %cx, %es
	ret

/*
 * Draws a single character at a given address in the display buffer.
 *
 * Arguments:
 *   ES:BX - The location of the first character byte
 *      DL - The character to draw
 *      DH - Color value (bit 7 means XOR except for mode 0x13)
 */
DrawCharacter:
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	DrawCharacter_0x12
	JmpNotImplemented	"DrawCharacter"

/*
 * Moves from one character address to the next on the same row.
 *
 * The result is incorrect for the last character of the row.
 *
 * Arguments:
 *   ES:BX - Location of the first byte of some character
 *
 * Returns:
 *   ES:BX - Location of the first byte of the next character
 */
StepCharacter:
	cmpb	$0x12, BDA_DISPLAY_MODE
	je	StepCharacter_0x12
	JmpNotImplemented	"StepCharacter"

/*
 * StepCharacter implementation for VGA mode 0x12.
 *
 * Arguments:
 *   ES:BX - Location of the first byte of some character
 *
 * Returns:
 *   ES:BX - Location of the first byte of the next character
 */
StepCharacter_0x12:
	inc	%bx
	ret

/*
 * DrawCharacter implementation for VGA mode 0x12.
 *
 * Arguments:
 *   ES:BX - The location of the first byte to write
 *      DL - The character to draw
 *      DH - Color value (bit 7 means XOR)
 */
DrawCharacter_0x12:
	PushSet	%ax, %bx, %cx, %dx, %si, %di

	/* Move character and color to %cx */
	mov	%dx, %cx

	/* Calculate an offset for the font data */
	mov	%cl, %al
	mulb	BDA_CHARACTER_HEIGHT
	mov	%ax, %si

	/* Select the function */
	test	$0x80, %ch	# Bit 7 means XOR
	jnz	0f
	xor	%ah, %ah	# Replace
	jmp	1f
0:	mov	$0x18, %ah	# XOR
1:	and	$0x0f, %ch

	/* Set the type of graphics write; this clobbers AL and DX */
	SetReg	$PORT_GFX, $GFXR_SET_RESET, %ch		# Color
	SetReg	$PORT_GFX, $GFXR_DATA_ROTATE, %ah	# Function
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x03	# Mode 3

	/* Loop over all lines of the character */
	mov	BDA_CHARACTER_HEIGHT, %cx
2:	mov	%cs:Font_8x16(%si), %ah
	SetReg	$PORT_GFX, $GFXR_BIT_MASK, $0xff	# Mask

	/* Read the byte to latch existing data */
	push	%si
	mov	%bx, %si
	mov	%bx, %di	# Only needed for movsb
	es movsb		# lodsb kills bhyve emulator (2019-05-29)
	pop	%si

	/* Write the byte */
	mov	%bx, %di
	mov	%ah, %al
	stosb

	/* Continue with the next line */
	add	BDA_NUMBER_OF_COLUMNS, %bx
	inc	%si
	loop	2b

	PopSet	%ax, %bx, %cx, %dx, %si, %di
	ret

/*
 * Updates the BIOS Data Area (BDA) to reflect a given video mode.
 *
 * Arguments:
 *   CS:BX - Pointer to an entry in the Video Parameter Table
 *      AH - The new mode number
 *      AL - The number of columns
 *      CL - 0x80 if buffer is kept on mode shifts; 0x00 if it's cleared
 */
UpdateBiosDataArea:
	PushSet	%ax

	/* 0x449: Current video mode */
	movb	%ah, BDA_DISPLAY_MODE

	/* 0x44A: Number of columns (a word, for some reason) */
	xor	%ah, %ah
	movw	%ax, BDA_NUMBER_OF_COLUMNS

	/* 0x44C: Size of active display page in bytes */
	movw	%cs:VPT_PAGE_SIZE(%bx), %ax
	movw	%ax, BDA_VIDEO_PAGE_SIZE

	/* 0x44E: Offset of display page in the video buffer */
	xor	%ax, %ax
	movw	%ax, BDA_VIDEO_PAGE_OFFSET

	/* 0x460: Cursor top (high byte) and bottom (low byte) line in char */
	movw	%cs:(VPT_CRT_CTRL_REGS + CRTR_CURSOR_START)(%bx), %ax
	and	$0x1f1f, %ax
	mov	%ax, BDA_CURSOR_TYPE

	/* 0x462: Active display page; reset to first page on mode changes */
	movb	$0x00, BDA_DISPLAY_PAGE

	/* 0x463: CRT Controller Base Address; differs for MDA compatibility */
	movb	%cs:(VPT_MISC_OUTPUT_REG)(%bx), %al
	test	$0x01, %al # I/O Address Select
	jz	0f
	movw	$PORT_CRTC_VGA, BDA_CRTC_BASE
	jmp	1f
0:	movw	$PORT_CRTC_MDA, BDA_CRTC_BASE

	/* 0x465-0x466: Emulated values for two old MDA/CGA registers */
1:	call	WriteFake3X8	# MDA/CGA Mode Control Register value
	call	WriteFake3X9	# CGA Color Select Register value

	/* 0x484: Zero-based index of the last character row */
	movb	%cs:VPT_LAST_ROW_INDEX(%bx), %al
	movb	%al, BDA_LAST_ROW_INDEX

	/* 0x485: Height of the character matrix (a word, for some reason) */
	movb	%cs:VPT_CHARACTER_HEIGHT(%bx), %al
	xor	%ah, %ah
	movw	%ax, BDA_CHARACTER_HEIGHT

	/* 0x487: Video options; only two of the flags are of interest here */
	movb	BDA_VIDEO_MODE_OPTIONS, %al
	and	$0x7f, %al
	or	%cl, %al	# Keep display buffer on mode shifts
	testb	$0x20, %cs:(VPT_CRT_CTRL_REGS + CRTR_CURSOR_START)(%bx)
	jnz	2f
	and	$0xfe, %al	# Enable CGA-to-VGA cursor size translation */
2:	movb	%al, BDA_VIDEO_MODE_OPTIONS

	/* 0x488: Feature bits; this field does not seem well defined */
	andb	$0x10, BDA_VIDEO_FEATURE_BITS # Leave the DHeader bit

	PopSet	%ax
	ret

/*
 * Writes byte 0x65 in the BIOS Data Area.
 *
 * I can find no official documentation on the contents of this byte, but the
 * original BIOS reference refers to it as "Current Setting of 3x8 Register",
 * and inofficial data on the web lists it as an "internal mode register".
 * This makes it the Mode Control Register at 0x3d8 for CGA or 0x3b8 for MDA.
 *
 * On the off chance that some old program relies on the contents of this byte,
 * we fake it here by piecing together information from other places.
 * The Mode Control Register is output-only, so we can't simply read it.
 *
 * Arguments:
 *   CS:BX - Pointer to an entry in the Video Parameter Table
 */
WriteFake3X8:
	PushSet	%ax
	xor	%al, %al

	/* Bit 0: Set for mode 2/3 (80x25 text) */
	cmpb	$0x02, BDA_DISPLAY_MODE
	jl	2f
	cmpb	$0x03, BDA_DISPLAY_MODE
	jg	1f
	or	$0x01, %al
	jmp	2f

	/* Bit 1: Set for mode 4/5 (320x200 4-color graphics) */
1:	cmpb	$0x05, BDA_DISPLAY_MODE
	jg	2f
	or	$0x02, %al

	/* Bit 2: Set for monochrome modes */
2:	testb	$0x02, %cs:(VPT_ATR_CTRL_REGS + ATRR_ATTR_MODE_CTRL)(%bx)
	jz	3f
	or	$0x04, %al

	/* Bit 3: Set if the video signal is enabled */
3:	cmp	$0x03, %cs:(VPT_SEQUENCER_REGS + SEQR_RESET)(%bx)
	jne	4f
	or	$0x08, %al

	/* Bit 4: Set for mode 6 (640x200 monochrome graphics) */
4:	cmpb	$0x06, BDA_DISPLAY_MODE
	jne	5f
	or	$0x10, %al

	/* Bit 5: Set to enable blink instead of background intensity */
5:	testb	$0x08, %cs:(VPT_ATR_CTRL_REGS + ATRR_ATTR_MODE_CTRL)(%bx)
	jz	6f
	or	$0x20, %al

6:	movb	%al, BDA_3X8_SETTING
	PopSet	%ax
	ret

/*
 * Writes byte 0x66 in the BIOS Data Area.
 *
 * I can find no official documentation on the contents of this byte, but the
 * original BIOS reference refers to it as "Current Setting of 3x9 Register",
 * and inofficial data on the web lists it as "palette" information.
 * This makes it the CGA Color Select Register at 0x3b9.
 *
 * On the off chance that some old program relies on the contents of this byte,
 * we fake it here by piecing together information from other places.
 * The Color Select Register is output-only, so we can't simply read it.
 */
WriteFake3X9:

	/* These bits will depend on the handling of CGA modes. */
	movb	$0x00, BDA_3X9_SETTING
	ret

/*
 * Updates the VGA registers to reflect a given video mode.
 * The BIOS Data Area should already have been updated.
 *
 * Arguments:
 *   CS:BX - Pointer to an entry in the Video Parameter Table
 */
UpdateVgaRegisters:

	PushSet	%ax, %cx, %dx, %si

	/* Write the Miscellaneous Output Register */
	movw	$PORT_MISC, %dx
	movb	%cs:(VPT_MISC_OUTPUT_REG)(%bx), %al
	outb	%al, %dx

	/* Clear this before writing attribute-controller registers */
	call	ClearAttributeFlipFlop

	/* Write the other registers (uses BX; clobbers AX, CX, DX, and SI) */
	SetReg	$PORT_SEQ, $SEQR_RESET, $0x03
	SetRegs	$PORT_SEQ, $RCNT_SEQ, VPT_SEQUENCER_REGS, StartIndex=$1
	SetRegs	BDA_CRTC_BASE, $RCNT_CRT, VPT_CRT_CTRL_REGS
	SetRegs	$PORT_ATR, $RCNT_ATR, VPT_ATR_CTRL_REGS, PortOffset=$0
	SetRegs	$PORT_GFX, $RCNT_GFX, VPT_GFX_CTRL_REGS

	PopSet	%ax, %cx, %dx, %si
	ret

/*
 * Turns off the display.
 */
DisableVideoDisplay:
	PushSet	%ax, %dx

	/* Select Clocking Mode register */
	mov	$PORT_SEQ, %dx
	mov	$0x01, %al
	outb	%al, %dx

	/* Set the Screen Off bit */
	inc	%dx
	inb	%dx, %al
	or	$0x20, %al
	outb	%al, %dx

	PopSet	%ax, %dx
	ret

/*
 * Turns on the display.
 */
EnableVideoDisplay:
	PushSet	%ax, %dx

	/* Select Clocking Mode register */
	mov	$PORT_SEQ, %dx
	mov	$0x01, %al
	outb	%al, %dx

	/* Clear the Screen Off bit */
	inc	%dx
	inb	%dx, %al
	and	$0xdf, %al
	outb	%al, %dx

	PopSet	%ax, %dx
	ret

/*
 * Loads the default Video DAC palette values.
 */
LoadDefaultPalette:
	PushSet	%ax, %bx, %cx, %dx, %es

	cmpb	$0x13, BDA_DISPLAY_MODE
	je	0f
	mov	$EgaPalette, %dx	# 64-color palette for modes < 0x13
	mov	$64, %cx
	jmp	1f
0:	mov	$VgaPalette, %dx	# 256-color palette for mode 0x13
	mov	$256, %cx

1:	xor	%bx, %bx
	mov	%cs, %ax
	mov	%ax, %es
	call	HandlePalette_SetBlockOfColorRegisters

	PopSet	%ax, %bx, %cx, %dx, %es
	ret

/*
 * Loads the default font into map 2 of the video memory.
 */
LoadDefaultFont:
	cmpb	$0x03, BDA_DISPLAY_MODE
	je	LoadDefaultFont_0x03
	JmpNotImplemented	"LoadDefaultFont"

/*
 * LoadDefaultFont implementation for VGA mode 0x03.
 */
LoadDefaultFont_0x03:
	PushSet	%ax, %bx, %cx, %dx, %di, %ds

	mov	%cs, %ax
	mov	%ax, %ds

	lea	Font_8x16, %ax	# Primary font table
	lea	Font_9x16, %bx	# Alternate font table
	movw	$256, %cx	# Number of characters
	movw	$16, %dx	# Bytes per character
	xor	%di, %di	# Offset in block
	call	LoadFont

	PopSet	%ax, %bx, %cx, %dx, %di, %ds
	ret

/*
 * Loads a given font into map 2 of the video memory.
 *
 * Arguments:
 *   DS:AX - Primary font table
 *   DS:BX - Alternate font table
 *      CX - Number of characters
 *      DL - Bytes per character
 *      DH - Block to load (0-7)
 *      DI - Offset in the block
 */
LoadFont:
	PushSet	%ax, %cx, %dx, %si, %di, %es, %bp
	mov	%sp, %bp
	cld

	/* Save the current VGA register values */
	PushReg	$PORT_SEQ, $SEQR_MAP_MASK
	PushReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PushReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PushReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PushReg	$PORT_GFX, $GFXR_MISCELLANEOUS

	/* Set the VGA registers for writing */
	SetReg	$PORT_SEQ, $SEQR_MAP_MASK, $0x04	# Write to plane 2
	SetReg	$PORT_SEQ, $SEQR_MEMORY_MODE, $0x06	# 256 KiB sequential
	SetReg	$PORT_GFX, $GFXR_READ_MAP_SELECT, $0x02	# Read from plane 2
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x00	# Direct write
	SetReg	$PORT_GFX, $GFXR_MISCELLANEOUS, $0x00	# 128 KiB at A000

	/* Restore the original %ax and %dx values */
	mov	12(%bp), %ax
	mov	8(%bp), %dx

	/* Set the source address */
	mov	%ax, %si

	/* Calculate the destination address */
	mov	$0xA000, %ax
	mov	%ax, %es
	mov	$0x2000, %ax	# 8 KiB per font table
	push	%dx
	mov	%dh, %dl
	xor	%dh, %dh
	mulw	%dx
	pop	%dx
	add	%ax, %di	# %di = %ax + 8192 * %dh + %di
	xor	%dh, %dh	# %dx = bytes per character

	/* Copy primary font to destination */
0:	push	%cx
	mov	%dx, %cx
	rep	movsb		# Copy the bytes for one character
	pop	%cx
	add	$0x20, %ax	# Step to the next character slot
	mov	%ax, %di
	loop	0b

	/* Is there another alternate character? */
	mov	%bx, %si
1:	movb	%cs:(%si), %al	# Load it into %al
	inc	%si
	test	%al, %al
	jz	2f

	/* Copy it to the destination slot */
	mov	$0x20, %ah
	mul	%ah		# Could be << 5, but it's pointless
	mov	%ax, %di	# %di = 32 * %al
	mov	%dx, %cx
	rep	movsb
	jmp	1b

	/* Restore the original VGA register values */
2:	PopReg	$PORT_GFX, $GFXR_MISCELLANEOUS
	PopReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PopReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PopReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PopReg	$PORT_SEQ, $SEQR_MAP_MASK

	PopSet	%ax, %cx, %dx, %si, %di, %es, %bp
	ret

/*
 * Resets the address flip-flop for Attribute Controller registers.
 *
 * This guarantees that the next byte written will be used as an index.
 */
ClearAttributeFlipFlop:
	PushSet	%ax, %bx, %dx

	/* Get video parameters for the current mode. */
	mov	BDA_DISPLAY_MODE, %al
	call	GetModeEntry

	/* Read the I/O Address Select bit */
	movb	%cs:(VPT_MISC_OUTPUT_REG)(%bx), %al
	test	$0x01, %al # I/O Address Select
	jz	0f

	/*
	 * Read Input Status Register 1 to clear the attribute flip-flop.
	 * This allows us to start writing Attribute Controller registers.
	 * It looks more complicated than it is because the ISR1 address
	 * can change in some modes for backwards compatibility with MDA.
	 */
	movw	$PORT_ISR1_VGA, %dx
	jmp	1f
0:	movw	$PORT_ISR1_MDA, %dx
1:	inb	%dx, %al

	PopSet	%ax, %bx, %dx
	ret

/*
 * Returns the current number of display pages.
 *
 * Returns:
 *      AL - Number of display pages
 */
GetPageCount:
	PushSet	%bx

	/* Validate the current display mode, just in case... */
	xor	%al, %al
	movb	BDA_DISPLAY_MODE, %bl
	cmp	$0x13, %bl
	ja	0f

	/* Load the number of pages from memory */
	xor	%bh, %bh
	movb	%cs:PageCountArray(%bx), %al

0:	PopSet	%bx
	ret

/*
 * Clears the video buffer by filling it with zero bytes in all planes.
 */
ClearVideoBuffer:
	PushSet	%ax, %bx, %cx, %dx, %di, %es

	/* Get video parameters for the current mode */
	movb	BDA_DISPLAY_MODE, %al
	call	GetModeEntry

	/* Write the same data to all planes (Mode 0) */
	movb	%cs:(VPT_GFX_CTRL_REGS + GFXR_GRAPHICS_MODE)(%bx), %ah
	and	$0xfc, %ah
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, %ah

	/* Find location and size of the video buffer */
	mov	%cs:(VPT_GFX_CTRL_REGS + GFXR_MISCELLANEOUS)(%bx), %dl
	and	$0x0c, %dl # Memory Map
	xor	%ax, %ax
	xor	%di, %di
	cld

	/* Clear the video buffer */
	test	$0x08, %dl	# 32 KiB buffer?
	jz	1f
	mov	$0x4000, %cx
	test	$0x04, %dl	# Buffer at B8000?
	jnz	0f
	mov	$0xB000, %bx	# 32 KiB at B0000
	jmp	3f
0:	mov	$0xB800, %bx	# 32 KiB at B8000
	jmp	3f
1:	mov	$0xA000, %bx	# 64+ KiB at A0000
	mov	$0x8000, %cx
	test	$0x04, %dl	# Only 64 KiB?
	jnz	3f
	mov	%bx, %es	# 128 KiB at A0000
	rep	stosw
	mov	$0x8000, %cx
3:	mov	%bx, %es
	rep	stosw

	PopSet	%ax, %bx, %cx, %dx, %di, %es
	ret

/*
 * Clears all pages by filling them with white-on-black space characters.
 *
 * This function does nothing if the current mode is not a text mode.
 */
ClearTextPages:
	PushSet	%ax, %bx, %cx, %dx, %di, %es

	call	IsTextMode
	jne	1f

	/* Calculate the number of characters per page */
	mov	BDA_LAST_ROW_INDEX, %al
	inc	%al
	mulb	BDA_NUMBER_OF_COLUMNS
	mov	%ax, %dx

	/* Get the number of pages */
	call	GetPageCount	# -> %al
	mov	%al, %bl

	/* Set character, attribute, and start page */
	mov	$0x0720, %ax
	xor	%bh, %bh

	/* Fill the pages one by one */
0:	call	GetPageAddress	# -> %es
	mov	%dx, %cx
	xor	%di, %di
	rep	stosw
	inc	%bh
	cmp	%bl, %bh
	jb	0b

1:	PopSet	%ax, %bx, %cx, %dx, %di, %es
	ret

/*
 * WriteDot implementation for VGA mode 0x12.
 *
 * Arguments:
 *      AL - Color value (bit 7 means XOR)
 *      CX - Column number
 *      DX - Row number
 */
WriteDot_0x12:
	PushSet	%ax, %bx, %cx, %dx, %es, %si, %di

	/* Get address and mask for the pixel */
	call	GetPixelAddress	# -> Address in %es:%bx; Mask in %ah

	/* Store mask in %ch and color in %cl */
	mov	%ax, %cx

	/* Select the function */
	test	$0x80, %cl	# Bit 7 means XOR
	jnz	0f
	xor	%ah, %ah	# Replace
	jmp	1f
0:	mov	$0x18, %ah	# XOR
1:	and	$0x0f, %cl

	/* Set the type of graphics write; this clobbers AL and DX */
	SetReg	$PORT_GFX, $GFXR_SET_RESET, %cl		# Color
	SetReg	$PORT_GFX, $GFXR_DATA_ROTATE, %ah	# Function
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x03	# Mode 3
	SetReg	$PORT_GFX, $GFXR_BIT_MASK, $0xff	# Mask

	/* Read the byte to latch existing data */
	mov	%bx, %si
	mov	%bx, %di	# Only needed for movsb
	es movsb		# lodsb kills bhyve emulator (2019-05-29)

	/* Write the byte */
	mov	%bx, %di
	mov	%ch, %al
	stosb

	PopSet	%ax, %bx, %cx, %dx, %es, %si, %di
	ret

/*
 * ReadDot implementation for VGA mode 0x12.
 *
 * Arguments:
 *      CX - Column number
 *      DX - Row number
 *
 * Returns:
 *      AL - Color value
 */
ReadDot_0x12:
	PushSet	%bx, %cx, %dx, %es, %si
	mov	%ah, %al

	/* Get address and mask for the pixel */
	call	GetPixelAddress	# -> Address in %es:%bx; Mask in %ah

	mov	$0x0803, %cx	# Bit in %ch; plane in %cl
	mov	%al, %dh	# Original %ah value
	xor	%dl, %dl	# Result

	/* Read a byte from the plane; the macro clobbers AL and DX */
0:	push	%dx
	SetReg	$PORT_GFX, $GFXR_READ_MAP_SELECT, %cl
	pop	%dx
	mov	%bx, %si
	es_lodsb	# or "mov %es:(%bx), %al" if you prefer that

	/* Copy one bit to the result */
	and	%ah, %al
	jz	1f
	or	%ch, %dl
1:	dec	%cl
	shr	$1, %ch
	test	%ch, %ch
	jnz	0b

	mov	%dx, %ax

	PopSet	%bx, %cx, %dx %es, %si
	ret

/*
 * Returns address and bit mask for the pixel at a given location.
 *
 * Arguments:
 *      CX - Column number
 *      DX - Row number
 *
 * Returns:
 *   ES:BX - Byte address
 *      AH - Bit mask
 */
GetPixelAddress:
	PushSet	%cx, %dx

	/* Calculate the byte address */
	call	GetPageAddress	# Sets %es
	push	%ax
	mov	%dx, %ax
	mulw	BDA_NUMBER_OF_COLUMNS
	mov	%cx, %bx
	shr	$1, %bx
	shr	$1, %bx
	shr	$1, %bx
	add	%ax, %bx	# %bx = BDA_NUMBER_OF_COLUMNS * %dx + %cx / 8
	pop	%ax

	/* Calculate the bit mask */
	and	$0x07, %cl
	mov	$0x80, %ah
	shr	%cl, %ah	# %ah = (0x80 >> (%cl % 8))

	PopSet	%cx, %dx
	ret

/*
 * Updates cursor position and scroll state for special teletype characters.
 * Handled characters are Bell, Backspace, Line Feed, and Carriage Return.
 *
 * Clears the carry flag if the character was handled or sets it to carry on.
 *
 * Arguments:
 *      AH - Write mode (bit 0: update cursor)
 *      AL - The character to handle
 *      DH - Row (zero-based)
 *      DL - Column (zero-based)
 *
 * Returns:
 *      DH - The new row
 *      DL - The new column
 *      CF - Set if and only if the character was not handled
 */
HandleSpecialChar:

	PushSet	%ax

	/* Bell (0x07): Ignore this for now */
	cmp	$0x07, %al
	je	4f

	/* Backspace (0x08): Step left unless it's the leftmost column */
	cmp	$0x08, %al
	jne	0f
	cmp	$0, %dl
	je	4f
	dec	%dl
	jmp	3f

	/* Line Feed (0x0A): Step down unless it's the last row */
0:	cmp	$'\n', %al	# 0x0A: Line Feed
	jne	2f
	cmp	BDA_LAST_ROW_INDEX, %dh
	je	1f
	inc	%dh
	jmp	3f

	/* Line Feed (0x0A): Scroll up if it's the last row */
1:	PushSet	%ax, %bx, %cx, %dx
	mov	$1, %al		# Number of lines to scroll
	mov	$0x07, %bh	# Attribute: white on black
	xor	%cx, %cx	# Upper left corner of scroll
	mov	$0xffff, %dx	# Lower right corner of scroll
	call	ScrollActivePageUp
	PopSet	%ax, %bx, %cx, %dx
	jmp	4f

	/* Carriage Return (0x0D): Go to the leftmost column */
2:	cmp	$'\r', %al
	jne	5f
	xor	%dl, %dl

	/* Set the cursor position */
3:	test	$0x01, %ah
	jz	4f
	call	SetCursorPosition

	/* Update the carry flag and return */
4:	clc
	jmp	6f
5:	stc
6:	PopSet	%ax
	ret

/*
 * Writes a character to the screen with cursor updating and scrolling.
 *
 * The following special characters are handled and do what you might expect:
 *   0x07 (BEL: "\a"), 0x08 (BS: "\b"), 0x0A (LF: "\n"), and 0x0D (CR: "\r")
 *
 * All other characters are simply printed using the current font.
 *
 * Arguments:
 *   ES:BP - Pointer to character
 *      AL - Write mode (bit 0: update cursor; bit 1: attributes in string)
 *      BH - Page number (zero-based)
 *      DH - Display row
 *      DL - Display column
 *
 * Returns:
 *   ES:BP - The next character
 *      DH - Updated row
 *      DL - Updated column
 */
WriteSingleStringCharacter:
	PushSet	%ax, %bx, %cx
	mov	%al, %ah
	mov	$1, %cx

	/* Read the character */
	mov	%es:(%bp), %al
	inc	%bp

	/* Handle special characters */
	call	HandleSpecialChar
	jc	0f
	test	$0x02, %ah
	jz	4f
	inc	%bp
	jmp	4f

	/* Just write the character if there is no attribute */
0:	test	$0x02, %ah
	jnz	1f
	call	WriteCharacter
	jmp	2f

	/* Otherwise read the attribute and use that too */
1:	mov	%es:(%bp), %bl
	inc	%bp
	call	WriteCharacterAndAttribute

	/* Advance the write position */
2:	inc	%dl
	cmp	BDA_NUMBER_OF_COLUMNS, %dl
	jb	3f
	xor	%dl, %dl
	inc	%dh

	/* Update the cursor if necessary */
3:	test	$0x01, %ah
	jz	4f
	call	SetCursorPosition

4:	PopSet	%ax, %bx, %cx
	ret

/*
 * Returns the current VGA display buffer.
 *
 * Returns:
 *      ES - Display buffer
 */
GetDisplayBuffer:
	PushSet	%ax

	cmpb	$7, BDA_DISPLAY_MODE
	je	0f
	ja	1f
	mov	$0xB800, %ax	# Modes 0x00-0x06
	jmp	2f
0:	mov	$0xB000, %ax	# Mode  0x07
	jmp	2f
1:	mov	$0xA000, %ax	# Modes 0x08-0x13
2:	mov	%ax, %es

	PopSet	%ax
	ret

/*
 * Returns the address for a given page.
 *
 * Arguments:
 *      BH - Page number (zero-based)
 *
 * Returns:
 *      ES - The beginning of the page
 */
GetPageAddress:
	PushSet	%ax, %bx, %cx, %dx

	/* Get the buffer address */
	call	GetDisplayBuffer	# Sets %es

	/* Add the page offset */
	mov	%bh, %al
	xor	%ah, %ah
	mulw	BDA_VIDEO_PAGE_SIZE	# Clears %dx
	mov	$4, %cl
	shr	%cl, %ax
	mov	%es, %bx
	add	%ax, %bx
	mov	%bx, %es

	PopSet	%ax, %bx, %cx, %dx
	ret

/*
 * Sets the zero flag if the current display mode is a text mode.
 *
 * This allows you to use je or jne instructions after the call,
 * which is arguably more readable than using the carry flag.
 */
IsTextMode:
	PushSet	%ax

	/* Check current display mode for known text modes */
	mov	BDA_DISPLAY_MODE, %ah
	cmp	$3, %ah # Modes 0-3 are text
	jbe	0f
	cmp	$7, %ah # Mode 7 is also text
	je	0f
	jmp	1f	# Anything else is graphics

	/* Set the zero flag accordingly */
0:	and	$0, %ah	# Set zero flag
	jmp	2f
1:	or	$1, %ah # Clear zero flag

2:	PopSet	%ax
	ret

/*** State Saving and Restoring ***********************************************/

/*
 * Saves 70 bytes of VGA video hardware state.
 *
 * The layout follows that documented by Ralf Brown
 * in inter61a/INTERRUP.A of RBIL Release 61:
 *
 *   Offset  Size    Description
 *    00h    BYTE    sequencer index register
 *    01h    BYTE    CRTC index register
 *    02h    BYTE    graphics controller index register
 *    03h    BYTE    attribute controller index register
 *    04h    BYTE    feature controller register
 *    05h  4 BYTEs   sequencer registers
 *    09h    BYTE    sequencer register 0
 *    0Ah 25 BYTEs   CRTC registers 0-8 [presumably typo for 00h-18h]
 *    23h 16 BYTEs   palette registers 00h-0Fh
 *    33h  4 BYTEs   attribute registers 10h-13h
 *    37h  9 BYTEs   graphics controller registers 0-8
 *    40h    BYTE    CRTC base address (low)
 *    41h    BYTE    CRTC base address (high)
 *    42h    BYTE    plane 0 latch
 *    43h    BYTE    plane 1 latch
 *    44h    BYTE    plane 2 latch
 *    45h    BYTE    plane 3 latch
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_Hardware:
	PushSet	%ax, %cx, %dx

	/* Save the index registers */
	call	SaveVideoState_Hardware_IndexRegisters

	/* Save the sequencer registers */
	mov	$0x0104, %cx
	mov	$PORT_SEQ, %dx
	call	SaveVideoState_Hardware_DataRegisters
	mov	$0x0000, %cx
	call	SaveVideoState_Hardware_DataRegisters

	/* Save the CRTC registers */
	mov	$0x0018, %cx
	mov	BDA_CRTC_BASE, %dx
	call	SaveVideoState_Hardware_DataRegisters

	/* Save palette and attribute registers */
	call	ClearAttributeFlipFlop
	mov	$0x0013, %cx
	mov	$PORT_ATR, %dx
	call	SaveVideoState_Hardware_DataRegisters

	/* Save the Graphics Controller registers */
	mov	$0x0008, %cx
	mov	$PORT_GFX, %dx
	call	SaveVideoState_Hardware_DataRegisters

	/* Save the CRTC base address */
	mov	BDA_CRTC_BASE, %ax
	mov	%al, %es:(%bx, %di)
	inc	%di
	mov	%ah, %es:(%bx, %di)
	inc	%di

	/* Save the latches */
	call	SaveVideoState_Hardware_Latches

	PopSet	%ax, %cx, %dx
	ret

/*
 * Restores state previously saved by SaveVideoState_Hardware.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index in buffer
 *
 * Returns:
 *      SI - An updated index
 */
RestoreVideoState_Hardware:
	PushSet	%ax, %cx, %dx

	/* Restore the CRTC base address */
	mov	%es:SVS_CRTC_BASE_HIGH(%bx, %di), %ah
	mov	%es:SVS_CRTC_BASE_LOW(%bx, %di), %al
	mov	%ax, BDA_CRTC_BASE

	/* Restore the sequencer registers */
	mov	$SVS_SEQ_REGS, %ax
	mov	$0x0104, %cx
	mov	$PORT_SEQ, %dx
	call	RestoreVideoState_Hardware_DataRegisters
	add	$4, %ax
	mov	$0x0000, %cx
	call	RestoreVideoState_Hardware_DataRegisters

	/* Restore the CRTC registers */
	mov	$SVS_CRTC_REGS, %ax
	mov	$0x0018, %cx
	mov	BDA_CRTC_BASE, %dx
	call	RestoreVideoState_Hardware_DataRegisters

	/* Restore palette and attribute registers */
	mov	$SVS_ATR_REGS, %ax
	mov	$0x0013, %cx
	mov	$PORT_ATR, %dx
	call	RestoreVideoState_Hardware_DataRegisters

	/* Restore Graphics Controller registers */
	mov	$SVS_GFX_REGS, %ax
	mov	$0x0008, %cx
	mov	$PORT_GFX, %dx
	call	RestoreVideoState_Hardware_DataRegisters

	/* Restore index registers and latches */
	call	RestoreVideoState_Hardware_IndexRegisters
	call	RestoreVideoState_Hardware_Latches

	/* Skip to the next block of saved state */
	add	$70, %si

	PopSet	%ax, %cx, %dx
	ret

/*
 * Saves 96 bytes of BIOS Data Area from 40:49 to 40:A8.
 * This layout follows that documented in RBIL Release 61.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_BiosDataArea:
	PushSet	%si

	/* This saves a lot more than just video state... */
	mov	$96, %cx
	mov	$0x49, %si
	add	%bx, %di
	rep	movsb
	sub	%bx, %di

	PopSet	%si
	ret

/*
 * Restores state previously saved by SaveVideoState_BiosDataArea.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index in buffer
 *
 * Returns:
 *      SI - An updated index
 */
RestoreVideoState_BiosDataArea:
	PushSet	%di

	Swap	%ds, %es
	add	%bx, %si

	/* Restore Video Control Data Area 1 (40:49 to 40:66) */
	mov	$30, %cx
	mov	$0x49, %di
	rep	movsb

	/* Restore Video Control Data Area 2 (40:84 to 40:8A) */
	mov	$7, %cx
	mov	$0x84, %di
	rep	movsb

	sub	%bx, %si
	Swap	%ds, %es

	PopSet	%di
	ret

/*
 * Saves 772 bytes of DAC state and color registers.
 *
 * The layout follows that documented by Ralf Brown
 * in inter61a/INTERRUP.A of RBIL Release 61:
 *
 *   Offset    Size    Description
 *     00h     BYTE    read/write mode DAC
 *     01h     BYTE    pixel [palette?] address
 *     02h     BYTE    pixel mask
 *     03h 768 BYTEs   color data (256 triples)
 *    303h     BYTE    color select register
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_DacAndColor:
	PushSet	%ax, %cx, %dx

	/* Save the DAC state */
	mov	$PORT_DAC_STATE, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	/* Save the palette address */
	mov	$PORT_DAC_WRITE, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	/* Save the pixel mask */
	mov	$PORT_DAC_MASK, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	/* Reset the color index */
	mov	$PORT_PALETTE_READ, %dx
	xor	%al, %al
	outb	%al, %dx

	/* Save the color data */
	mov	$768, %cx
	mov	$PORT_PALETTE_DATA, %dx
0:	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di
	loop	0b

	/* Save the color select register */
	call	ClearAttributeFlipFlop
	mov	$0x1414, %cx
	mov	$PORT_ATR, %dx
	call	SaveVideoState_Hardware_DataRegisters

	PopSet	%ax, %cx, %dx
	ret

/*
 * Restores state previously saved by SaveVideoState_DacAndColor.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index in buffer
 *
 * Returns:
 *      SI - An updated index
 */
RestoreVideoState_DacAndColor:
	PushSet	%ax, %cx, %dx

	/* Read the DAC state */
	mov	%es:(%bx, %si), %ah
	inc	%si

	/* Read the palette address */
	mov	%es:(%bx, %si), %al
	inc	%si

	/* Note: the pixel mask should not be written */
	push	%ax
	inc	%si

	/* Reset the color index */
	mov	$PORT_PALETTE_WRITE, %dx
	xor	%al, %al
	outb	%al, %dx

	/* Restore the color data */
	mov	$768, %cx
	mov	$PORT_PALETTE_DATA, %dx
0:	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si
	loop	0b

	/* Restore the color select register */
	call	ClearAttributeFlipFlop
	mov	$0x0000, %ax
	mov	$0x1414, %cx
	mov	$PORT_ATR, %dx
	call	RestoreVideoState_Hardware_DataRegisters
	inc	%si

	/* Restore DAC state and palette address */
	pop	%ax
	test	%ah, %ah
	jz	1f
	mov	$PORT_DAC_READ, %dx
	jmp	2f
1:	mov	$PORT_DAC_WRITE, %dx
2:	outb	%al, %dx

	PopSet	%ax, %cx, %dx
	ret

/*
 * Saves current values of the index registers.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_Hardware_IndexRegisters:
	PushSet	%ax, %dx

	mov	$PORT_SEQ, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	mov	BDA_CRTC_BASE, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	mov	$PORT_GFX, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	mov	$PORT_ATR, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	mov	$PORT_FEAT_READ, %dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di

	PopSet	%ax, %dx
	ret

/*
 * Restores values of the index registers.
 *
 * Note that this function does NOT update the SI register.
 * The SI register is updated once in RestoreVideoState_Hardware.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index of hardware state in buffer
 */
RestoreVideoState_Hardware_IndexRegisters:
	PushSet	%ax, %dx, %si

	mov	$PORT_SEQ, %dx
	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si

	mov	BDA_CRTC_BASE, %dx
	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si

	mov	$PORT_GFX, %dx
	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si

	mov	$PORT_ATR, %dx
	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si

	mov	$PORT_FEAT_READ, %dx
	mov	%es:(%bx, %si), %al
	outb	%al, %dx
	inc	%si

	PopSet	%ax, %dx, %si
	ret

/*
 * Saves a range of VGA register values.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      CH - First register index
 *      CL - Last register index
 *      DX - The index register
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_Hardware_DataRegisters:
	PushSet	%ax, %cx

0:	mov	%ch, %al
	outb	%al, %dx
	inc	%dx
	inb	%dx, %al
	mov	%al, %es:(%bx, %di)
	inc	%di
	dec	%dx
	inc	%ch
	cmp	%cl, %ch
	jbe	0b

	PopSet	%ax, %cx
	ret

/*
 * Restores a range of VGA register values.
 *
 * Note that this function does NOT update the SI register.
 * The SI register is updated once in RestoreVideoState_Hardware.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index of hardware state in buffer
 *      AX - Index of registers in hardware state
 *      CH - First register index
 *      CL - Last register index
 *      DX - The index register
 */
RestoreVideoState_Hardware_DataRegisters:
	PushSet	%ax, %cx, %si

	add	%ax, %si
0:	mov	%ch, %al
	outb	%al, %dx
	inc	%dx
	mov	%es:(%bx, %si), %al
	inc	%si
	outb	%al, %dx
	dec	%dx
	inc	%ch
	cmp	%cl, %ch
	jbe	0b

	PopSet	%ax, %cx, %si
	ret

/*
 * Saves current values of the VGA latches.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      DI - Index in buffer
 *
 * Returns:
 *      DI - An updated index
 */
SaveVideoState_Hardware_Latches:
	PushSet	%ax, %cx, %dx, %bp, %ds

	/* Save the current VGA register values */
	PushReg	$PORT_SEQ, $SEQR_MAP_MASK
	PushReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PushReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PushReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PushReg	$PORT_GFX, $GFXR_MISCELLANEOUS

	/* Set the VGA registers for writing */
	SetReg	$PORT_SEQ, $SEQR_MAP_MASK, $0x0f	# Write to all planes
	SetReg	$PORT_SEQ, $SEQR_MEMORY_MODE, $0x06	# 256 KiB sequential
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x01	# Write latch content
	SetReg	$PORT_GFX, $GFXR_MISCELLANEOUS, $0x00	# 128 KiB at A000

	/* Write the latch values to address 0xbffff */
	mov	$0xb000, %ax
	mov	%ax, %ds
	mov	$0xffff, %bp
	xor	%al, %al
	mov	%al, %ds:(%bp)

	/* Save the latch values */
	xor	%cl, %cl
0:	SetReg	$PORT_GFX, $GFXR_READ_MAP_SELECT, %cl
	mov	%ds:(%bp), %al
	mov	%al, %es:(%bx, %di)
	inc	%di
	inc	%cl
	cmp	$4, %cl
	jb	0b

	/* Restore the original VGA register values */
	PopReg	$PORT_GFX, $GFXR_MISCELLANEOUS
	PopReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PopReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PopReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PopReg	$PORT_SEQ, $SEQR_MAP_MASK

	PopSet	%ax, %cx, %dx
	ret

/*
 * Restores values of the VGA latches.
 *
 * Note that this function does NOT update the SI register.
 * The SI register is updated once in RestoreVideoState_Hardware.
 *
 * Arguments:
 *   ES:BX - Buffer pointer
 *      SI - Index of hardware state in buffer
 */
RestoreVideoState_Hardware_Latches:
	PushSet	%ax, %cx, %dx, %bp, %si, %ds

	/* Save the current VGA register values */
	PushReg	$PORT_SEQ, $SEQR_MAP_MASK
	PushReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PushReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PushReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PushReg	$PORT_GFX, $GFXR_MISCELLANEOUS

	/* Set the VGA registers for writing */
	SetReg	$PORT_SEQ, $SEQR_MEMORY_MODE, $0x06	# 256 KiB sequential
	SetReg	$PORT_GFX, $GFXR_GRAPHICS_MODE, $0x00	# Direct write
	SetReg	$PORT_GFX, $GFXR_MISCELLANEOUS, $0x00	# 128 KiB at A000

	/* Use address 0xbffff as a scratch pad */
	mov	$0xb000, %ax
	mov	%ax, %ds
	mov	$0xffff, %bp

	/* Restore the latch values by reading */
	mov	0x0100, %cx
0:	SetReg	$PORT_SEQ, $SEQR_MAP_MASK, %ch
	SetReg	$PORT_GFX, $GFXR_READ_MAP_SELECT, %cl
	mov	%es:SVS_LATCHES(%bx, %si), %al
	inc	%si
	mov	%al, %ds:(%bp)	# Write the value...
	mov	%ds:(%bp), %al	# ...and read it back
	shl	$1, %ch		# Update write plane
	inc	%cl		# Update read plane
	cmp	$4, %cl
	jb	0b

	/* Restore the original VGA register values */
	PopReg	$PORT_GFX, $GFXR_MISCELLANEOUS
	PopReg	$PORT_GFX, $GFXR_GRAPHICS_MODE
	PopReg	$PORT_GFX, $GFXR_READ_MAP_SELECT
	PopReg	$PORT_SEQ, $SEQR_MEMORY_MODE
	PopReg	$PORT_SEQ, $SEQR_MAP_MASK

	PopSet	%ax, %cx, %dx, %bp, %si, %ds
	ret

/*
 * Returns the current value of the 8254 PIT Counter.
 *
 * Returns:
 *      AX - The 16-bit counter
 */
GetTimerCounter:
	xor	%ax, %ax
	outb	%al, $0x43	# Latch count value
	inb	$0x40, %al	# Read low byte
	mov	%al, %ah
	inb	$0x40, %al	# Read high byte
	xchg	%al, %ah
	ret

/*
 * Sleeps for a while, spinning furiously until the time has come.
 *
 * Interrupts are off, but the 8254 timer should be running in the background.
 * We're using that to get reasonably accurate delay times.
 *
 * Arguments:
 *      AX - Seconds
 *      BX - Milliseconds
 */
Delay:
	PushSet	%ax, %bx, %cx, %dx

	/* Go from s and ms to 32-bit ms value */
	mov	$1000, %dx
	mulw	%dx
	add	%bx, %ax
	adc	$0, %dx

	/* Go from ms in %dx:%ax to subticks in %cx:%dx */
	mov	%dx, %cx
	mulw	%cs:SubticksPerMillisecond
	mov	%ax, %bx
	mov	%cx, %ax
	mov	%dx, %cx
	mulw	%cs:SubticksPerMillisecond
	add	%ax, %cx
	mov	%bx, %dx

	/* Get a base value */
	call	GetTimerCounter
	mov	%ax, %bx

	/* Loop until we're done */
0:	call	GetTimerCounter
	sub	%ax, %bx	# Get number of passed subticks
	sub	%bx, %dx	# Subtract them from the delay counter
	mov	%ax, %bx	# Remember the last timer value
	jnc	0b		# Continue if there were subticks left
	sub	$1, %cx		# Borrow from the high delay word
	jnc	0b		# End when there's nothing left

1:	PopSet	%ax, %bx, %cx, %dx
	ret

/*** Protected Mode ***********************************************************/

.arch i386
.code16

/*
 * Segment selectors matching the Global Descriptor Table.
 */
#define	CODE16_SEL	0x0008
#define	DATA16_SEL	0x0010
#define	CODE32_SEL	0x0018
#define	DATA32_SEL	0x0020

/*
 * The structure used for LGDT operations.
 */
.align 8
GDT_Descriptor:
GDT_Descriptor.Limit:
.word	(GDT_end - GDT) - 1
GDT_Descriptor.Base:
.long	GDT

/*
 * Global Descriptor Table (GDT) for protected mode.
 */
.align 8
GDT:
GDT.NULL:
	.word	0x0000
	.word	0x0000
	.long	0x00000000
GDT.Code16:
	.word	0xffff	/* Limit (bits  0-15) */
	.word	0x0000	/* Base  (bits  0-15) */
	.byte	0x00	/* Base  (bits 16-23) */
	.byte	0x90 |	/* Present, Ring 0, Code/Data */\
		0x0b	/* Code: Execute/Read, accessed */
	.byte	0x00 |	/* G=0, D=0 (16-bit)  */\
		0x00	/* Limit (bits 16-19) */
	.byte	0x00	/* Base  (bits 24-31) */
GDT.Data16:
	.word	0xffff	/* Limit (bits  0-15) */
	.word	0x0000	/* Base  (bits  0-15) */
	.byte	0x00	/* Base  (bits 16-23) */
	.byte	0x90 |	/* Present, Ring 0, Code/Data */\
		0x03	/* Data: Read/Write, accessed */
	.byte	0x00 |	/* G=0, B=0 (16-bit)  */\
		0x00	/* Limit (bits 16-19) */
	.byte	0x00	/* Base  (bits 24-31) */
GDT.Code32:
	.word	0xffff	/* Limit (bits  0-15) */
	.word	0x0000	/* Base  (bits  0-15) */
	.byte	0x00	/* Base  (bits 16-23) */
	.byte	0x90 |	/* Present, Ring 0, Code/Data */\
		0x0b	/* Code: Execute/Read, accessed */
	.byte	0xc0 |	/* G=1, D=1 (32-bit)  */\
		0x0f	/* Limit (bits 16-19) */
	.byte	0x00	/* Base  (bits 24-31) */
GDT.Data32:
	.word	0xffff	/* Limit (bits  0-15) */
	.word	0x0000	/* Base  (bits  0-15) */
	.byte	0x00	/* Base  (bits 16-23) */
	.byte	0x90 |	/* Present, Ring 0, Code/Data */\
		0x03	/* Data: Read/Write, accessed */
	.byte	0xc0 |	/* G=1, B=1 (32-bit)  */\
		0x0f	/* Limit (bits 16-19) */
	.byte	0x00	/* Base  (bits 24-31) */
GDT_end:

/*
 * Enters protected mode to unlock 32-bit memory access.
 *
 * Most of this video BIOS intentionally uses code that would run on an
 * Intel 8086 processor from 1978. That is partially because it may run on
 * limited real-mode emulators and partially because 16 bits are enough.
 * This will help for the few occasions when 32-bit addressing is needed.
 *
 * You would typically call this function via the Enter32 macro.
 */
EnterProtectedMode:
	PushSet	%ax, %eax, %ebx, %bp
	mov	%sp, %bp
	pushf
	cli

	/* Convert the return address to 32 bits */
	mov	%cs, %eax	# Load the code segment
	shl	$4, %eax	# %eax = %cx << 4
	movzwl	12(%bp), %ebx	# Load the 16-bit return address
	add	%ebx, %eax	# Add it to the total result
	movl	%eax, 10(%bp)	# Save the 32-bit return address

	/* Enable protected mode */
	lgdt	%cs:GDT_Descriptor
	movl	%cr0, %eax
	or	$0x01, %al
	movl	%eax, %cr0

	/* Make the actual switch */
PatchedJump1:
	ljmpl	$CODE32_SEL, $(0f)

.code32	/* Adjust the stack pointer */
0:	mov	%ss, %eax
	shl	$4, %eax
	add	%eax, %esp

	/* Reload the segment registers */
	mov	$DATA32_SEL, %ax
	mov	%ax, %ds
	mov	%ax, %ss
	mov	%ax, %es
	mov	%ax, %fs
	mov	%ax, %gs

data16	popf
	PopSet	%eax, %ebx, %bp
	ret

/*
 * Returns to 16-bit real mode.
 *
 * You would typically call this function via the Leave32 macro.
 */
LeaveProtectedMode:
	PushSet	%eax, %ebp
	mov	%esp, %ebp
data16	pushf
	cli

	/* Convert the return address to 16 bits */
	mov	8(%ebp), %ax	# Shift the return address...
	mov	%ax, 10(%ebp)	# ...overwriting the upper word
	mov	4(%ebp), %eax	# Shift	saved %eax
	mov	%eax, 6(%ebp)
	mov	0(%ebp), %eax	# Shift saved %ebp
	mov	%eax, 2(%ebp)
	mov	-2(%ebp), %eax	# Shift saved flags
	mov	%eax, 0(%ebp)
	add	$2, %esp	# Shift stack pointer

	/* Switch to 16-bit protected mode */
	ljmp	$CODE16_SEL, $(0f)

.code16	/* Reload the segment registers */
0:	mov	$DATA16_SEL, %ax
	mov	%ax, %ds
	mov	%ax, %ss
	mov	%ax, %es
	mov	%ax, %fs
	mov	%ax, %gs

	/* Disable protected mode */
	movl	%cr0, %eax
	and	$0xfe, %al
	movl	%eax, %cr0

	/* Make the actual switch */
PatchedJump2:
	jmp	$0xC000, $1f

	/* Restore the stack segment */
1:	mov	%esp, %eax
	shr	$4, %eax
	and	$0xf000, %ax
	and	$0xffff, %esp
	mov	%ax, %ss

	/* Restore the data segment */
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds

	/* Clear the other segments */
	xor	%ax, %ax
	mov	%ax, %es
	mov	%ax, %fs
	mov	%ax, %gs

	popf
	PopSet	%eax, %ebp
	ret

/*
 * Updates 32-bit pointers to reflect the current code segment.
 */
AdjustLongPointers:
	PushSet	%eax

	/* Calculate the segment start */
	mov	%cs, %eax
	shl	$4, %eax

	/* Add it to all relevant pointers */
	add	%eax, %cs:(GDT_Descriptor.Base)
	add	%eax, %cs:(GDT.Code16 + 2)
	add	%eax, %cs:(PatchedJump1 + 2)

	PopSet	%eax
	ret

/*** 32-bit Functions *********************************************************/

.arch i386
.code32

/*
 * Wraps a 32-bit function to make it callable from 16-bit real mode.
 *
 * Arguments:
 *   Name - Function name including the following colon
 */
.macro Func32 Name
.arch i8086
.code16
\Name
	Enter32
	call	0f
	Leave32
	ret
.arch i386
.code32
0:
Func32_\Name
.endm

/*
 * Calls a 16-bit real-mode function from 32-bit protected mode.
 *
 * Arguments:
 *   Name - The function to call
 */
.macro Call16 Name
Leave32
	call	\Name
Enter32
.endm

/*
 * Calls a "Func32" function directly from protected mode.
 *
 * Functions wrapped by "Func32" would normally be called from real mode.
 * You could use Call16 to call them from protected mode, but this avoids
 * the extra step of leaving protected mode just to immediately come back.
 *
 * Arguments:
 *   Name - The function to call
 */
.macro Call32 Name
	call	Func32_\Name
.endm

/*
 * Clears the framebuffer for a given VESA mode.
 *
 * Arguments:
 *   CS:BX - The ModeInfoArray (MIA) entry
 */
Func32 ClearVesaBuffer:
	PushSet	%eax, %ebx, %ecx, %edx, %ebp, %edi

	/* Get the BIOS start address */
	call	0f
0:	pop	%ebp
	sub	$(0b), %ebp

	/* Get the framebuffer */
	movl	PhysBasePtr(%ebp), %edi

	/* Get the ModeInfoArray entry */
	movzwl	%bx, %ebx
	add	%ebp, %ebx

	/* Calculate the number of bytes */
	movzwl	MIA_WIDTH(%ebx), %eax
	movzwl	MIA_HEIGHT(%ebx), %edx
	mul	%edx
	movzwl	MIA_DEPTH(%ebx), %edx
	shr	$3, %edx
	mul	%edx

	/* Clear the buffer */
	mov	%eax, %ecx
	xor	%al, %al
	rep	stosb

	PopSet	%eax, %ebx, %ecx, %edx, %ebp, %edi
	ret

/*
 * Loads the splash screen and blocks for a little while.
 */
#ifdef	SPLASH
Func32 ShowSplashScreen:
	PushSet	%eax, %ebx, %ecx, %edx, %ebp, %esi, %edi
	xor	%eax, %eax

	/* Get the BIOS start address */
	call	0f
0:	pop	%ebp
	sub	$(0b), %ebp

	/* Set the framebuffer dimensions */
	mov	SplashWidth(%ebp), %ax
	mov	SplashHeight(%ebp), %bx
	mov	$24, %cx
	Call16	SetBufferShape

	/* Calculate the number of pixels */
	mul	%bx
	shl	$16, %edx
	add	%eax, %edx

	/* Get the palette data */
	lea	SplashPalette(%ebp), %ebx

	/* Get the packed image data */
	lea	SplashImage(%ebp), %esi

	/* Get the framebuffer */
	movl	PhysBasePtr(%ebp), %edi

	/* Read the color index */
1:	movb	(%esi), %al
	inc	%esi

	/* Read the pixel count */
	mov	$1, %ecx
	cmp	SplashLevel2(%ebp), %al
	ja	2f
	movw	(%esi), %cx
	add	$2, %esi
	jmp	4f
2:	cmp	SplashLevel1(%ebp), %al
3:	ja	4f
	movb	(%esi), %cl
	inc	%esi

	/* Write the pixels */
4:	sub	%ecx, %edx
	push	%edx
	mov	$3, %dl
	mul	%dl
5:	movb	0(%ebx, %eax), %dl
	movb	%dl, 2(%edi)
	movb	1(%ebx, %eax), %dl
	movb	%dl, 1(%edi)
	movb	2(%ebx, %eax), %dl
	movb	%dl, 0(%edi)
	add	$3, %edi
	loop	5b

	/* Loop until we're done */
	pop	%edx
	test	%edx, %edx
	jnz	1b

	/* Wait a little before returning */
	mov	$SPLASH_DELAY_S, %ax
	mov	$SPLASH_DELAY_MS, %bx
	Call16	Delay

	PopSet	%eax, %ebx, %ecx, %edx, %ebp, %esi, %edi
	ret
#endif

/*** Debug Functions **********************************************************/

.arch i8086
.code16

/*
 * Prints a character either to DEBUG_PORT or via WriteTeletypeToActivePage.
 *
 * The destination is determined by bit 5 in BDA_VIDEO_FEATURE_BITS:
 *       0 - Output goes to DEBUG_PORT
 *       1 - Output goes to the display
 *
 * Arguments:
 *      AL - Character to print
 */
PrintCharacter:

	/* Test if the output redirect bit is set */
	testb	$0x20, BDA_VIDEO_FEATURE_BITS
	jz	0f

	/* Send output to the screen if it was */
	call	WriteTeletypeToActivePage
	jmp	1f

	/* Otherwise, simply use the debug port */
0:	push	%dx
	mov	$DEBUG_PORT, %dx
	outb	%al, %dx
	pop	%dx

1:	ret

/*
 * Prints a zero-terminated ASCII string.
 *
 * Arguments:
 *      AX - Text to print
 */
PrintString:
	PushSet	%ax, %si

	/* Load the arguments */
	mov	%ax, %si

	/* Loop over the string */
	cld
0:	lodsb	%cs:(%si)
	cmp	$0, %al
	je	1f
	call	PrintCharacter
	jmp	0b

1:	PopSet	%ax, %si
	ret

/*
 * Prints "\r\n"; this function makes it a one-liner.
 */
PrintEndOfLine:
	PushSet	%ax

	mov	$STR_EOL, %ax
	call	PrintString

	PopSet	%ax
	ret

/*
 * Prints the 8-bit AL register as a hexadecimal number.
 */
PrintAlRegister:
	PushSet	%ax, %bx, %cx

	/* Load the arguments */
	xor	%bx, %bx
	mov	%al, %bh

	/* Loop over two nybbles and output hexadecimal */
	mov	$2, %cx		# Rotate left four times

	jmp	0f

/*
 * Prints the 16-bit AX register as a hexadecimal number.
 */
PrintAxRegister:
	PushSet	%ax, %bx, %cx

	/* Load the arguments */
	mov	%ax, %bx

	/* Loop over four nybbles and output hexadecimal */

	mov	$4, %cx		# Rotate left four times

0:	push	%cx
	mov	$4, %cx
	rol	%cl, %bx
	pop	%cx

	mov	$0x0f, %al	# Extract the four low bits
	and	%bl, %al

#ifndef LONG_BUT_EASY_TO_UNDERSTAND
	cmp	$0x0a, %al	# Convert to an ASCII hex digit: 0x{100-69-X-Carry}
	sbb	$0x69, %al	# Yeah, it's magic, but uses 5 bytes instead of 12,
	das			# by skipping "non-decimal" numbers in a hex table
#else
	cmp	$0x0a, %al	# Convert to an ASCII hex digit
	jge	1f
	add	$'0', %al	# the long but slightly
	jmp	2f
1:	sub	$0x0a, %al	# more readable way
	add	$'A', %al
#endif
2:	call	PrintCharacter	# Output the byte
	loop	0b

	PopSet	%ax, %bx, %cx
	ret

/*
 * Prints some of the registers for easy debugging.
 */
PrintRegisters:
	PushSet	%ax

	/* Print the AX register */
	push	%ax
	mov	$STR_AX, %ax
	call	PrintString
	pop	%ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the BX register */
	mov	$STR_BX, %ax
	call	PrintString
	mov	%bx, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the CX register */
	mov	$STR_CX, %ax
	call	PrintString
	mov	%cx, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the DX register */
	mov	$STR_DX, %ax
	call	PrintString
	mov	%dx, %ax
	call	PrintAxRegister
	call	PrintEndOfLine

	/* Print the SP register */
	mov	$STR_SP, %ax
	call	PrintString
	mov	%sp, %ax
	add	$2, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the BP register */
	mov	$STR_BP, %ax
	call	PrintString
	mov	%bp, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the SI register */
	mov	$STR_SI, %ax
	call	PrintString
	mov	%si, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the DI register */
	mov	$STR_DI, %ax
	call	PrintString
	mov	%di, %ax
	call	PrintAxRegister
	call	PrintEndOfLine

	/* Print the CS register */
	mov	$STR_CS, %ax
	call	PrintString
	mov	%cs, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the DS register */
	mov	$STR_DS, %ax
	call	PrintString
	mov	%ds, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the SS register */
	mov	$STR_SS, %ax
	call	PrintString
	mov	%ss, %ax
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the ES register */
	mov	$STR_ES, %ax
	call	PrintString
	mov	%es, %ax
	call	PrintAxRegister
	call	PrintEndOfLine

	PopSet	%ax
	ret

/*
 * This just dumps a bunch of hexadecimal digits, but it may be useful.
 *
 * Arguments:
 *   ES:DI - Pointer to ModeInfoBlock struct
 */
PrintVbeModeInfo:
	PushSet	%ax, %cx, %si

	mov	$MIB_STRUCT_SIZE, %cx
	shl	$1, %cx

	mov	%di, %si
0:	es_lodsw
	test	$0x000f, %cx
	jnz	1f
	call	PrintEndOfLine
1:	xchg	%ah, %al
	call	PrintAxRegister
	loop	0b

	call	PrintEndOfLine

	PopSet	%ax, %cx, %si
	ret

/*
 * Prints something like "AX: 0xABCD; MyFunction\r\n" for the DHeader macro.
 *
 * This function wants an ASCII string two bytes after its return address.
 */
PrintDebugHeader:

	/* Function prologue */
	push	%bp
	mov	%sp, %bp
	PushSet	%ax

	/* Print the prefix */
	push	%ax
	mov	$STR_AX, %ax
	call	PrintString
	pop	%ax

	/* Print the register value */
	call	PrintAxRegister
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the message */
	push	%ax
	mov	2(%bp), %ax	# Grab the function return address
	add	$2, %ax		# Add 2 bytes for a short jmp
	call	PrintString	# Use this as the message
	pop	%ax

	/* Function epilogue */
	PopSet	%ax
	mov	%bp, %sp
	pop	%bp
	ret

/*
 * Print the Video Control Data Area from the BIOS Data Area
 */
PrintVideoControlDataArea:
	PushSet	%ax, %bx, %cx

	/* Print the Video Control Data Area 1 */
	mov	$STR_VCDA1, %ax
	call	PrintString

	PrintByte	BDA_DISPLAY_MODE
	PrintWord	BDA_NUMBER_OF_COLUMNS
	PrintWord	BDA_VIDEO_PAGE_SIZE
	PrintWord	BDA_VIDEO_PAGE_OFFSET
	PrintCursors	BDA_CURSOR_POSITIONS
	PrintWord	BDA_CURSOR_TYPE
	PrintByte	BDA_DISPLAY_PAGE
	PrintWord	BDA_CRTC_BASE
	PrintByte	BDA_3X8_SETTING
	PrintByte	BDA_3X9_SETTING

	/* Print the Video Control Data Area 2 */
	mov	$STR_VCDA2, %ax
	call	PrintString

	PrintByte	BDA_LAST_ROW_INDEX
	PrintWord	BDA_CHARACTER_HEIGHT
	PrintByte	BDA_VIDEO_MODE_OPTIONS
	PrintByte	BDA_VIDEO_FEATURE_BITS
	PrintByte	BDA_VIDEO_DISPLAY_DATA
	PrintByte	BDA_DCC_TABLE_INDEX

	PopSet	%ax, %bx, %cx
	ret

/*
 * Prints something like "Function: AX: 0xABCD; Not implemented!\r\n" and stops.
 *
 * This will force us to decide if the missing BIOS function needs a real
 * implementation or if an empty dummy function is good enough.
 */
NotImplemented:
	/* Print the prefix */
	push	%ax
	mov	$STR_AX, %ax
	call	PrintString
	pop	%ax

	/* Print the register value */
	call	PrintAxRegister
	push	%ax
	mov	$STR_SEMICOLON, %ax
	call	PrintString

	/* Print the message */
	mov	$STR_NOT_IMPLEMENTED, %ax
	call	PrintString
	pop	%ax

	/* This is often useful as well */
	call	PrintRegisters
	call	PrintVideoControlDataArea

	/* The user is more likely to see this */
	call	ShowBlueScreenOfDeath

	/* Wait forever */
0:	jmp 0b

/*
 * Displays a blue screen full of scary info.
 */
ShowBlueScreenOfDeath:

	/* Set VGA mode 3 (80x25 text mode) */
	push	%ax
	mov	$0x0003, %ax
	call	SetVideoMode
	pop	%ax

	/* Make the background blue */
	PushSet	%ax, %bx, %cx, %dx
	xor	%al, %al	# Blank the entire window
	mov	$0x17, %bh	# Attribute: white on blue
	xor	%cx, %cx	# Upper left corner of scroll
	mov	$0xffff, %dx	# Lower right corner of scroll
	call	ScrollActivePageUp
	PopSet	%ax, %bx, %cx, %dx

	/* Write the BSOD header */
	push	%ax
	orb	$0x20, BDA_VIDEO_FEATURE_BITS
	mov	$STR_BSOD_HEADER, %ax
	call	PrintString
	pop	%ax

	/* Print the important stuff */
	call	PrintRegisters

	/* Explain the problem */
	push	%ax
	mov	$STR_BSOD_MESSAGE, %ax
	call	PrintString
	pop	%ax

	ret

/*** Video Modes ***************************************************************

--------------------------------------------------------------------------------
From https://web.archive.org/web/20150102175843/http://javiervalcarce.eu/wiki/
     VGA_Video_Signal_Format_and_Timing_Specifications
--------------------------------------------------------------------------------

Horizontal                              Vertical
                +-------+                               +-------+
Video           |<--D-->|               Video           |<--R-->|
----------------+       +------------   ----------------+       +------------
        |<--C-->|       |<--E-->|               |<--Q-->|       |<--S-->|
------+ +-----------------------+ +--   ------+ +-----------------------+ +--
Sync  |B|                       |B|     Sync  |P|                       |P|
      +-+                       +-+           +-+                       +-+
      |<-----------A----------->|             |<-----------O----------->|

--------------------------------------------------------------------------------
		IBM	IBM	   VESA		   VESA		    VESA
		640x480	720x400	  640x480	  800x600	  1024x768
Measure	Unit	60Hz	70Hz	75Hz	85Hz	75Hz	85Hz	75Hz	85Hz
--------------------------------------------------------------------------------
F_HSYNC	kHz	31.469	31.469	37.500	43.269	46.875	53.674	60.023	68.677
A	us	31.778	31.777	26.667	23.111	21.333	18.631	16.660	14.561
B	us	 3.813	 3.813	 2.032	 1.556	 1.616	 1.138	 1.219	 1.016
C	us	 1.907	 1.907	 3.810	 2.222	 3.232	 2.702	 2.235	 2.201
D	us	25.422	25.422	20.317	17.778	16.162	14.222	13.003	10.836
E	us	 0.636	 0.636	 0.508	 1.558	 0.323	 0.569*	 0.203	 0.508
F_VSYNC	Hz	59.940	70.087	75.000	85.008	75.000	85.061	75.029	84.997
O	ms	16.683	14.268	13.333	11.764	13.333	11.758	13.328	11.765
P	ms	 0.064	 0.064	 0.080	 0.067*	 0.064	 0.056	 0.050	 0.044
Q	ms	 1.048	 1.080	 0.427	 0.578	 0.448	 0.503	 0.466	 0.524
R	ms	15.253	12.711	12.800	11.093	12.800	11.179	12.795	11.183
S	ms	 0.318	 0.413	 0.027	 0.023	 0.021	 0.019	 0.017	 0.015
CLOCK	Mhz	25.175	28.322	31.500	36.000	49.500	56.250	78.750	94.500
--------------------------------------------------------------------------------
HSYNC Polarity	   Neg	   Neg	   Neg	   Neg	   Pos	   Pos	   Pos	   Pos
VSYNC Polarity	   Neg	   Pos	   Neg	   Neg	   Pos	   Pos	   Pos	   Pos
--------------------------------------------------------------------------------
A	px	   800	   900	   840	   832	  1056	  1048	  1312	  1376
B	px	    96	   108	    64	    56	    80	    64	    96	    96
C	px	    48	    54	   120	    80	   160	   152	   176	   208
D	px	   640	   720	   640	   640	   800	   800	  1024	  1024
E	px	    16	    18	    16	    56	    16	    32	    16	    48
O	px	   525	   449	   500	   509	   625	   631	   800	   808
P	px	     2	     2	     3	     3	     3	     3	     3	     3
Q	px	    33	    34	    16	    25	    21	    27	    28	    36
R	px	   480	   400	   480	   480	   600	   600	   768	   768
S	px	    10	    13	     1	     1	     1	     1	     1	     1
--------------------------------------------------------------------------------
* = Incorrect in the original table

*******************************************************************************/

/*
 * Defines values for the CRT Controller registers.
 *
 * The border between displayed and blanked areas is zero pixels wide.
 *
 * Horizontal sync args:
 *   D - Number of displayed chars in a row
 *   E - Number of blanking chars before HSYNC
 *   B - Number of chars in HSYNC signal
 *   C - Number of blanking chars after HSYNC
 *
 * Vertical sync args:
 *   R - Number of displayed lines on the screen
 *   S - Number of blanking lines before VSYNC
 *   P - Number of lines in VSYNC signal
 *   Q - Number of blanking lines after VSYNC
 *
 * Character args:
 *   W - Width of each character in pixels
 *   H - Height of each character in pixels
 *
 * Other args:
 *   Mode - Value of the CRT Mode Control register
 *   Text - 0 for graphics modes; 1 for text modes
 */
.macro CRTC_Regs D, E, B, C, R, S, P, Q, W, H, Mode, Text

/* Overflow bits from various registers */
.set	EB5,	(0x20 & (\B + \C + \D + \E)) << 2
.set	VT8,	(0x100 & (\P + \Q + \R + \S - 2)) >> 8
.set	VT9,	(0x200 & (\P + \Q + \R + \S - 2)) >> 4
.set	VRS8,	(0x100 & (\R + \S)) >> 6
.set	VRS9,	(0x200 & (\R + \S)) >> 2
.set	VDE8,	(0x100 & (\R - 1)) >> 7
.set	VDE9,	(0x200 & (\R - 1)) >> 3
.set	VBS8,	(0x100 & \R) >> 5
.set	VBS9,	(0x200 & \R) >> 4
.set	LC8,	(0x100) >> 4
.set	LC9,	(0x200) >> 3

/* One byte for each CRT Controller register */
.byte	\B + \C + \D + \E - 5			# Horizontal Total
.byte	\D - 1					# Horizontal Display-Enable End
.byte	\D					# Start Horizontal Blanking
.byte	0x80 | (0x1f & (\B + \C + \D + \E))	# End Horizontal Blanking
.byte	\D + \E					# Start Horizontal Retrace
.byte	EB5 | (0x1f & (\B + \D + \E))		# End Horizontal Retrace
.byte	0xff & (\P + \Q + \R + \S - 2)		# Vertical Total
.byte	VRS9|VDE9|VT9|LC8|VBS8|VRS8|VDE8|VT8	# Overflow
.byte	0x00					# Preset Row Scan
.byte	LC9 | VBS9 | (0x1f & (\H - 1))		# Maximum Scan Line
.if	\Text
.byte	0x00					# Cursor Start (cursor enabled)
.else
.byte	0x20					# Cursor Start (cursor disabled)
.endif
.byte	0x1f & (\H - 1)				# Cursor End
.byte	0x00					# Start Address High
.byte	0x00					# Start Address Low
.byte	0x00					# Cursor Location High
.byte	0x00					# Cursor Location Low
.byte	0xff & (\R + \S)			# Vertical Retrace Start
.byte	0x0f & (\P + \R + \S)			# Vertical Retrace End
.byte	0xff & (\R - 1)				# Vertical Display-Enable End
.byte	\D >> 1					# Offset
.byte	0x1f					# Underline Location
.byte	0xff & \R				# Start Vertical Blanking
.byte	0xff & (\P + \Q + \R + \S - 1)		# End Vertical Blanking
.byte	\Mode					# CRT Mode Control
.byte	0xff					# Line Compare

.endm

/******************************************************************************
 * The following 64-byte video-mode structs follow the original format for    *
 * elements in the Video Parameter Table, as documented by Ralf Brown in      *
 * inter61c/MEMORY.LST of RBIL Release 61.                                    *
 *                                                                            *
 * Format of Video Parameter Table element [EGA, VGA only]:                   *
 *   00h    BYTE    Columns on screen                                         *
 *   01h    BYTE    Rows on screen minus one                                  *
 *   02h    BYTE    Height of character in scan lines                         *
 *   03h    WORD    Size of video buffer                                      *
 *   05h  4 BYTEs   Values for Sequencer Registers 1-4                        *
 *   09h    BYTE    Value for Miscellaneous Output Register                   *
 *   0Ah 25 BYTEs   Values for CRTC Registers 00h-18h                         *
 *   23h 20 BYTEs   Values for Attribute Controller Registers 00h-13h         *
 *   37h  9 BYTEs   Values for Graphics Controller Registers 00h-08h          *
 *                                                                            *
 ******************************************************************************/

/*** VGA Mode 0x03: 80x25 chars in 720x400 pixels *****************************/

.macro VGA_Mode_0x03

.byte	80	# Number of columns
.byte	24	# Last row index
.byte	16	# Character height
.word	0x1000	# Page size

/* Sequencer Registers 1-4 */
.byte	0x22	# Clocking Mode: 9 pixels/char
.byte	0x03	# Map Mask: access maps 0 and 1
.byte	0x00	# Character Map Select: not used
.byte	0x02	# Memory Mode: 256 KiB; interlace bytes from maps 0 and 1

/* Miscellaneous Output Register */
.byte	0x47	# Positive VSYNC, Negative HSYNC, 28.322 MHz, Enable RAM

/*
 * Horizontal: 100 chars total; 80 visible, 2 blank, 12 sync, 6 blank
 * Vertical: 449 lines total; 400 visible, 13 blank, 2 sync, 34 blank
 * Character Width: 9 pixels; Character Height: 16 pixels
 * CRT Mode Control: 0xa3 - enabled, word mode
 */
CRTC_Regs 80, 2, 12, 6, 400, 13, 2, 34, 9, 16, 0xa3, 1

/* Palette Registers */
.byte	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
.byte	0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f

/* Other Attribute Controller Registers */
.byte	0x0c	# Attribute Mode Control: Blink, Line Graphics, Color, Text
.byte	0x00	# Overscan Color: Black border
.byte	0x0f	# Color Plane Enable: Enable all four planes
.byte	0x08	# Horizontal Pixel Panning: No panning

/* Graphics Controller Registers */
.byte	0x00	# Set/Reset: Not used
.byte	0x00	# Enable Set/Reset: Disabled
.byte	0x00	# Color Compare: Not used
.byte	0x00	# Data Rotate; No function, no rotation
.byte	0x00	# Read Map Select: Maps 0 and 1
.byte	0x10	# Graphics Mode: Odd/Even addressing
.byte	0x0e	# Miscellaneous: 32 KiB at B8000, Odd/Even, Text
.byte	0x0f	# Color Don't Care: Use all maps
.byte	0xff	# Bit Mask: Allow all bits to change

.endm

/*** VGA Mode 0x12: 640x480 pixels with 4-bit color ***************************/

.macro VGA_Mode_0x12

.byte	80	# Number of columns
.byte	29	# Last row index
.byte	16	# Character height
.word	0x0000	# Page size

/* Sequencer Registers 1-4 */
.byte	0x23	# Clocking Mode: 8 pixels/char
.byte	0x0f	# Map Mask: access all maps
.byte	0x00	# Character Map Select: not used
.byte	0x06	# Memory Mode: 256 KiB; sequential bytes in a bitmap

/* Miscellaneous Output Register */
.byte	0xc3	# Negative VSYNC, Negative HSYNC, 25.175 MHz, Enable RAM

/*
 * Horizontal: 100 chars total; 80 visible, 2 blank, 12 sync, 6 blank
 * Vertical: 449 lines total; 480 visible, 10 blank, 2 sync, 33 blank
 * Character Width: 8 pixels; Character Height: 16 pixels
 * CRT Mode Control: 0xe3 - enabled, byte mode
 */
CRTC_Regs 80, 2, 12, 6, 480, 10, 2, 33, 8, 16, 0xe3, 0

/* Palette Registers */
.byte	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
.byte	0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f

/* Other Attribute Controller Registers */
.byte	0x01	# Attribute Mode Control: Color, Graphics
.byte	0x00	# Overscan Color: Black border
.byte	0x0f	# Color Plane Enable: Enable all four planes
.byte	0x00	# Horizontal Pixel Panning: No panning

/* Graphics Controller Registers */
.byte	0x00	# Set/Reset: Not used
.byte	0x00	# Enable Set/Reset: Disabled
.byte	0x00	# Color Compare: Not used
.byte	0x00	# Data Rotate; No function, no rotation
.byte	0x00	# Read Map Select: Maps 0 and 1
.byte	0x00	# Graphics Mode: Nothing special
.byte	0x05	# Miscellaneous: 64 KiB at A0000, Graphics
.byte	0x0f	# Color Don't Care: Use all maps
.byte	0xff	# Bit Mask: Allow all bits to change

.endm

/******************************************************************************/

SavePointerTable1:
.long	VideoParameterTable
.zero	12
.long	SavePointerTable2
.zero	8

SavePointerTable2:
.word	26	/* Table length in bytes */
.long	DisplayCombinationCodeTable
.zero	20

DisplayCombinationCodeTable:
.byte	0x01	/* Number of entries in table */
.byte	0x00	/* DCC Table Version Number */
.byte	0x08	/* Maximum Display Type Code */
.byte	0x00	/* Reserved */
.long	0x0008	/* One display with color VGA */

StaticFunctionalityTable:
.byte	0x08	# VGA Mode 0x03
.byte	0x00	# Unsupported
.byte	0x04	# VGA Mode 0x12
.zero	4	# Reserved
.byte	0x04	# 400 scan lines
.byte	8	# 8 character blocks
.byte	1	# Max one active block
.byte	0x7d	# Various supported functions
.byte	0x06	# DCC, Save/Restore
.zero	2	# Reserved
.byte	0x00	# No save pointer functions
.zero	1	# Reserved

/*
 * This may be overly conservative, but for utmost compatibility with any old
 * DOS programs, and as documentation of modes we have still not implemented,
 * the following table follows the original, as documented by Ralf Brown in
 * inter61c/MEMORY.LST of RBIL Release 61.
 */
VideoParameterTable:
.zero	256	# 0x00-0x03: Modes 0x00-0x03 in 200-line CGA emulation mode
.zero	704	# 0x04-0x0E: Modes 0x04-0x0E
.zero	128	# 0x0F-0x10: Modes 0x0F-0x10 for <= 64 KiB RAM
.zero	128	# 0x11-0x12: Modes 0x0F-0x10 for > 64 KiB RAM
.zero	256	# 0x13-0x16: Modes 0x00-0x03 in 350-line mode
.zero	 64	# 0x17:      VGA Mode 0x00 or 0x01 in 400-line mode
VGA_Mode_0x03	# 0x18:      VGA Mode 0x02 or 0x03 in 400-line mode
.zero	 64	# 0x19:      VGA Mode 0x07 in 400-line mode
.zero	 64	# 0x1A:      VGA Mode 0x11
VGA_Mode_0x12	# 0x1B:      VGA Mode 0x12
.zero	 64	# 0x1C:      VGA Mode 0x13

/*** Palettes *****************************************************************/

EgaPalette: # 64 colors, 6 bits: R-low, G-low, B-low, R-high, G-high, B-high
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x00, 0x00, 0x2a, 0x2a
.byte	0x2a, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x2a, 0x2a, 0x00, 0x2a, 0x2a, 0x2a
.byte	0x00, 0x00, 0x15, 0x00, 0x00, 0x3f, 0x00, 0x2a, 0x15, 0x00, 0x2a, 0x3f
.byte	0x2a, 0x00, 0x15, 0x2a, 0x00, 0x3f, 0x2a, 0x2a, 0x15, 0x2a, 0x2a, 0x3f
.byte	0x00, 0x15, 0x00, 0x00, 0x15, 0x2a, 0x00, 0x3f, 0x00, 0x00, 0x3f, 0x2a
.byte	0x2a, 0x15, 0x00, 0x2a, 0x15, 0x2a, 0x2a, 0x3f, 0x00, 0x2a, 0x3f, 0x2a
.byte	0x00, 0x15, 0x15, 0x00, 0x15, 0x3f, 0x00, 0x3f, 0x15, 0x00, 0x3f, 0x3f
.byte	0x2a, 0x15, 0x15, 0x2a, 0x15, 0x3f, 0x2a, 0x3f, 0x15, 0x2a, 0x3f, 0x3f
.byte	0x15, 0x00, 0x00, 0x15, 0x00, 0x2a, 0x15, 0x2a, 0x00, 0x15, 0x2a, 0x2a
.byte	0x3f, 0x00, 0x00, 0x3f, 0x00, 0x2a, 0x3f, 0x2a, 0x00, 0x3f, 0x2a, 0x2a
.byte	0x15, 0x00, 0x15, 0x15, 0x00, 0x3f, 0x15, 0x2a, 0x15, 0x15, 0x2a, 0x3f
.byte	0x3f, 0x00, 0x15, 0x3f, 0x00, 0x3f, 0x3f, 0x2a, 0x15, 0x3f, 0x2a, 0x3f
.byte	0x15, 0x15, 0x00, 0x15, 0x15, 0x2a, 0x15, 0x3f, 0x00, 0x15, 0x3f, 0x2a
.byte	0x3f, 0x15, 0x00, 0x3f, 0x15, 0x2a, 0x3f, 0x3f, 0x00, 0x3f, 0x3f, 0x2a
.byte	0x15, 0x15, 0x15, 0x15, 0x15, 0x3f, 0x15, 0x3f, 0x15, 0x15, 0x3f, 0x3f
.byte	0x3f, 0x15, 0x15, 0x3f, 0x15, 0x3f, 0x3f, 0x3f, 0x15, 0x3f, 0x3f, 0x3f

VgaPalette: # 256 colors used as the default palette for VGA mode 0x13
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x00, 0x00, 0x2a, 0x2a
.byte	0x2a, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x2a, 0x15, 0x00, 0x2a, 0x2a, 0x2a
.byte	0x15, 0x15, 0x15, 0x15, 0x15, 0x3f, 0x15, 0x3f, 0x15, 0x15, 0x3f, 0x3f
.byte	0x3f, 0x15, 0x15, 0x3f, 0x15, 0x3f, 0x3f, 0x3f, 0x15, 0x3f, 0x3f, 0x3f
.byte	0x00, 0x00, 0x00, 0x04, 0x04, 0x04, 0x08, 0x08, 0x08, 0x0d, 0x0d, 0x0d
.byte	0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x19, 0x19, 0x19, 0x1d, 0x1d, 0x1d
.byte	0x22, 0x22, 0x22, 0x26, 0x26, 0x26, 0x2a, 0x2a, 0x2a, 0x2e, 0x2e, 0x2e
.byte	0x32, 0x32, 0x32, 0x37, 0x37, 0x37, 0x3b, 0x3b, 0x3b, 0x3f, 0x3f, 0x3f
.byte	0x00, 0x00, 0x3f, 0x10, 0x00, 0x3f, 0x20, 0x00, 0x3f, 0x2f, 0x00, 0x3f
.byte	0x3f, 0x00, 0x3f, 0x3f, 0x00, 0x2f, 0x3f, 0x00, 0x20, 0x3f, 0x00, 0x10
.byte	0x3f, 0x00, 0x00, 0x3f, 0x10, 0x00, 0x3f, 0x20, 0x00, 0x3f, 0x2f, 0x00
.byte	0x3f, 0x3f, 0x00, 0x2f, 0x3f, 0x00, 0x20, 0x3f, 0x00, 0x10, 0x3f, 0x00
.byte	0x00, 0x3f, 0x00, 0x00, 0x3f, 0x10, 0x00, 0x3f, 0x20, 0x00, 0x3f, 0x2f
.byte	0x00, 0x3f, 0x3f, 0x00, 0x2f, 0x3f, 0x00, 0x20, 0x3f, 0x00, 0x10, 0x3f
.byte	0x20, 0x20, 0x3f, 0x27, 0x20, 0x3f, 0x2f, 0x20, 0x3f, 0x37, 0x20, 0x3f
.byte	0x3f, 0x20, 0x3f, 0x3f, 0x20, 0x37, 0x3f, 0x20, 0x2f, 0x3f, 0x20, 0x27
.byte	0x3f, 0x20, 0x20, 0x3f, 0x27, 0x20, 0x3f, 0x2f, 0x20, 0x3f, 0x37, 0x20
.byte	0x3f, 0x3f, 0x20, 0x37, 0x3f, 0x20, 0x2f, 0x3f, 0x20, 0x27, 0x3f, 0x20
.byte	0x20, 0x3f, 0x20, 0x20, 0x3f, 0x27, 0x20, 0x3f, 0x2f, 0x20, 0x3f, 0x37
.byte	0x20, 0x3f, 0x3f, 0x20, 0x37, 0x3f, 0x20, 0x2f, 0x3f, 0x20, 0x27, 0x3f
.byte	0x2e, 0x2e, 0x3f, 0x32, 0x2e, 0x3f, 0x37, 0x2e, 0x3f, 0x3b, 0x2e, 0x3f
.byte	0x3f, 0x2e, 0x3f, 0x3f, 0x2e, 0x3b, 0x3f, 0x2e, 0x37, 0x3f, 0x2e, 0x32
.byte	0x3f, 0x2e, 0x2e, 0x3f, 0x32, 0x2e, 0x3f, 0x37, 0x2e, 0x3f, 0x3b, 0x2e
.byte	0x3f, 0x3f, 0x2e, 0x3b, 0x3f, 0x2e, 0x37, 0x3f, 0x2e, 0x32, 0x3f, 0x2e
.byte	0x2e, 0x3f, 0x2e, 0x2e, 0x3f, 0x32, 0x2e, 0x3f, 0x37, 0x2e, 0x3f, 0x3b
.byte	0x2e, 0x3f, 0x3f, 0x2e, 0x3b, 0x3f, 0x2e, 0x37, 0x3f, 0x2e, 0x32, 0x3f
.byte	0x00, 0x00, 0x1c, 0x07, 0x00, 0x1c, 0x0e, 0x00, 0x1c, 0x15, 0x00, 0x1c
.byte	0x1c, 0x00, 0x1c, 0x1c, 0x00, 0x15, 0x1c, 0x00, 0x0e, 0x1c, 0x00, 0x07
.byte	0x1c, 0x00, 0x00, 0x1c, 0x07, 0x00, 0x1c, 0x0e, 0x00, 0x1c, 0x15, 0x00
.byte	0x1c, 0x1c, 0x00, 0x15, 0x1c, 0x00, 0x0e, 0x1c, 0x00, 0x07, 0x1c, 0x00
.byte	0x00, 0x1c, 0x00, 0x00, 0x1c, 0x07, 0x00, 0x1c, 0x0e, 0x00, 0x1c, 0x15
.byte	0x00, 0x1c, 0x1c, 0x00, 0x15, 0x1c, 0x00, 0x0e, 0x1c, 0x00, 0x07, 0x1c
.byte	0x0e, 0x0e, 0x1c, 0x11, 0x0e, 0x1c, 0x15, 0x0e, 0x1c, 0x18, 0x0e, 0x1c
.byte	0x1c, 0x0e, 0x1c, 0x1c, 0x0e, 0x18, 0x1c, 0x0e, 0x15, 0x1c, 0x0e, 0x11
.byte	0x1c, 0x0e, 0x0e, 0x1c, 0x11, 0x0e, 0x1c, 0x15, 0x0e, 0x1c, 0x18, 0x0e
.byte	0x1c, 0x1c, 0x0e, 0x18, 0x1c, 0x0e, 0x15, 0x1c, 0x0e, 0x11, 0x1c, 0x0e
.byte	0x0e, 0x1c, 0x0e, 0x0e, 0x1c, 0x11, 0x0e, 0x1c, 0x15, 0x0e, 0x1c, 0x18
.byte	0x0e, 0x1c, 0x1c, 0x0e, 0x18, 0x1c, 0x0e, 0x15, 0x1c, 0x0e, 0x11, 0x1c
.byte	0x14, 0x14, 0x1c, 0x16, 0x14, 0x1c, 0x18, 0x14, 0x1c, 0x1a, 0x14, 0x1c
.byte	0x1c, 0x14, 0x1c, 0x1c, 0x14, 0x1a, 0x1c, 0x14, 0x18, 0x1c, 0x14, 0x16
.byte	0x1c, 0x14, 0x14, 0x1c, 0x16, 0x14, 0x1c, 0x18, 0x14, 0x1c, 0x1a, 0x14
.byte	0x1c, 0x1c, 0x14, 0x1a, 0x1c, 0x14, 0x18, 0x1c, 0x14, 0x16, 0x1c, 0x14
.byte	0x14, 0x1c, 0x14, 0x14, 0x1c, 0x16, 0x14, 0x1c, 0x18, 0x14, 0x1c, 0x1a
.byte	0x14, 0x1c, 0x1c, 0x14, 0x1a, 0x1c, 0x14, 0x18, 0x1c, 0x14, 0x16, 0x1c
.byte	0x00, 0x00, 0x10, 0x04, 0x00, 0x10, 0x08, 0x00, 0x10, 0x0c, 0x00, 0x10
.byte	0x10, 0x00, 0x10, 0x10, 0x00, 0x0c, 0x10, 0x00, 0x08, 0x10, 0x00, 0x04
.byte	0x10, 0x00, 0x00, 0x10, 0x04, 0x00, 0x10, 0x08, 0x00, 0x10, 0x0c, 0x00
.byte	0x10, 0x10, 0x00, 0x0c, 0x10, 0x00, 0x08, 0x10, 0x00, 0x04, 0x10, 0x00
.byte	0x00, 0x10, 0x00, 0x00, 0x10, 0x04, 0x00, 0x10, 0x08, 0x00, 0x10, 0x0c
.byte	0x00, 0x10, 0x10, 0x00, 0x0c, 0x10, 0x00, 0x08, 0x10, 0x00, 0x04, 0x10
.byte	0x08, 0x08, 0x10, 0x0a, 0x08, 0x10, 0x0c, 0x08, 0x10, 0x0e, 0x08, 0x10
.byte	0x10, 0x08, 0x10, 0x10, 0x08, 0x0e, 0x10, 0x08, 0x0c, 0x10, 0x08, 0x0a
.byte	0x10, 0x08, 0x08, 0x10, 0x0a, 0x08, 0x10, 0x0c, 0x08, 0x10, 0x0e, 0x08
.byte	0x10, 0x10, 0x08, 0x0e, 0x10, 0x08, 0x0c, 0x10, 0x08, 0x0a, 0x10, 0x08
.byte	0x08, 0x10, 0x08, 0x08, 0x10, 0x0a, 0x08, 0x10, 0x0c, 0x08, 0x10, 0x0e
.byte	0x08, 0x10, 0x10, 0x08, 0x0e, 0x10, 0x08, 0x0c, 0x10, 0x08, 0x0a, 0x10
.byte	0x0b, 0x0b, 0x10, 0x0c, 0x0b, 0x10, 0x0d, 0x0b, 0x10, 0x0f, 0x0b, 0x10
.byte	0x10, 0x0b, 0x10, 0x10, 0x0b, 0x0f, 0x10, 0x0b, 0x0d, 0x10, 0x0b, 0x0c
.byte	0x10, 0x0b, 0x0b, 0x10, 0x0c, 0x0b, 0x10, 0x0d, 0x0b, 0x10, 0x0f, 0x0b
.byte	0x10, 0x10, 0x0b, 0x0f, 0x10, 0x0b, 0x0d, 0x10, 0x0b, 0x0c, 0x10, 0x0b
.byte	0x0b, 0x10, 0x0b, 0x0b, 0x10, 0x0c, 0x0b, 0x10, 0x0d, 0x0b, 0x10, 0x0f
.byte	0x0b, 0x10, 0x10, 0x0b, 0x0f, 0x10, 0x0b, 0x0d, 0x10, 0x0b, 0x0c, 0x10
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

/*** Fonts ********************************************************************/

/*
 * Generated from the standard VGA font in FreeBSD syscons:
 *
 *   uudecode -o /dev/stdout /usr/share/syscons/fonts/cp437-8x16.fnt | \
 *   hexdump -ve '".byte\t" 11/1 "0x%02x, " 1/1 " 0x%02x\n"'
 */
Font_8x16:
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x81, 0xa5, 0x81, 0x81, 0xbd
.byte	0x99, 0x81, 0x81, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0xff
.byte	0xdb, 0xff, 0xff, 0xc3, 0xe7, 0xff, 0xff, 0x7e, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x6c, 0xfe, 0xfe, 0xfe, 0xfe, 0x7c, 0x38, 0x10
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x7c, 0xfe
.byte	0x7c, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18
.byte	0x3c, 0x3c, 0xe7, 0xe7, 0xe7, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x18, 0x3c, 0x7e, 0xff, 0xff, 0x7e, 0x18, 0x18, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x3c
.byte	0x3c, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff
.byte	0xff, 0xff, 0xe7, 0xc3, 0xc3, 0xe7, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x66, 0x42, 0x42, 0x66, 0x3c, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xc3, 0x99, 0xbd
.byte	0xbd, 0x99, 0xc3, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x1e, 0x0e
.byte	0x1a, 0x32, 0x78, 0xcc, 0xcc, 0xcc, 0xcc, 0x78, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x3c, 0x66, 0x66, 0x66, 0x66, 0x3c, 0x18, 0x7e, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x33, 0x3f, 0x30, 0x30, 0x30
.byte	0x30, 0x70, 0xf0, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7f, 0x63
.byte	0x7f, 0x63, 0x63, 0x63, 0x63, 0x67, 0xe7, 0xe6, 0xc0, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x18, 0x18, 0xdb, 0x3c, 0xe7, 0x3c, 0xdb, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xc0, 0xe0, 0xf0, 0xf8, 0xfe, 0xf8
.byte	0xf0, 0xe0, 0xc0, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x06, 0x0e
.byte	0x1e, 0x3e, 0xfe, 0x3e, 0x1e, 0x0e, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x18, 0x3c, 0x7e, 0x18, 0x18, 0x18, 0x7e, 0x3c, 0x18, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
.byte	0x66, 0x00, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7f, 0xdb
.byte	0xdb, 0xdb, 0x7b, 0x1b, 0x1b, 0x1b, 0x1b, 0x1b, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x7c, 0xc6, 0x60, 0x38, 0x6c, 0xc6, 0xc6, 0x6c, 0x38, 0x0c, 0xc6
.byte	0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0xfe, 0xfe, 0xfe, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x3c
.byte	0x7e, 0x18, 0x18, 0x18, 0x7e, 0x3c, 0x18, 0x7e, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x18, 0x3c, 0x7e, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x7e, 0x3c, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x18, 0x0c, 0xfe, 0x0c, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x60, 0xfe, 0x60, 0x30, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0xc0
.byte	0xc0, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x28, 0x6c, 0xfe, 0x6c, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x38, 0x7c, 0x7c, 0xfe, 0xfe, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xfe, 0x7c, 0x7c
.byte	0x38, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x18, 0x3c, 0x3c, 0x3c, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x66, 0x66, 0x24, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6c
.byte	0x6c, 0xfe, 0x6c, 0x6c, 0x6c, 0xfe, 0x6c, 0x6c, 0x00, 0x00, 0x00, 0x00
.byte	0x18, 0x18, 0x7c, 0xc6, 0xc2, 0xc0, 0x7c, 0x06, 0x06, 0x86, 0xc6, 0x7c
.byte	0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc2, 0xc6, 0x0c, 0x18
.byte	0x30, 0x60, 0xc6, 0x86, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6c
.byte	0x6c, 0x38, 0x76, 0xdc, 0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x30, 0x30, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x18, 0x30, 0x30, 0x30, 0x30
.byte	0x30, 0x30, 0x18, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x18
.byte	0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x3c, 0xff, 0x3c, 0x66, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x7e
.byte	0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x02, 0x06, 0x0c, 0x18, 0x30, 0x60, 0xc0, 0x80, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x38, 0x6c, 0xc6, 0xc6, 0xd6, 0xd6, 0xc6, 0xc6, 0x6c, 0x38
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x38, 0x78, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6
.byte	0x06, 0x0c, 0x18, 0x30, 0x60, 0xc0, 0xc6, 0xfe, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x7c, 0xc6, 0x06, 0x06, 0x3c, 0x06, 0x06, 0x06, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x1c, 0x3c, 0x6c, 0xcc, 0xfe
.byte	0x0c, 0x0c, 0x0c, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xc0
.byte	0xc0, 0xc0, 0xfc, 0x06, 0x06, 0x06, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x38, 0x60, 0xc0, 0xc0, 0xfc, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xc6, 0x06, 0x06, 0x0c, 0x18
.byte	0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6
.byte	0xc6, 0xc6, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0x7e, 0x06, 0x06, 0x06, 0x0c, 0x78
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00
.byte	0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x06, 0x0c, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0c, 0x06
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x00, 0x00
.byte	0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60
.byte	0x30, 0x18, 0x0c, 0x06, 0x0c, 0x18, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x7c, 0xc6, 0xc6, 0x0c, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6, 0xc6, 0xde, 0xde
.byte	0xde, 0xdc, 0xc0, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x38
.byte	0x6c, 0xc6, 0xc6, 0xfe, 0xc6, 0xc6, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xfc, 0x66, 0x66, 0x66, 0x7c, 0x66, 0x66, 0x66, 0x66, 0xfc
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x66, 0xc2, 0xc0, 0xc0, 0xc0
.byte	0xc0, 0xc2, 0x66, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x6c
.byte	0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6c, 0xf8, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xfe, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x62, 0x66, 0xfe
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x66, 0x62, 0x68, 0x78, 0x68
.byte	0x60, 0x60, 0x60, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x66
.byte	0xc2, 0xc0, 0xc0, 0xde, 0xc6, 0xc6, 0x66, 0x3a, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xc6, 0xc6, 0xc6, 0xc6, 0xfe, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1e, 0x0c
.byte	0x0c, 0x0c, 0x0c, 0x0c, 0xcc, 0xcc, 0xcc, 0x78, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xe6, 0x66, 0x66, 0x6c, 0x78, 0x78, 0x6c, 0x66, 0x66, 0xe6
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x60, 0x60, 0x60, 0x60, 0x60
.byte	0x60, 0x62, 0x66, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0xee
.byte	0xfe, 0xfe, 0xd6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xc6, 0xe6, 0xf6, 0xfe, 0xde, 0xce, 0xc6, 0xc6, 0xc6, 0xc6
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfc, 0x66
.byte	0x66, 0x66, 0x7c, 0x60, 0x60, 0x60, 0x60, 0xf0, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xd6, 0xde, 0x7c
.byte	0x0c, 0x0e, 0x00, 0x00, 0x00, 0x00, 0xfc, 0x66, 0x66, 0x66, 0x7c, 0x6c
.byte	0x66, 0x66, 0x66, 0xe6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6
.byte	0xc6, 0x60, 0x38, 0x0c, 0x06, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x7e, 0x7e, 0x5a, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x6c, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xc6, 0xc6, 0xc6, 0xc6, 0xd6, 0xd6, 0xd6, 0xfe, 0xee, 0x6c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0xc6, 0x6c, 0x7c, 0x38, 0x38
.byte	0x7c, 0x6c, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x66
.byte	0x66, 0x66, 0x3c, 0x18, 0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xfe, 0xc6, 0x86, 0x0c, 0x18, 0x30, 0x60, 0xc2, 0xc6, 0xfe
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x30, 0x30, 0x30, 0x30, 0x30
.byte	0x30, 0x30, 0x30, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80
.byte	0xc0, 0xe0, 0x70, 0x38, 0x1c, 0x0e, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x3c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x6c, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00
.byte	0x30, 0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x0c, 0x7c
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0x60
.byte	0x60, 0x78, 0x6c, 0x66, 0x66, 0x66, 0x66, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6, 0xc0, 0xc0, 0xc0, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0x0c, 0x0c, 0x3c, 0x6c, 0xcc
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x7c, 0xc6, 0xfe, 0xc0, 0xc0, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x38, 0x6c, 0x64, 0x60, 0xf0, 0x60, 0x60, 0x60, 0x60, 0xf0
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xcc, 0xcc
.byte	0xcc, 0xcc, 0xcc, 0x7c, 0x0c, 0xcc, 0x78, 0x00, 0x00, 0x00, 0xe0, 0x60
.byte	0x60, 0x6c, 0x76, 0x66, 0x66, 0x66, 0x66, 0xe6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x18, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x06, 0x00, 0x0e, 0x06, 0x06
.byte	0x06, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3c, 0x00, 0x00, 0x00, 0xe0, 0x60
.byte	0x60, 0x66, 0x6c, 0x78, 0x78, 0x6c, 0x66, 0xe6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xec, 0xfe, 0xd6
.byte	0xd6, 0xd6, 0xd6, 0xc6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xdc, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdc, 0x66, 0x66
.byte	0x66, 0x66, 0x66, 0x7c, 0x60, 0x60, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x76, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x7c, 0x0c, 0x0c, 0x1e, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xdc, 0x76, 0x66, 0x60, 0x60, 0x60, 0xf0
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c, 0xc6, 0x60
.byte	0x38, 0x0c, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x30
.byte	0x30, 0xfc, 0x30, 0x30, 0x30, 0x30, 0x36, 0x1c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x76
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x66, 0x66
.byte	0x66, 0x66, 0x3c, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xc6, 0xc6, 0xd6, 0xd6, 0xd6, 0xfe, 0x6c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x6c, 0x38, 0x38, 0x38, 0x6c, 0xc6
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0x7e, 0x06, 0x0c, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xfe, 0xcc, 0x18, 0x30, 0x60, 0xc6, 0xfe, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x0e, 0x18, 0x18, 0x18, 0x70, 0x18, 0x18, 0x18, 0x18, 0x0e
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x18
.byte	0x18, 0x18, 0x0e, 0x18, 0x18, 0x18, 0x18, 0x70, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x76, 0xdc, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x6c, 0xc6
.byte	0xc6, 0xc6, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x66
.byte	0xc2, 0xc0, 0xc0, 0xc0, 0xc2, 0x66, 0x3c, 0x0c, 0x06, 0x7c, 0x00, 0x00
.byte	0x00, 0x00, 0xcc, 0x00, 0x00, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x76
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x18, 0x30, 0x00, 0x7c, 0xc6, 0xfe
.byte	0xc0, 0xc0, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x6c
.byte	0x00, 0x78, 0x0c, 0x7c, 0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xcc, 0x00, 0x00, 0x78, 0x0c, 0x7c, 0xcc, 0xcc, 0xcc, 0x76
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x30, 0x18, 0x00, 0x78, 0x0c, 0x7c
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6c, 0x38
.byte	0x00, 0x78, 0x0c, 0x7c, 0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x3c, 0x66, 0x60, 0x60, 0x66, 0x3c, 0x0c, 0x06
.byte	0x3c, 0x00, 0x00, 0x00, 0x00, 0x10, 0x38, 0x6c, 0x00, 0x7c, 0xc6, 0xfe
.byte	0xc0, 0xc0, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x00
.byte	0x00, 0x7c, 0xc6, 0xfe, 0xc0, 0xc0, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x60, 0x30, 0x18, 0x00, 0x7c, 0xc6, 0xfe, 0xc0, 0xc0, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x00, 0x00, 0x38, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x3c, 0x66
.byte	0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x60, 0x30, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x00, 0x10, 0x38, 0x6c, 0xc6, 0xc6
.byte	0xfe, 0xc6, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6c, 0x38, 0x00
.byte	0x38, 0x6c, 0xc6, 0xc6, 0xfe, 0xc6, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x18, 0x30, 0x60, 0x00, 0xfe, 0x66, 0x60, 0x7c, 0x60, 0x60, 0x66, 0xfe
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xcc, 0x76, 0x36
.byte	0x7e, 0xd8, 0xd8, 0x6e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3e, 0x6c
.byte	0xcc, 0xcc, 0xfe, 0xcc, 0xcc, 0xcc, 0xcc, 0xce, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x10, 0x38, 0x6c, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x00, 0x00, 0x7c, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x30, 0x18
.byte	0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x30, 0x78, 0xcc, 0x00, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x76
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x30, 0x18, 0x00, 0xcc, 0xcc, 0xcc
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x00
.byte	0x00, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7e, 0x06, 0x0c, 0x78, 0x00
.byte	0x00, 0xc6, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc6, 0x00, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6
.byte	0xc6, 0xc6, 0xc6, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x3c
.byte	0x66, 0x60, 0x60, 0x60, 0x66, 0x3c, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x38, 0x6c, 0x64, 0x60, 0xf0, 0x60, 0x60, 0x60, 0x60, 0xe6, 0xfc
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x66, 0x3c, 0x18, 0x7e, 0x18
.byte	0x7e, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0xcc, 0xcc
.byte	0xf8, 0xc4, 0xcc, 0xde, 0xcc, 0xcc, 0xcc, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x0e, 0x1b, 0x18, 0x18, 0x18, 0x7e, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0xd8, 0x70, 0x00, 0x00, 0x00, 0x18, 0x30, 0x60, 0x00, 0x78, 0x0c, 0x7c
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x18, 0x30
.byte	0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x18, 0x30, 0x60, 0x00, 0x7c, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x30, 0x60, 0x00, 0xcc, 0xcc, 0xcc
.byte	0xcc, 0xcc, 0xcc, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xdc
.byte	0x00, 0xdc, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00
.byte	0x76, 0xdc, 0x00, 0xc6, 0xe6, 0xf6, 0xfe, 0xde, 0xce, 0xc6, 0xc6, 0xc6
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x6c, 0x6c, 0x3e, 0x00, 0x7e, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6c, 0x6c
.byte	0x38, 0x00, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x30, 0x30, 0x00, 0x30, 0x30, 0x60, 0xc0, 0xc6, 0xc6, 0x7c
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xc0
.byte	0xc0, 0xc0, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0xfe, 0x06, 0x06, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xc0, 0xc0, 0xc2, 0xc6, 0xcc, 0x18, 0x30, 0x60, 0xdc, 0x86, 0x0c
.byte	0x18, 0x3e, 0x00, 0x00, 0x00, 0xc0, 0xc0, 0xc2, 0xc6, 0xcc, 0x18, 0x30
.byte	0x66, 0xce, 0x9e, 0x3e, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18
.byte	0x00, 0x18, 0x18, 0x18, 0x3c, 0x3c, 0x3c, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x6c, 0xd8, 0x6c, 0x36, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xd8, 0x6c, 0x36
.byte	0x6c, 0xd8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x44, 0x11, 0x44
.byte	0x11, 0x44, 0x11, 0x44, 0x11, 0x44, 0x11, 0x44, 0x11, 0x44, 0x11, 0x44
.byte	0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa
.byte	0x55, 0xaa, 0x55, 0xaa, 0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77
.byte	0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0xf8, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0xf8, 0x18, 0xf8
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0xf6, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x18, 0xf8
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0xf6, 0x06, 0xf6, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0x06, 0xf6
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0xf6, 0x06, 0xfe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0xfe, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0xf8, 0x18, 0xf8
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0xf8, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1f, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0xff, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1f, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0xff, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x1f, 0x18, 0x1f, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x37
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x37, 0x30, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x30, 0x37, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0xf7, 0x00, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xff, 0x00, 0xf7, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x37, 0x30, 0x37, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0xf7, 0x00, 0xf7, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0xff, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0xff
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xff, 0x00, 0xff, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x3f
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x1f, 0x18, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x1f, 0x18, 0x1f, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f
.byte	0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x36, 0x36, 0x36, 0xff, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36, 0x36
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0xff, 0x18, 0xff, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0xf8
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x1f, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
.byte	0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff
.byte	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf0, 0xf0, 0xf0, 0xf0
.byte	0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0
.byte	0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f, 0x0f
.byte	0x0f, 0x0f, 0x0f, 0x0f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x76, 0xdc, 0xd8, 0xd8, 0xd8, 0xdc, 0x76, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x78, 0xcc, 0xcc, 0xcc, 0xd8, 0xcc, 0xc6, 0xc6, 0xc6, 0xcc
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfe, 0xc6, 0xc6, 0xc0, 0xc0, 0xc0
.byte	0xc0, 0xc0, 0xc0, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0xfe, 0x6c, 0x6c, 0x6c, 0x6c, 0x6c, 0x6c, 0x6c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0xfe, 0xc6, 0x60, 0x30, 0x18, 0x30, 0x60, 0xc6, 0xfe
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0xd8, 0xd8
.byte	0xd8, 0xd8, 0xd8, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x66, 0x66, 0x66, 0x66, 0x66, 0x7c, 0x60, 0x60, 0xc0, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x76, 0xdc, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x18, 0x3c, 0x66, 0x66
.byte	0x66, 0x3c, 0x18, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38
.byte	0x6c, 0xc6, 0xc6, 0xfe, 0xc6, 0xc6, 0x6c, 0x38, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x38, 0x6c, 0xc6, 0xc6, 0xc6, 0x6c, 0x6c, 0x6c, 0x6c, 0xee
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1e, 0x30, 0x18, 0x0c, 0x3e, 0x66
.byte	0x66, 0x66, 0x66, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x7e, 0xdb, 0xdb, 0xdb, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x03, 0x06, 0x7e, 0xdb, 0xdb, 0xf3, 0x7e, 0x60, 0xc0
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0x30, 0x60, 0x60, 0x7c, 0x60
.byte	0x60, 0x60, 0x30, 0x1c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7c
.byte	0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0xc6, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0xfe, 0x00, 0x00, 0xfe, 0x00, 0x00, 0xfe, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x7e, 0x18
.byte	0x18, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30
.byte	0x18, 0x0c, 0x06, 0x0c, 0x18, 0x30, 0x00, 0x7e, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x0c, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0c, 0x00, 0x7e
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0e, 0x1b, 0x1b, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18
.byte	0x18, 0x18, 0x18, 0x18, 0xd8, 0xd8, 0xd8, 0x70, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x7e, 0x00, 0x18, 0x18, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xdc, 0x00
.byte	0x76, 0xdc, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x6c, 0x6c
.byte	0x38, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x0c, 0x0c
.byte	0x0c, 0x0c, 0x0c, 0xec, 0x6c, 0x6c, 0x3c, 0x1c, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0xd8, 0x6c, 0x6c, 0x6c, 0x6c, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0xd8, 0x30, 0x60, 0xc8, 0xf8, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x7c, 0x7c, 0x7c, 0x7c, 0x7c, 0x7c, 0x7c, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x00, 0x00, 0x00, 0x00

/*
 * Alternate 9x16 VGA font table.
 *
 * This only includes some wide characters that differ from data in Font_8x16.
 * The format is one byte for replaced character followed by 16 bytes of data.
 *
 * I converted this manually from the informative example images found at
 * https://nerdlypleasures.blogspot.com/2015/04/ibm-character-fonts.html
 */
Font_9x16:
.byte	0x1d
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x66, 0xff	# <->
.byte	0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte	0x30
.byte	0x00, 0x00, 0x3c, 0x66, 0xc3, 0xc3, 0xdb, 0xdb	# 0
.byte	0xc3, 0xc3, 0x66, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x4d
.byte	0x00, 0x00, 0xc3, 0xe7, 0xff, 0xff, 0xdb, 0xc3	# M
.byte	0xc3, 0xc3, 0xc3, 0xc3, 0x00, 0x00, 0x00, 0x00
.byte	0x54
.byte	0x00, 0x00, 0xff, 0xdb, 0x99, 0x18, 0x18, 0x18	# T
.byte	0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x56
.byte	0x00, 0x00, 0xc3, 0xc3, 0xc3, 0xc3, 0xc3, 0xc3	# V
.byte	0xc3, 0x66, 0x3c, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x57
.byte	0x00, 0x00, 0xc3, 0xc3, 0xc3, 0xc3, 0xc3, 0xdb	# W
.byte	0xdb, 0xff, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00
.byte	0x58
.byte	0x00, 0x00, 0xc3, 0xc3, 0x66, 0x3c, 0x18, 0x18	# X
.byte	0x3c, 0x66, 0xc3, 0xc3, 0x00, 0x00, 0x00, 0x00
.byte	0x59
.byte	0x00, 0x00, 0xc3, 0xc3, 0xc3, 0x66, 0x3c, 0x18	# Y
.byte	0x18, 0x18, 0x18, 0x3c, 0x00, 0x00, 0x00, 0x00
.byte	0x5a
.byte	0x00, 0x00, 0xff, 0xc3, 0x86, 0x0c, 0x18, 0x30	# Z
.byte	0x60, 0xc1, 0xc3, 0xff, 0x00, 0x00, 0x00, 0x00
.byte	0x6d
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xe6, 0xff, 0xdb	# m
.byte	0xdb, 0xdb, 0xdb, 0xdb, 0x00, 0x00, 0x00, 0x00
.byte	0x76
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc3, 0xc3, 0xc3	# v
.byte	0xc3, 0x66, 0x3c, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x77
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc3, 0xc3, 0xc3	# w
.byte	0xdb, 0xdb, 0xff, 0x66, 0x00, 0x00, 0x00, 0x00
.byte	0x78
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x66, 0x3c	# x
.byte	0x18, 0x3c, 0x66, 0xc3, 0x00, 0x00, 0x00, 0x00
.byte	0x91
.byte	0x00, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x3b, 0x1b	# ae
.byte	0x7e, 0xd8, 0xdc, 0x77, 0x00, 0x00, 0x00, 0x00
.byte	0x9b
.byte	0x00, 0x18, 0x18, 0x7e, 0xc3, 0xc0, 0xc0, 0xc0	# cent
.byte	0xc3, 0x7e, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x9d
.byte	0x00, 0x00, 0xc3, 0x66, 0x3c, 0x18, 0xff, 0x18	# yen
.byte	0xff, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00
.byte	0x9e
.byte	0x00, 0xfc, 0x66, 0x66, 0x7c, 0x62, 0x66, 0x6f	# Pt
.byte	0x66, 0x66, 0x66, 0xf3, 0x00, 0x00, 0x00, 0x00
.byte	0xab
.byte	0x00, 0xc0, 0xc0, 0xc2, 0xc6, 0xcc, 0x18, 0x30	# 1/2
.byte	0x60, 0xce, 0x9b, 0x06, 0x0c, 0x1f, 0x00, 0x00
.byte	0xac
.byte	0x00, 0xc0, 0xc0, 0xc2, 0xc6, 0xcc, 0x18, 0x30	# 1/4
.byte	0x66, 0xce, 0x96, 0x3e, 0x06, 0x06, 0x00, 0x00
EmptyTable:
.byte	0x00

/*** Splash Screen ************************************************************/

#ifdef	SPLASH
#include "splash.S"
SplashEnd:
#endif

/*** Test Code ****************************************************************/

#ifdef	TESTING
#include "video_bios.t"
#endif

/*** Empty Space **************************************************************/

/*
 * A devmem segment must be a multiple of the system page size.
 * Otherwise, 2048 bytes would have been enough for PCI ROMs.
 */
.align 4096, 0x00

/*
 * Of course, the address space of a PCI expansion ROM must also
 * be a power of two. You may need to increase the exponent here
 * if the assembler complains about moving .org backwards.
 */
#if defined(SPLASH) || defined(TESTING)
.org (1 << 16) - 1, 0x00
#else
.org (1 << 15) - 1, 0x00
#endif

.global VideoBIOS_end
VideoBIOS_end:
.byte	0x00

TAIL: /* End of Video ROM */
/******************************************************************************/
