/******************************************************************************/
/*                       Tests for the bhyve Video BIOS                       */
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

/*** Definitions **************************************************************/

/* Mask Values for BadRegisterMask */
#define	MASK_AX	0x0001
#define	MASK_BX	0x0002
#define	MASK_CX	0x0004
#define	MASK_DX	0x0008
#define	MASK_SP	0x0010
#define	MASK_BP	0x0020
#define	MASK_SI	0x0040
#define	MASK_DI	0x0080
#define	MASK_CS	0x0100
#define	MASK_DS	0x0200
#define	MASK_SS	0x0400
#define	MASK_ES	0x0800

/*** Static Data Area *********************************************************/

/*
 * TestVideoBios is called from Init, so this should be read/write.
 */

SavedAxValue:
SavedAlValue: .byte 0x00
SavedAhValue: .byte 0x00
SavedBxValue:
SavedBlValue: .byte 0x00
SavedBhValue: .byte 0x00
SavedCxValue:
SavedClValue: .byte 0x00
SavedChValue: .byte 0x00
SavedDxValue:
SavedDlValue: .byte 0x00
SavedDhValue: .byte 0x00
SavedSpValue: .word 0x0000
SavedBpValue: .word 0x0000
SavedSiValue: .word 0x0000
SavedDiValue: .word 0x0000
SavedCsValue: .word 0x0000
SavedDsValue: .word 0x0000
SavedSsValue: .word 0x0000
SavedEsValue: .word 0x0000

BadRegisterMask:
.word	0x0000

SavedCursor:
.word	0x0000

FailCount:
.word	0x0000

TestCount:
.word	0x0000

/*** Strings ******************************************************************/

NAME_AX:
.asciz	"ax"
NAME_BX:
.asciz	"bx"
NAME_CX:
.asciz	"cx"
NAME_DX:
.asciz	"dx"
NAME_SP:
.asciz	"sp"
NAME_BP:
.asciz	"bp"
NAME_SI:
.asciz	"si"
NAME_DI:
.asciz	"di"
NAME_CS:
.asciz	"cs"
NAME_DS:
.asciz	"ds"
NAME_SS:
.asciz	"ss"
NAME_ES:
.asciz	"es"

.set LEN_SUCCESS, 9
STR_SUCCESS:
.ascii	"S\002u\002c\002c\002e\002s\002s\002\r\000\n\000"

.set LEN_FAILURE, 7
STR_FAILURE:
.ascii	"F\004a\004i\004l\004u\004r\004e\004"

STR_LEFT:
.asciz	"("
STR_RIGHT:
.asciz	")"
STR_COMMA:
.asciz	","
STR_DOT:
.asciz	"."
STR_SPACE:
.asciz	" "

STR_FINAL_RESULT:
.asciz	"Final result: "
STR_OF:
.asciz	" of "
STR_TESTS_FAILED:
.asciz	" tests failed.\r\n"

/*** Macros *******************************************************************/

/*
 * Switches to a given VGA mode without clearing buffer or cursor positions.
 *
 * Arguments:
 *   Mode - The new mode
 *
 * Clobbers: Nothing
 */
.macro VgaMode Mode
	push	%ax
	mov	\Mode, %al
	call	SwitchToVideoMode
	pop	%ax
.endm

/*
 * Calls WriteSingleBadRegister if a given register value is bad.
 *
 * This is a help macro for WriteBadRegisters.
 *
 * Arguments:
 *   Name - The name of a register
 *   Mask - The associated register mask
 *
 * Clobbers: AX, BX
 */
.macro WifBad Name, Mask
	mov	\Name, %ax
	mov	\Mask, %bx
	call	WriteSingleBadRegister
.endm

/*
 * Sets the register with a given Name to the given Value.
 *
 * If Temp is given, that register is used as a temporary
 * storage location for Value before assigning it to Name.
 *
 * Arguments:
 *   Name  - The name of a register
 *   Value - The hexadecimal value to set
 *   Temp  - Optional temporary register
 */
.macro Assign Name, Value, Temp
    .ifb \Temp
	mov	$0x\Value, %\Name
    .else
	push	%\Temp
	mov	$0x\Value, %\Temp
	mov	%\Temp, %\Name
	pop	%\Temp
    .endif
.endm

/*
 * Pushes or pops a given register or its 16-bit extension.
 *
 * Arguments:
 *   Type - The type of stack operation (push/pop)
 *   Name - The name of a possibly 8-bit register
 *   Word - The corresponding 16-bit register
 */
.macro Stack Type, Name, Word
    .ifnb \Word
	\Type	%\Word
    .else
	\Type	%\Name
    .endif
.endm

/*
 * Prepares input and output values for the RunTest macro.
 *
 * The input value is stored in the register, and the output value is stored
 * in a particular memory location for later verification by VerifyRegisters.
 *
 * Arguments:
 *   Name   - The name of a register
 *   Input  - Input value for the call
 *   Output - Expected output value
 *   Memory - Camelcase name for the memory location
 *   Word   - The 16-bit register holding this one
 *   Temp   - Temporary register used to set seg-regs
 */
.macro Arg Name, Input, Output, Memory, Word, Temp

  /* Use the output variable if we have one */
  .ifnb \Output
    .ifb \Input
      Stack push, \Name, \Word
    .endif
    Assign \Name, \Output, \Temp

  /* Otherwise use the input as a default output value */
  .else
    .ifnb \Input
      Assign \Name, \Input, \Temp
    .endif
  .endif

  /* In any case, save the expected output value... */
  .ifnb \Input\Output
	mov	%\Name, Saved\Memory\()Value
  .endif

  /* ...before setting any potential input value */
  .ifnb \Output
    .ifb \Input
      Stack pop, \Name, \Word
    .else
      Assign \Name, \Input, \Temp
    .endif
  .endif

.endm

/*
 * Verifies that a given INT 10h call has the expected output values.
 *
 * Input values and expected output values are given as macro arguments.
 * Unused registers get random values from a list of predefined words.
 * The verification fails if an unused register is changed, or if some
 * unexpected output value appears in a register. In that case, a list
 * of all incorrect registers is printed as part of the test output.
 *
 * Arguments:
 *   Name - A descriptive name for the test to execute
 *   Mode - The VGA mode in which the call should be tested
 *     XX - Uppercase register names are input values
 *     xx - Lowercase register names are output values
 */
.macro RunTest Name:req, Mode, \
	AH, AL, AX, BH, BL, BX, CH, CL, CX, DH, DL, DX, \
	ah, al, ax, bh, bl, bx, ch, cl, cx, dh, dl, dx, \
	SP, BP, SI, DI, CS, DS, SS, ES, \
	sp, bp, si, di, cs, ds, ss, es

	call	Test_\Name
	jmp	9f

Name_\Name:
.asciz	"\Name"

Test_\Name:
	DHeader	"Test_\Name"
	PushSet	%ax, %bx, %cx, %dx, %si, %di, %ds, %es

	/* Print the test name and prepare all registers */
	mov	$Name_\Name, %ax
	call	PrepareForTest

	/* Let arguments take effect */
	Arg	ah, \AH, \ah, Ah, Word=ax
	Arg	al, \AL, \al, Al, Word=ax
	Arg	ax, \AX, \ax, Ax
	Arg	bh, \BH, \bh, Bh, Word=bx
	Arg	bl, \BL, \bl, Bl, Word=bx
	Arg	bx, \BX, \bx, Bx
	Arg	ch, \CH, \ch, Ch, Word=cx
	Arg	cl, \CL, \cl, Cl, Word=cx
	Arg	cx, \CX, \cx, Cx
	Arg	dh, \DH, \dh, Dh, Word=dx
	Arg	dl, \DL, \dl, Dl, Word=dx
	Arg	dx, \DX, \dx, Dx
	Arg	sp, \SP, \sp, Sp
	Arg	bp, \BP, \bp, Bp
	Arg	si, \SI, \si, Si
	Arg	di, \DI, \di, Di
	Arg	cs, \CS, \cs, Cs, Temp=ax
	Arg	ds, \DS, \ds, Ds, Temp=ax
	Arg	ss, \SS, \ss, Ss, Temp=ax
	Arg	es, \ES, \es, Es, Temp=ax

	/* Registers are saved in the code segment... */
	call	UpdateChecksums

.ifnb	\Mode
    .ifnc "\Mode", "VESA"
	VgaMode	$0x\Mode
    .endif
.endif

	/* Call the BIOS function  */
	int	$0x10

.ifnb	\Mode
	VgaMode	$0x03
.endif

	/* Verify the result */
	call	VerifyRegisters

	PopSet	%ax, %bx, %cx, %dx, %si, %di, %ds, %es
	ret
9:
.endm

/*** Test Code ****************************************************************/

/*
 * The main test suite for the bhyve Video BIOS.
 */
TestVideoBios:

	/* Use the code segment for data by default */
	push	%ds
	push	%cs
	pop	%ds

	/* Set a dummy font pointer for the FontInformation test */
	PushSet	%ax, %ds
	xor	%ax, %ax
	mov	%ax, %ds
	movw	$0xABCD, 0x010c
	movw	$0x1234, 0x010e
	PopSet	%ax, %ds

	/* Run the test suites and print a summary */
	call	TestAncientFunctions
	call	TestVesaFunctions
	call	PrintSummaryLine

	pop	%ds
9:	jmp 9b

/*
 * Tests video functions from the original IBM PS/2.
 */
TestAncientFunctions:
	RunTest	SetVideoMode AH=00 AL=83
	RunTest	SetCursorType AH=01 CX=000F
	RunTest	SetCursorPosition AH=02 BH=00 DX=0000
	RunTest	GetCursorPosition AH=03 BH=00 cx=000f dx=032e
	RunTest	GetLightPenPosition AH=04 ah=00 bx=0000 cx=0000 dx=0000
	RunTest	SelectActiveDisplayPage AH=05 AL=00
	RunTest	ScrollActivePageUp AH=06 AL=05 BH=07 CX=0800 DX=FFFF
	RunTest	ScrollActivePageDown AH=07 AL=06 BH=07 CX=0800 DX=FFFF
	RunTest	ReadCharacterAndAttribute AH=08 BH=00 al=20 ah=07
	RunTest	WriteCharacterAndAttribute AH=09 AL=20 BL=07 BH=00 CX=02
	RunTest	WriteCharacter AH=0A AL=20 BH=00 CX=04
//	RunTest	SetColorPalette AH=0B # Not implemented
	RunTest	WriteDot AH=0C AL=0F CX=08 DX=D8 Mode=12
	RunTest	ReadDot AH=0D CX=08 DX=D8 al=0f Mode=12
	RunTest	WriteTeletypeToActivePage AH=0E AL=20
	RunTest	ReadCurrentVideoState AH=0F al=83 ah=50 bh=00
	RunTest	SetIndividualPaletteRegister AH=10 AL=00 BL=0F BH=3F
	RunTest	SetAllPaletteRegistersAndOverscan AH=10 AL=02 ES=C000 DX=7800
	RunTest	SetIndividualColorRegister AH=10 AL=10 BX=003F CL=3F CH=3F DH=3F
	RunTest	SetBlockOfColorRegisters AH=10 AL=12 BX=0 CX=8 ES=C000 DX=7811
	RunTest	UserAlphaLoad AH=11 AL=00 ES=C000 BP=7829 BH=10 CX=1 DX=0
	RunTest	FontInformation AH=11 AL=30 BH=01 es=1234 bp=ABCD cx=10 dl=18
	RunTest	ReturnEgaInformation AH=12 BL=10 bh=00 bl=03 ch=00 cl=00
	RunTest	SelectScanLines AH=12 BL=30 AL=2 al=12
	RunTest	DefaultPaletteLoading AH=12 BL=31 AL=00 al=12
	RunTest	CursorEmulation AH=12 BL=34 AL=00 al=12
	RunTest	WriteString AH=13 AL=00 ES=C000 BP=784D BH=0 CX=4 DH=18 DL=00
	RunTest	ReadDisplayCombinationCode AH=1A AL=00 al=1a bh=00 bl=08
//	RunTest	WriteDisplayCombinationCode AH=1A AL=01 # Not implemented
	RunTest	ReturnFunctionalityAndStateInfo AH=1B ES=C000 DI=7C00 BX=0 al=1b
	RunTest	ReturnStateBufferSize AH=1C AL=00 CX=0007 al=1c bx=0f
	RunTest	SaveVideoState AH=1C AL=01 ES=C000 BX=7C00 CX=0007 al=1c
	RunTest	RestoreVideoState AH=1C AL=02 ES=C000 BX=7C00 CX=0007 al=1c
	ret

/*
 * Tests functions from the VESA Bios Extension (VBE) and supplemental specs.
 */
TestVesaFunctions:
	RunTest	VBE_ReturnControllerInfo AH=4F AL=00 ES=C000 BX=7C00 ax=004f
	RunTest	VBE_ReturnModeInfo AH=4F AL=01 ES=C000 BX=7C00 CX=0118 ax=004f
	RunTest	VBE_SetMode AH=4F AL=02 ES=0 DI=0 BX=8112 ax=004f Mode=VESA
	RunTest	VBE_ReturnCurrentMode AH=4F AL=03 ax=034f
	RunTest	VBE_ReturnStateBufferSize AH=4F AL=04 DL=00 CX=0F ax=004f bx=0f
	RunTest	VBE_SaveState AH=4F AL=04 DL=01 ES=C000 BX=7C00 CX=0F ax=004f
	RunTest	VBE_RestoreState AH=4F AL=04 DL=02 ES=C000 BX=7C00 CX=0F ax=004f
	RunTest	VBE_DisplayWindowControl AH=4F AL=05 ax=034f
	RunTest	VBE_SetScanLineLengthInPixels AH=4F AL=06 BL=00 CX=0 ax=034f
	RunTest	VBE_GetScanLineLength AH=4F AL=06 BL=01 ax=034f
	RunTest	VBE_SetScanLineLengthInBytes AH=4F AL=06 BL=02 CX=0 ax=034f
	RunTest	VBE_GetMaximumScanLineLength AH=4F AL=06 BL=03 ax=034f
	RunTest	VBE_SetDisplayStart AH=4F AL=07 BL=00 CX=0 DX=0 ax=004f
	RunTest	VBE_SetDisplayStartDuringVerticalRetrace \
		AH=4F AL=07 BL=00 CX=0 DX=0 ax=004f
	RunTest	VBE_SetDacPaletteFormat AH=4F AL=08 BL=00 ax=034f
	RunTest	VBE_GetDacPaletteFormat AH=4F AL=08 BL=01 ax=034f
	RunTest	VBE_SetPaletteData AH=4F AL=09 BL=00 ES=C000 DI=7851 \
		CX=9 DX=0 ax=004f
	RunTest	VBE_GetPaletteData AH=4F AL=09 BL=01 ax=024f
	RunTest	VBE_SetSecondaryPaletteData AH=4F AL=09 BL=02 ax=024f
	RunTest	VBE_GetSecondaryPaletteData AH=4F AL=09 BL=03 ax=024f
	RunTest	VBE_SetPaletteDataDuringVerticalRetrace AH=4F AL=09 BL=00 \
		ES=C000 DI=7851 CX=9 DX=0 ax=004f
	RunTest	VBE_GetClosestPixelClock AH=4F AL=0B BL=00 CX=ABCD, DX=0118 \
		ax=004f
	RunTest	PM_GetCapabilities AH=4F AL=10 BL=00 ES=0 DI=0 \
		ax=004f bl=10 bh=00
	RunTest	PM_SetDisplayPowerState AH=4F AL=10 BL=01 BH=01 ax=024f
	RunTest	PM_GetDisplayPowerState AH=4F AL=10 BL=02 ax=004f bh=00
	RunTest	DDC_ReportCapabilities AH=4F AL=15 BL=00 ax=004f bx=0002
	RunTest	DDC_ReadEDID AH=4F AL=15 BL=01 ES=C000 DI=7C00 ax=004f
	ret

/*** Support Functions ********************************************************/

/*
 * Handles test preparation that can be done outside the RunTest macro.
 *
 * Arguments:
 *   CS:AX - The test name
 *
 * Returns:
 *   AX, BX, CX, DX, BP, SI, DI, and ES with random values.
 */
PrepareForTest:

	/* Delay for 0.250 seconds */
	push	%ax
	xor	%ax, %ax
	mov	$250, %bx
	call	Delay
	pop	%ax

	/* Print the test name */
	call	PrintTestLine

	/* Save the cursor location, since the function may change it */
	push	%ds
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds
	mov	BDA_CURSOR_POSITIONS, %ax
	pop	%ds
	mov	%ax, SavedCursor

	/* Prepare input registers */
	call	PrepareRegisters
	call	SaveRegisters
	ret

/*
 * Prints a line for each test.
 *
 * This will just print the test name and the following dots.
 * Results are printed from the VerifyRegisters function.
 *
 * Arguments:
 *   CS:AX - The test name
 */
PrintTestLine:
	PushSet	%ax, %bx, %cx, %dx, %ds

	/* Print the test name */
	call	GetStringLength
	call	WriteStringWithoutAttributes

	/* Figure out how many dots we need */
	neg	%cx
	add	$45, %cx
	jle	1f

	/* Fill up with dots */
	mov	$STR_DOT, %ax
0:	call	WriteStringWithoutAttributes
	loop	0b

	/* Add a single space at the end */
1:	mov	$STR_SPACE, %ax
	call	WriteStringWithoutAttributes

	PopSet	%ax, %bx, %cx, %dx, %ds
	ret

/*
 * Prints a summary at the end of the list of test results.
 *
 * This text might be "Final result: 0 of 58 tests failed."
 */
PrintSummaryLine:
	PushSet	%ax

	mov	$STR_EOL, %ax
	call	WriteStringWithoutAttributes
	mov	$STR_FINAL_RESULT, %ax
	call	WriteStringWithoutAttributes
	mov	FailCount, %ax
	call	WriteInteger
	mov	$STR_OF, %ax
	call	WriteStringWithoutAttributes
	mov	TestCount, %ax
	call	WriteInteger
	mov	$STR_TESTS_FAILED, %ax
	call	WriteStringWithoutAttributes

	PopSet	%ax
	ret

/*
 * Fills most of the registers with randomly selected values.
 *
 * CS, DS, SS, and SP are left unchanged.
 */
PrepareRegisters:

	/* CS, DS, and SS are hard to change, but ES... */
	mov	$0xb8d6, %ax
	mov	%ax, %es

	mov	$0xf959, %ax
	mov	$0x518a, %bx
	mov	$0x7493, %cx
	mov	$0x089e, %dx
	mov	$0x9bb2, %bp
	mov	$0x5c2c, %si
	mov	$0x829a, %di
	ret

/*
 * Saves current register values in the static data area.
 */
SaveRegisters:

	/* Save the four main registers */
	mov	%ax, SavedAxValue
	mov	%bx, SavedBxValue
	mov	%cx, SavedCxValue
	mov	%dx, SavedDxValue

	/* The stack pointer is a special case */
	sub	$4, %sp
	mov	%sp, SavedSpValue
	add	$4, %sp

	/* Save everything else */
	mov	%bp, SavedBpValue
	mov	%si, SavedSiValue
	mov	%di, SavedDiValue
	mov	%cs, SavedCsValue
	mov	%ds, SavedDsValue
	mov	%ss, SavedSsValue
	mov	%es, SavedEsValue

	ret

/*
 * Compares registers after a BIOS call to the expected results.
 *
 * The result is printed as a green or red status text.
 * This function also restores the original cursor.
 */
VerifyRegisters:
	PushSet	%ax, %cx, %ds
	incw	TestCount

	movw	$0x0000, BadRegisterMask

	cmp	%ax, SavedAxValue
	je	0f
	orw	$MASK_AX, BadRegisterMask
0:	cmp	%bx, SavedBxValue
	je	0f
	orw	$MASK_BX, BadRegisterMask
0:	cmp	%cx, SavedCxValue
	je	0f
	orw	$MASK_CX, BadRegisterMask
0:	cmp	%dx, SavedDxValue
	je	0f
	orw	$MASK_DX, BadRegisterMask
0:	cmp	%sp, SavedSpValue
	je	0f
	orw	$MASK_SP, BadRegisterMask
0:	cmp	%bp, SavedBpValue
	je	0f
	orw	$MASK_BP, BadRegisterMask
0:	cmp	%si, SavedSiValue
	je	0f
	orw	$MASK_SI, BadRegisterMask
0:	cmp	%di, SavedDiValue
	je	0f
	orw	$MASK_DI, BadRegisterMask
0:	mov	%cs, %ax
	cmp	%ax, SavedCsValue
	je	0f
	orw	$MASK_CS, BadRegisterMask
0:	mov	%ds, %ax
	cmp	%ax, SavedDsValue
	je	0f
	orw	$MASK_DS, BadRegisterMask
0:	mov	%ss, %ax
	cmp	%ax, SavedSsValue
	je	0f
	orw	$MASK_SS, BadRegisterMask
0:	mov	%es, %ax
	cmp	%ax, SavedEsValue
	je	0f
	orw	$MASK_ES, BadRegisterMask

	/* Restore the original cursor position */
0:	mov	SavedCursor, %ax
	push	%ds
	mov	$BDA_SEGMENT, %cx
	mov	%cx, %ds
	mov	%ax, BDA_CURSOR_POSITIONS
	pop	%ds

	/* Complain if the test failed */
	testw	$0x0fff, BadRegisterMask
	jz	1f
	call	FailTest
	jmp	2f

	/* Look happy if the test succeeded */
1:	mov	$STR_SUCCESS, %ax
	mov	$LEN_SUCCESS, %cx
	call	WriteStringWithAttributes

2:	PopSet	%ax, %cx, %ds
	ret

/*
 * Writes an error string and increases the FailCount variable.
 */
FailTest:
	PushSet	%ax, %cx

	mov	$STR_FAILURE, %ax
	mov	$LEN_FAILURE, %cx
	call	WriteStringWithAttributes
	call	WriteBadRegisters
	mov	$STR_EOL, %ax
	call	WriteStringWithoutAttributes
	incw	FailCount

	PopSet	%ax, %cx
	ret

/*
 * Writes a parenthesis containing the list of all bad registers.
 *
 * As a side effect, this function resets BadRegisterMask to zero.
 */
WriteBadRegisters:
	PushSet	%ax, %bx

	/* Write space and a left parenthesis */
	mov	$STR_SPACE, %ax
	call	WriteStringWithoutAttributes
	mov	$STR_LEFT, %ax
	call	WriteStringWithoutAttributes

	WifBad	$NAME_AX, $MASK_AX
	WifBad	$NAME_BX, $MASK_BX
	WifBad	$NAME_CX, $MASK_CX
	WifBad	$NAME_DX, $MASK_DX
	WifBad	$NAME_SP, $MASK_SP
	WifBad	$NAME_BP, $MASK_BP
	WifBad	$NAME_SI, $MASK_SI
	WifBad	$NAME_DI, $MASK_DI
	WifBad	$NAME_CS, $MASK_CS
	WifBad	$NAME_DS, $MASK_DS
	WifBad	$NAME_SS, $MASK_SS
	WifBad	$NAME_ES, $MASK_ES

	/* Write a right parenthesis */
	mov	$STR_RIGHT, %ax
	call	WriteStringWithoutAttributes

	PopSet	%ax, %bx
	ret

/*
 * Writes a space character and a register name if the register is bad.
 *
 * This function also clears the corresponding bit in BadRegisterMask.
 *
 * Arguments:
 *      AX - The register name
 *      BX - The register mask
 */
WriteSingleBadRegister:

	/* Skip this function if the register was OK */
	test	%bx, BadRegisterMask
	jz	0f

	/* Write the register name */
	call	WriteStringWithoutAttributes

	/* Check if this was the last bad register */
	not	%bx
	and	%bx, BadRegisterMask
	jz	0f

	/* Write comma and space otherwise */
	mov	$STR_COMMA, %ax
	call	WriteStringWithoutAttributes
	mov	$STR_SPACE, %ax
	call	WriteStringWithoutAttributes

0:	ret

/*
 * Writes a string without attributes using the WriteString BIOS call.
 *
 * Every byte in the string is interpreted as a character.
 * This function is a bit easier to use than WriteString.
 * The string should be zero-terminated.
 *
 * Arguments:
 *   CS:AX - The string
 */
WriteStringWithoutAttributes:
	PushSet	%ax, %bx, %cx, %dx, %bp, %ds, %es

	/*
	 * A direct call to WriteString needs
         * an indirect %bp register value.
	 */
	push	%ax
	mov	%sp, %bp

	/* Prepare arguments for WriteString */
	call	GetStringLength
	mov	%cs, %ax
	mov	%ax, %es
	mov	$0x01, %ax
	xor	%bh, %bh

	/* Switch data segment to BDA instead of %cs */
	push	%ax
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds
	pop	%ax

	/* Make the relevant function calls */
	push	%cx
	call	GetCursorPosition
	pop	%cx
	call	WriteString
	pop	%ax

	PopSet	%ax, %bx, %cx, %dx, %bp, %ds, %es
	ret

/*
 * Writes a string with attributes using the WriteString BIOS call.
 *
 * Odd bytes in the string are interpreted as attributes.
 * This function is a bit easier to use than WriteString.
 *
 * Arguments:
 *   CS:AX - The string
 *      CX - The length
 */
WriteStringWithAttributes:
	PushSet	%ax, %bx, %dx, %bp, %ds, %es

	/*
	 * A direct call to WriteString needs
         * an indirect %bp register value.
	 */
	push	%ax
	mov	%sp, %bp

	/* Prepare arguments for WriteString */
	mov	%cs, %ax
	mov	%ax, %es
	mov	$0x03, %ax
	xor	%bh, %bh

	/* Switch data segment to BDA instead of %cs */
	push	%ax
	mov	$BDA_SEGMENT, %ax
	mov	%ax, %ds
	pop	%ax

	push	%cx
	call	GetCursorPosition
	pop	%cx
	call	WriteString
	pop	%ax

	PopSet	%ax, %bx, %dx, %bp, %ds, %es
	ret

/*
 * Writes a given value as an unsigned decimal integer.
 *
 * Arguments:
 *      AX - The integer to write
 */
WriteInteger:
	PushSet	%bx, %cx, %dx, %ds

	/* Switch data segment to BDA instead of %cs */
	mov	$BDA_SEGMENT, %bx
	mov	%bx, %ds

	/* Is the integer below 10? */
	mov	$10, %bx
	cmp	%bx, %ax
	jb	0f

	/* Use recursion if it's not */
	xor	%dx, %dx
	div	%bx
	call	WriteInteger
	mov	%dx, %ax

	/* Then write a single digit */
0:	add	$'0', %al
	call	WriteTeletypeToActivePage

	PopSet	%bx, %cx, %dx, %ds
	ret

/*
 * Returns the length of a zero-terminated string.
 *
 * Arguments:
 *   CS:AX - The string
 *
 * Returns:
 *      CX - Length in bytes, not including the '\0'
 */
GetStringLength:
	PushSet	%ax, %si

	/* Prepare loop variables */
	mov	%ax, %si
	xor	%cx, %cx

	/* Loop until the end is found */
0:	mov	%cs:(%si), %al
	test	%al, %al
	jz	1f
	inc	%cx
	inc	%si
	jmp	0b

1:	PopSet	%ax, %si
	ret

/*
 * Sets the VGA mode without clearing buffer or cursor position.
 *
 * Arguments:
 *      AL - Requested video mode; bit 7 for not clearing is automatically set
 */
SwitchToVideoMode:
	PushSet	%ax, %bx, %dx, %ds

	/* Switch data segment to BDA instead of %cs */
	mov	$BDA_SEGMENT, %bx
	mov	%bx, %ds

	/* Save the cursor position */
	mov	BDA_CURSOR_POSITIONS, %dx

	or	$0x80, %al
	call	SetVideoMode

	/* Restore the cursor position */
	xor	%bh, %bh
	call	SetCursorPosition

	PopSet	%ax, %bx, %dx, %ds
	ret

/*** Test Data ****************************************************************/

/* We use fixed addresses, so they can be hard-coded in the test lines */
.org	0x7800, 0x00

TestPalette:	# 0x7800: Test data for SetAllPaletteRegistersAndOverscan
.byte	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
.byte	0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f
.byte	0x00

TestColors:	# 0x7811: Test data for SetBlockOfColorRegisters
.byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x00, 0x00, 0x2a, 0x2a
.byte   0x2a, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x2a, 0x2a, 0x00, 0x2a, 0x2a, 0x2a

TestFont:	# 0x7829: Test data for UserAlphaLoad
.byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x81, 0xa5, 0x81, 0x81, 0xbd
.byte   0x99, 0x81, 0x81, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0xff

TestString:	# 0x784d: Test data for WriteString
.byte	0x20, 0x20, 0x20, 0x20

TestVbePalette:	# 0x7851: Test data for VBE_SetPaletteData
.byte	0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00
.byte	0x2a, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x2a, 0x00, 0x2a, 0x00
.byte	0x00, 0x2a, 0x2a, 0x00, 0x2a, 0x2a, 0x2a, 0x00, 0x15, 0x00, 0x00, 0x00

TestBuffer:	# 0x7c00: Test buffer for functions that return data
.zero	0x400

/******************************************************************************/
