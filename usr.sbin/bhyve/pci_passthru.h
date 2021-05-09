/*-
 * SPDX-License-Identifier: BSD-2-Clause-FreeBSD
 *
 * Copyright (c) 2020 Beckhoff Automation GmbH & Co. KG
 * All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR OR CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
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

#pragma once

#include <sys/pciio.h>

#include <vmmapi.h>

#include "config.h"
#include "pci_emul.h"

struct passthru_mmio_mapping {
	uint64_t gpa;
	uint64_t len;
	uint64_t hpa;
};

struct passthru_softc {
	struct pci_devinst *psc_pi;
	struct pcibar psc_bar[PCI_BARMAX + 1];
	struct {
		int capoff;
		int msgctrl;
		int emulated;
	} psc_msi;
	struct {
		int capoff;
	} psc_msix;
	struct pcisel psc_sel;

	struct passthru_mmio_mapping psc_mmio_map[2];
	uint8_t psc_pcir_prot_map[(PCI_REGMAX + 1) / 4];
};

#define PT_MAP_PPTDEV_MMIO 1
#define PT_UNMAP_PPTDEV_MMIO 0

#define PPT_PCIR_PROT_NA 0 /* No Access to physical values */
#define PPT_PCIR_PROT_RO 1 /* Read Only access to physical values */
#define PPT_PCIR_PROT_WO 2 /* Write Only access to physical values */
#define PPT_PCIR_PROT_RW    \
	(PPT_PCIR_PROT_RO | \
	    PPT_PCIR_PROT_WO) /* Read/Write access to physical values */
#define PPT_PCIR_PROT_MASK 0x03

#define GET_INT_CONFIG(var, name)                                           \
	do {                                                                \
		const char *value = get_config_value_node(nvl, name);       \
		if (value == NULL) {                                        \
			EPRINTLN(                                           \
			    "passthru: missing required %s setting", name); \
			return (1);                                         \
		}                                                           \
		var = atoi(value);                                          \
	} while (0)

int passthru_modify_pptdev_mmio(struct vmctx *ctx, struct passthru_softc *sc,
    struct passthru_mmio_mapping *map, int registration);
uint32_t read_config(const struct pcisel *sel, long reg, int width);
void write_config(const struct pcisel *sel, long reg, int width, uint32_t data);
int set_pcir_prot(
    struct passthru_softc *sc, uint32_t reg, uint32_t len, uint8_t prot);
int gvt_d_early_quirks(struct vmctx *ctx, struct pcisel *sel);
int gvt_d_init(struct vmctx *ctx, struct pci_devinst *pi, nvlist_t *nvl);
void gvt_d_deinit(struct vmctx *ctx, struct pci_devinst *pi);
