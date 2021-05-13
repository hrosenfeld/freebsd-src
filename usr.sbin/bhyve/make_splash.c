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
 * This is a small tool to convert images saved by GIMP to assembly code for
 * use as a splash screen. In GIMP, select "Image -> Mode -> Indexed..." and
 * pick 256 as the maximum number of colors. Export the image as "splash.h".
 * The program was written for GIMP 2.10.8; later versions may be different.
 *
 * The image is compressed with an algorithm that makes it simple enough to
 * unpack in assembly code: Run-Length Encoding, where each color value is
 * followed by one or two repeat bytes if that makes the total size smaller.
 * This tool checks when it is best to use two, one, or zero repeat bytes.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/*** User Data ****************************************************************/

/* This header file contains image data saved by GIMP. */
#include "splash.h"

/*
 * You will probably have to change this copyright header.
 * The structure of the output is not in itself enough for
 * copyright protection, so this really gives the license
 * for the image data. Maybe some other license is better?
 */
static char *copyright =
"/*-\n"
" * SPDX-License-Identifier: BSD-2-Clause-FreeBSD\n"
" *\n"
" * Copyright (c) 2019 Henrik Gulbrandsen <henrik@gulbra.net>\n"
" *\n"
" * Redistribution and use in source and binary forms, with or without\n"
" * modification, are permitted provided that the following conditions\n"
" * are met:\n"
" * 1. Redistributions of source code must retain the above copyright\n"
" *    notice, this list of conditions and the following disclaimer.\n"
" * 2. Redistributions in binary form must reproduce the above copyright\n"
" *    notice, this list of conditions and the following disclaimer in the\n"
" *    documentation and/or other materials provided with the distribution.\n"
" *\n"
" * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND\n"
" * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE\n"
" * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE\n"
" * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE\n"
" * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL\n"
" * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS\n"
" * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)\n"
" * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT\n"
" * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY\n"
" * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF\n"
" * SUCH DAMAGE.\n"
" *\n"
" * $FreeBSD$\n"
" */\n";

/*** Definitions **************************************************************/

#define	MAX(a, b) (((a) > (b))? (a) : (b))

typedef struct {
	int old_color;	/* Original color index */
	int new_color;	/* Modified color index */
	int saved1;	/* Bytes saved with 1-byte RLE */
	int saved2;	/* Bytes saved with 2-byte RLE */
} InfoEntry;

/*** Global Variables *********************************************************/

int16_t byte_level = -1; /* SplashLevel1 */
int16_t word_level = -1; /* SplashLevel2 */

int data_size;
int column;

InfoEntry info[256];

/*** Functions ****************************************************************/

/*
 * Calculates the number of bytes saved with 1-byte RLE.
 */
void calculate_saved1() {
	int index, size;

	size = width * height;
	index = 0;

	while (index < size) {
		uint8_t value = header_data[index++];
		uint8_t count = 1;

		while (index < size && header_data[index] == value) {
			if (count == 0xff) break;
			count++;
			index++;
		}

		info[value].saved1 += count - 2;
	}
}

/*
 * Calculates the number of bytes saved with 2-byte RLE.
 */
void calculate_saved2() {
	int index, size;

	size = width * height;
	index = 0;

	while (index < size) {
		uint8_t value = header_data[index++];
		uint16_t count = 1;

		while (index < size && header_data[index] == value) {
			if (count == 0xffff) break;
			count++;
			index++;
		}

		info[value].saved2 += count - 3;
	}
}

/*
 * Quicksort comparison function to get the new color order.
 */
int compare_saved(const void *arg1, const void *arg2) {
	const InfoEntry *entry1 = arg1;
	const InfoEntry *entry2 = arg2;
	int saved1, saved2;

	/* Entry 1 comes first if it uses 2-byte RLE and the other doesn't */
	if (entry1->saved2 > entry1->saved1 && entry2->saved2 <= entry2->saved1)
		return -1;

	/* Entry 2 comes first if it uses 2-byte RLE and the other doesn't */
	if (entry2->saved2 > entry2->saved1 && entry1->saved2 <= entry1->saved1)
		return +1;

	/* Otherwise, the entry that saves the most comes first */
	saved1 = MAX(entry1->saved1, entry1->saved2);
	saved2 = MAX(entry2->saved1, entry2->saved2);
	if (saved1 > saved2) return -1;
	if (saved1 < saved2) return +1;

	return 0;
}

/*
 * Quicksort comparison function to get the old color order.
 */
int compare_value(const void *arg1, const void *arg2) {
	const InfoEntry *entry1 = arg1;
	const InfoEntry *entry2 = arg2;

	if (entry1->old_color < entry2->old_color) return -1;
	if (entry1->old_color > entry2->old_color) return +1;

	return 0;
}

void analyze_data(void) {
	int index;

	for (index = 0; index < 256; index++)
		info[index].old_color = index;

	calculate_saved1();
	calculate_saved2();

	/* Sort the colors to put RLE-encoded colors first */
	qsort(info, 256, sizeof(*info), compare_saved);

	/* Fill in new_color and update the RLE levels */
	for (index = 0; index < 256; index++) {
		info[index].new_color = index;
		if (MAX(info[index].saved1, info[index].saved2) > 0) {
			if (info[index].saved2 > info[index].saved1) {
				word_level = index;
			} else {
				byte_level = index;
			}
		}
	}

#if 0
	/*
	 * This loop can be used to see the number of saved bytes.
	 */
	for (index = 0; index < 256; index++) {
		fprintf(stderr, "saved for value %3d: %d/%d\n",
		    info[index].value, info[index].saved1, info[index].saved2);
	}
#endif

    /* Restore the original order to simplify color lookup */
    qsort(info, 256, sizeof(*info), compare_value);
}

/*
 * Returns the old color for a given new color.
 */
uint8_t get_old_for_new(uint8_t new_color) {
	int index;

	for (index = 0; index < 256; index++)
		if (info[index].new_color == new_color)
			return index;

	fprintf(stderr, "Unmapped new value!\n");
	exit(1);
}

/*
 * Returns the new color for a given old color.
 */
uint8_t get_new_for_old(uint8_t old_color) {
	return info[old_color].new_color;
}

/*
 * Adds another byte to the SplashImage data.
 */
void output_byte(uint8_t byte) {

	if (column >= 12) {
		printf("\n");
		column = 0;
	}

	if (column == 0) {
		printf(".byte\t");
	} else {
		printf(", ");
	}

	printf("0x%02x", byte);
	data_size += 1;
	column += 1;
}

/*** Main Program *************************************************************/

int main(int argc, char *argv[]) {
	int index, part, size;

	analyze_data();

	printf("%s\n", copyright);

	printf("/* The width of the splash image */\n");
	printf("SplashWidth:\n");
	printf(".word\t%d\n", width);
	printf("\n");

	printf("/* The height of the splash image */\n");
	printf("SplashHeight:\n");
	printf(".word\t%d\n", height);
	printf("\n");

	printf("/* The highest color using one-byte RLE counts (or -1) */\n");
	printf("SplashLevel1:\n");
	printf(".word\t%d\n", byte_level);
	printf("\n");

	printf("/* The highest color using two-byte RLE counts (or -1) */\n");
	printf("SplashLevel2:\n");
	printf(".word\t%d\n", word_level);
	printf("\n");

	printf("/*\n");
	printf(" * 256 24-bit palette entries for the splash image.\n");
	printf(" */\n");
	printf("SplashPalette:\n");

	for (index = 0; index < 256; index++) {
		uint8_t color = get_old_for_new(index);

		if (index % 4 == 0)
			printf(".byte\t");

		for (part = 0; part < 3; part++) {
			uint8_t byte = (uint8_t)header_data_cmap[color][part];
			printf("0x%02x%s", byte, (index % 4 < 3 || part != 2)?
			    ", " : "\n");
		}
	}

	printf("\n");
	printf("/*\n");
	printf(" * Image data with adaptive run-length encoding.\n");
	printf(" * Each one-byte color value is followed by zero,\n");
	printf(" * one, or two bytes for the repeat count.\n");
	printf(" */\n");
	printf("SplashImage:\n");
	size = width * height;
	index = 0;

	while (index < size) {
		uint8_t value = header_data[index++];
		uint8_t color = get_new_for_old(value);
		uint16_t count = 1;

		/*
		 * Output the color byte.
		 */
		output_byte(color);

		/*
		 * Output data for colors with two-byte repeat counts
		 */
		if (color <= word_level) {
			while (index < size && header_data[index] == value) {
				if (count == 0xffff) break;
				count++;
				index++;
			}
			output_byte(count & 0xff);
			output_byte(count >> 8);
			continue;
		}

		/*
		 * Output data for colors with one-byte repeat counts
		 */
		if (color <= byte_level) {
			while (index < size && header_data[index] == value) {
				if (count == 0xff) break;
				count++;
				index++;
			}
			output_byte(count);
			continue;
		}
	}

	printf("\n");

	/* This information may be of interest to the user */
	fprintf(stderr, "Total image size: %lu bytes\n",
	    4 * sizeof(uint16_t)  + /* Width, height, and levels */
	    768 * sizeof(uint8_t) + /* Palette */
	    data_size);             /* Image data */

	return 0;
}

/******************************************************************************/
