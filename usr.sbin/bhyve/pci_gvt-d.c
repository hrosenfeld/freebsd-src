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

#include <sys/cdefs.h>
__FBSDID("$FreeBSD$");

#include <sys/types.h>
#include <sys/param.h>

#include <machine/vmm.h>

#include <dev/pci/pcireg.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#include "inout.h"
#include "pci_passthru.h"

#define MB (1024 * 1024UL)

/*
 * PCI definitions
 */
#define PCIR_GGC 0x50	   /* GMCH Graphics Control register */
#define PCIR_BDSM 0x5C	   /* Base Data of Stolen Memory register */
#define PCIR_ASLS_CTL 0xFC /* Opregion start address register */
#define PCIM_GEN5_75_GGC_GMS_MASK \
	0x000000F0 /* Bits 7:4 contain Graphics Mode Select */
#define PCIM_GEN6_GGC_GMS_MASK \
	0x000000F8 /* Bits 7:3 contain Graphics Mode Select */
#define PCIM_GEN8_GGC_GMS_MASK \
	0x0000FF00 /* Bits 15:8 contain Graphics Mode Select */
#define PCIM_BDSM_GSM_MASK \
	0xFFF00000 /* Bits 31:20 contain base address of gsm */
#define PCIM_ASLS_OPREGION_MASK 0xFFFFF000 /* Opregion is 4k aligned */
#define GPU_OPREGION_LEN 0x00004000	   /* Size of Opregion (16 KB) */

/*
 * Known device ids for different generations of Intel graphics
 * see https://www.graphics-drivers.eu/intel-pci-hardware-id-string.html for
 * complete list
 */
/* Westmere & Ironlake */
static const uint16_t igd_devid_gen5_75[] = { 0x0042, 0x0046 };
/* Sandy Bridge */
static const uint16_t igd_devid_gen6[] = { 0x0102, 0x0106, 0x010A, 0x0112,
	0x0116, 0x0122, 0x0126 };
/* Ivy Bridge */
static const uint16_t igd_devid_gen7[] = { 0x0152, 0x0156, 0x015A, 0x0162,
	0x0166, 0x016A };
/* Haswell */
static const uint16_t igd_devid_gen7_5[] = { 0x0402, 0x0406, 0x040A, 0x0412,
	0x0416, 0x041A, 0x041E, 0x0A06, 0x0A0E, 0x0A16, 0x0A1E, 0x0A26, 0x0A2E,
	0x0C02, 0x0C06, 0x0C12, 0x0C16, 0x0C22, 0x0C26, 0x0D06, 0x0D16, 0x0D22,
	0x0D26 };
/* Broadwell */
static const uint16_t igd_devid_gen8[] = { 0x1606, 0x160E, 0x1612, 0x1616,
	0x161A, 0x161E, 0x1622, 0x1626, 0x162A, 0x162B };
/* Skylake */
static const uint16_t igd_devid_gen9[] = { 0x1902, 0x1906, 0x190B, 0x190E,
	0x1912, 0x1913, 0x1916, 0x1917, 0x191B, 0x191D, 0x191E, 0x1921, 0x1923,
	0x1926, 0x1927, 0x192B, 0x192D, 0x1932, 0x193A, 0x193B, 0x193D };
/* Kaby Lake & Whiskey Lake & Amber Lake & Coffee Lake & Comet Lake */
static const uint16_t igd_devid_gen9_5[] = { 0x3E90, 0x3E91, 0x3E92, 0x3E93,
	0x3E94, 0x3E96, 0x3E98, 0x3E99, 0x3E9A, 0x3E9B, 0x3E9C, 0x3EA0, 0x3EA1,
	0x3EA5, 0x3EA6, 0x3EA7, 0x3EA8, 0x3EA9, 0x5902, 0x5906, 0x590B, 0x5912,
	0x5916, 0x5917, 0x591B, 0x591C, 0x591D, 0x591E, 0x5921, 0x5926, 0x5927,
	0x87C0, 0x87CA, 0x9B21, 0x9B41, 0x9BA2, 0x9BA4, 0x9BA5, 0x9BA8, 0x9BAA,
	0x9BAC, 0x9BC2, 0x9BC4, 0x9BC5, 0x9BC6, 0x9BC8, 0x9BCA, 0x9BCC, 0x9BE6,
	0x9BF6 };

static int
array_contains(const uint16_t *array, uint64_t elements, uint16_t item)
{
	for (uint64_t i = 0; i < elements; ++i)
		if (array[i] == item)
			return 1;
	return 0;
}

#define IGD_FUNC_IS_IGD_GEN(gen)                                           \
	static int igd_gen##gen##_is_igd_gen(int devid)                    \
	{                                                                  \
		return array_contains(igd_devid_gen##gen,                  \
		    sizeof(igd_devid_gen##gen) / sizeof(uint16_t), devid); \
	}

/* GVT-d definitions */
#define GVT_D_MAP_OPREGION 0
#define GVT_D_MAP_GSM 1

/*
 * Handler for passthru of igd
 *
 * Keep it as struct instead of a single function pointer, since new
 * generations of Intel graphics could need other funcs.
 * e.g. Intel Elkhartlake and Intel Tigerlake:
 * They will need different handling for GSM and Opregion (See ACRN-Hypervisor
 * <https://github.com/projectacrn/acrn-hypervisor/blob/master/devicemodel/hw/pci/passthrough.c>)
 */
struct igd_funcs {
	int (*is_igd_gen)(int devid);
	uint64_t (*get_gsm_len)(struct vmctx *ctx, struct pcisel *sel);
};

/* Handler for igd of gen5.75 (Westmere & Ironlake) */
IGD_FUNC_IS_IGD_GEN(5_75);

static uint64_t
igd_gen5_75_get_gsm_len(struct vmctx *ctx, struct pcisel *sel)
{
	uint16_t ggc_val = read_config(sel, PCIR_GGC, 2);
	uint8_t gms_val = (ggc_val & PCIM_GEN5_75_GGC_GMS_MASK) >>
	    4; /* Bits 7:4 contain Graphics Mode Select */
	switch (gms_val) {
	case 0x05:
		return 32 * MB;
	case 0x06:
		return 48 * MB;
	case 0x07:
		return 64 * MB;
	case 0x08:
		return 128 * MB;
	case 0x09:
		return 256 * MB;
	case 0x0A:
		return 96 * MB;
	case 0x0B:
		return 160 * MB;
	case 0x0C:
		return 224 * MB;
	case 0x0D:
		return 352 * MB;
	}

	warnx("Unknown Graphic Mode (%x)", gms_val);
	return 0;
}

/* Handler for igd of gen6 (Sandy Bridge) */
IGD_FUNC_IS_IGD_GEN(6);

static uint64_t
igd_gen6_get_gsm_len(struct vmctx *ctx, struct pcisel *sel)
{
	uint16_t ggc_val = read_config(sel, PCIR_GGC, 2);
	uint8_t gms_val = (ggc_val & PCIM_GEN6_GGC_GMS_MASK) >>
	    3; /* Bits 7:3 contain Graphics Mode Select */
	if (gms_val <= 0x10)
		return gms_val * 32 * MB;

	warnx("Unknown Graphic Mode (%x)", gms_val);
	return 0;
}

/* Handler for igd of gen7 (Ivy Bridge) */
IGD_FUNC_IS_IGD_GEN(7);

/* Handler for igd of gen7.5 (Haswell) */
IGD_FUNC_IS_IGD_GEN(7_5);

/* Handler for igd of gen8 (Broadwell) */
IGD_FUNC_IS_IGD_GEN(8);

static uint64_t
igd_gen8_get_gsm_len(struct vmctx *ctx, struct pcisel *sel)
{
	uint16_t ggc_val = read_config(sel, PCIR_GGC, 2);
	uint8_t gms_val = (ggc_val & PCIM_GEN8_GGC_GMS_MASK) >>
	    8; /* Bits 15:8 contain Graphics Mode Select */
	if ((gms_val <= 0x10) || (gms_val == 0x20) || (gms_val == 0x30) ||
	    (gms_val == 0x3F))
		return gms_val * 32 * MB;

	warnx("Unknown Graphic Mode (%x)", gms_val);
	return 0;
}

/* Handler for igd of gen9 (Skylake) */
IGD_FUNC_IS_IGD_GEN(9);

static uint64_t
igd_gen9_get_gsm_len(struct vmctx *ctx, struct pcisel *sel)
{
	uint16_t ggc_val = read_config(sel, PCIR_GGC, 2);
	uint8_t gms_val = (ggc_val & PCIM_GEN8_GGC_GMS_MASK) >>
	    8; /* Bits 15:8 contain Graphics Mode Select */
	if ((gms_val <= 0x10) || (gms_val == 0x20) || (gms_val == 0x30) ||
	    (gms_val == 0x40))
		return gms_val * 32 * MB;
	else if (gms_val >= 0xF0 && gms_val <= 0xFE)
		return gms_val * 4 * MB;

	warnx("Unknown Graphic Mode (%x)", gms_val);
	return 0;
}

/*
 * Handler for igd of gen9.5 (Kaby Lake & Whiskey Lake & Amber Lake & Coffee
 * Lake & Comet Lake)
 */
IGD_FUNC_IS_IGD_GEN(9_5);

/* Westmere & Ironlake */
static const struct igd_funcs igd_gen5_75 = {
	.is_igd_gen = igd_gen5_75_is_igd_gen,
	.get_gsm_len = igd_gen5_75_get_gsm_len
};
/* Sandy Bridge */
static const struct igd_funcs igd_gen6 = { .is_igd_gen = igd_gen6_is_igd_gen,
	.get_gsm_len = igd_gen6_get_gsm_len };
/* Ivy Bridge */
static const struct igd_funcs igd_gen7 = { .is_igd_gen = igd_gen7_is_igd_gen,
	.get_gsm_len = igd_gen6_get_gsm_len };
/* Haswell */
static const struct igd_funcs igd_gen7_5 = {
	.is_igd_gen = igd_gen7_5_is_igd_gen,
	.get_gsm_len = igd_gen6_get_gsm_len
};
/* Broadwell */
static const struct igd_funcs igd_gen8 = { .is_igd_gen = igd_gen8_is_igd_gen,
	.get_gsm_len = igd_gen8_get_gsm_len };
/* Skylake */
static const struct igd_funcs igd_gen9 = { .is_igd_gen = igd_gen9_is_igd_gen,
	.get_gsm_len = igd_gen9_get_gsm_len };
/* Kaby Lake & Whiskey Lake & Amber Lake & Coffee Lake & Comet Lake */
static const struct igd_funcs igd_gen9_5 = {
	.is_igd_gen = igd_gen9_5_is_igd_gen,
	.get_gsm_len = igd_gen9_get_gsm_len
};

static const struct igd_funcs *igd_gen_map[] = { &igd_gen5_75, &igd_gen6,
	&igd_gen7, &igd_gen7_5, &igd_gen8, &igd_gen9, &igd_gen9_5 };

static const struct igd_funcs *
get_igd_funcs(const uint16_t devid)
{
	for (int i = 0; i < sizeof(igd_gen_map) / sizeof(struct igd_funcs *);
	     ++i) {
		if (igd_gen_map[i]->is_igd_gen(devid))
			return igd_gen_map[i];
	}
	return NULL;
}

int
gvt_d_early_quirks(struct vmctx *ctx, struct pcisel *sel)
{
	/* Get IGD funcs */
	const uint16_t dev = read_config(sel, PCIR_DEVICE, 2);
	const struct igd_funcs *const igd = get_igd_funcs(dev);
	if (igd == NULL) {
		warnx("Unsupported igd-device (%x)", dev);
		return -ENODEV;
	}

	/* Get Graphics Stolen Memory len */
	const uint64_t gsm_len = igd->get_gsm_len(ctx, sel);
	/* Get Opregion length */
	const uint64_t opregion_len = GPU_OPREGION_LEN;

	pci_emul_adjust_gsmbase(ctx, gsm_len);
	pci_emul_adjust_gsmbase(ctx, opregion_len);

	return (0);
}

int
gvt_d_init(struct vmctx *ctx, struct pci_devinst *pi, nvlist_t *nvl)
{
	int error;
	struct passthru_softc *sc;

	sc = pi->pi_arg;

	/* check vendor == Intel */
	const uint16_t dev_vendor = read_config(&sc->psc_sel, PCIR_VENDOR, 2);
	if (dev_vendor != 0x8086) {
		warnx("Unknown vendor (%x) of igd", dev_vendor);
		return -ENODEV;
	}

	/* check if device is a display device */
	if (read_config(&sc->psc_sel, PCIR_CLASS, 1) != PCIC_DISPLAY) {
		warnx("%s is no display device", pi->pi_name);
		return -ENODEV;
	}

	/* Get IGD funcs */
	const struct igd_funcs *igd = get_igd_funcs(
	    read_config(&sc->psc_sel, PCIR_DEVICE, 2));
	if (igd == NULL) {
		warnx("Unsupported igd-device (%x)",
		    read_config(&sc->psc_sel, PCIR_DEVICE, 2));
		return -ENODEV;
	}

	struct passthru_mmio_mapping *opregion =
	    &sc->psc_mmio_map[GVT_D_MAP_OPREGION];
	struct passthru_mmio_mapping *gsm = &sc->psc_mmio_map[GVT_D_MAP_GSM];

	/* Get Opregion length */
	opregion->len = GPU_OPREGION_LEN;
	/* Get Opregion HPA */
	opregion->hpa = read_config(&sc->psc_sel, PCIR_ASLS_CTL, 4) &
	    PCIM_ASLS_OPREGION_MASK;
	/* Get Graphics Stolen Memory len */
	gsm->len = igd->get_gsm_len(ctx, &sc->psc_sel);
	/* Get Graphics Stolen Memory HPA */
	gsm->hpa = read_config(&sc->psc_sel, PCIR_BDSM, 4) & PCIM_BDSM_GSM_MASK;

	if (opregion->len == 0 || gsm->len == 0) {
		warnx("Could not determine size of opregion or gsm");
		return -ENODEV;
	}

	/* Allocate Opregion and GSM in guest space */
	gsm->gpa = pci_emul_alloc_gsm(gsm->len);
	opregion->gpa = pci_emul_alloc_gsm(opregion->len);
	if (opregion->gpa == 0 || gsm->gpa == 0) {
		error = -ENOMEM;
		goto failed_opregion;
	}

	/* Write address of Opregion and GSM into PCI register */
	/* Set Opregion GPA */
	uint32_t asls_val = read_config(&sc->psc_sel, PCIR_ASLS_CTL, 4);
	pci_set_cfgdata32(sc->psc_pi, PCIR_ASLS_CTL,
	    opregion->gpa | (asls_val & ~PCIM_ASLS_OPREGION_MASK));
	/* Set Graphics Stolen Memory GPA */
	uint32_t bdsm_val = read_config(&sc->psc_sel, PCIR_BDSM, 4);
	pci_set_cfgdata32(
	    sc->psc_pi, PCIR_BDSM, gsm->gpa | (bdsm_val & ~PCIM_BDSM_GSM_MASK));

	/* Map Opregion and GSM into guest space */
	if ((error = passthru_modify_pptdev_mmio(
		 ctx, sc, opregion, PT_MAP_PPTDEV_MMIO)) != 0)
		goto failed_opregion;
	if ((error = passthru_modify_pptdev_mmio(
		 ctx, sc, gsm, PT_MAP_PPTDEV_MMIO)) != 0)
		goto failed_gsm;

	/* Protect PCI register */
	set_pcir_prot(sc, PCIR_ASLS_CTL, 0x04, PPT_PCIR_PROT_NA);
	set_pcir_prot(sc, PCIR_BDSM, 0x04, PPT_PCIR_PROT_NA);

	return (0);

failed_opregion:
	opregion->gpa = 0;
failed_gsm:
	gsm->gpa = 0;
	return error;
}

void
gvt_d_deinit(struct vmctx *ctx, struct pci_devinst *pi)
{
	struct passthru_softc *sc;

	sc = pi->pi_arg;

	struct passthru_mmio_mapping *gsm = &sc->psc_mmio_map[GVT_D_MAP_GSM];
	struct passthru_mmio_mapping *opregion =
	    &sc->psc_mmio_map[GVT_D_MAP_OPREGION];

	/* GPA is only set, if it's initialized */
	if (gsm->gpa)
		passthru_modify_pptdev_mmio(ctx, sc, gsm, PT_UNMAP_PPTDEV_MMIO);
	if (opregion->gpa)
		passthru_modify_pptdev_mmio(
		    ctx, sc, opregion, PT_UNMAP_PPTDEV_MMIO);
}
