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
#include <sys/mman.h>

#include <machine/iodev.h>
#include <machine/vmm.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <unistd.h>

#include "config.h"
#include "debug.h"
#include "pci_passthru.h"

#define max(a, b) (((a) > (b)) ? (a) : (b))

static void
gvt_d_amd_usage(char *opt) {
	EPRINTLN("Invalid gvt-d amd passthru option \"%s\"", opt);
	EPRINTLN("passthru: {rom=rom_file}");
}

static int
gvt_d_amd_parse_opts(struct passthru_softc *sc, nvlist_t *nvl)
{
	const char *value;
	/* parse rom file */
	value = get_config_value_node(nvl, "rom");
	if (value != NULL) {
		const int fd = open(value, O_RDONLY);
		if (fd < 0) {
			return (-1);
		}
		/* determine file size */
		uint64_t bios_size = lseek(fd, 0, SEEK_END);
		lseek(fd, 0, SEEK_SET);
		/* read bios */
		void *bios_addr = malloc(bios_size);
		if (bios_addr == NULL) {
			close(fd);
			return (-ENOMEM);
		}
		bios_size = read(fd, bios_addr, bios_size);
		close(fd);

		/* save physical values of ROM */
		sc->psc_bar[PCI_ROM_IDX].type = PCIBAR_ROM;
		sc->psc_bar[PCI_ROM_IDX].addr = (uint64_t)bios_addr;
		sc->psc_bar[PCI_ROM_IDX].size = bios_size;
	}

	return (0);
}

int
gvt_d_amd_init(struct vmctx *ctx, struct pci_devinst *pi, nvlist_t *nvl)
{
	int error = 0;

	struct passthru_softc *sc = pi->pi_arg;

	if ((error = gvt_d_amd_parse_opts(sc, nvl)))
		goto done;

	const uint16_t vendor = read_config(&sc->psc_sel, PCIR_VENDOR, 0x02);
	const uint16_t dev_id = read_config(&sc->psc_sel, PCIR_DEVICE, 0x02);

	uint64_t bios_size;
	if (sc->psc_bar[PCI_ROM_IDX].size == 0) {
		/* get VBIOS size */
		if ((error = vm_get_vbios(ctx, sc->psc_sel.pc_bus,
			 sc->psc_sel.pc_dev, sc->psc_sel.pc_func, vendor,
			 dev_id, NULL, &bios_size)) != 0) {
			warnx("vm_get_vbios: %x", errno);
			goto done;
		}
	} else {
		bios_size = sc->psc_bar[PCI_ROM_IDX].size;
	}
	if (bios_size == 0) {
		error = ESRCH;
		warnx("Could not determine VBIOS size");
		goto done;
	}

	/*
	 * round up size to a power of two
	 * check in descendig order to avoid endless loop
	 */
	uint64_t rom_size = 1ULL << 63;
	while (rom_size >= bios_size) {
		rom_size >>= 1;
	}
	rom_size <<= 1;
	/* ROM size should be greater than 2 KB */
	rom_size = max(rom_size, (~PCIM_BIOS_ADDR_MASK) + 1);

	/* Allocate VM Memory for VBIOS */
	const uint64_t rom_addr = (uint64_t)vm_create_devmem(
	    ctx, VM_VIDEOBIOS, "videobios", rom_size);
	if ((void *)rom_addr == MAP_FAILED) {
		error = ENOMEM;
		warnx("vm_create_devmem: %x", errno);
		goto done;
	}

	/* get VBIOS */
	if (sc->psc_bar[PCI_ROM_IDX].addr == 0) {
		if ((error = vm_get_vbios(ctx, sc->psc_sel.pc_bus,
			 sc->psc_sel.pc_dev, sc->psc_sel.pc_func, vendor,
			 dev_id, (void *)rom_addr, &bios_size)) != 0) {
			warnx("vm_get_vbios: %x", errno);
			goto done;
		}
	} else {
		memcpy((void *)rom_addr, (void *)sc->psc_bar[PCI_ROM_IDX].addr,
		    bios_size);
		free((void *)sc->psc_bar[PCI_ROM_IDX].addr);
	}

	/* assign a ROM to this device */
	if ((error = pci_emul_alloc_bar(
		 pi, PCI_ROM_IDX, PCIBAR_ROM, rom_size)) != 0) {
		warnx("pci_emul_alloc_rom: %x", error);
		goto done;
	}

	/* save physical values of ROM */
	sc->psc_bar[PCI_ROM_IDX].type = PCIBAR_ROM;
	sc->psc_bar[PCI_ROM_IDX].addr = rom_addr;
	sc->psc_bar[PCI_ROM_IDX].size = bios_size;

done:
	return (error);
}

int
gvt_d_amd_addr_rom(struct pci_devinst *pi, int idx, int enabled)
{
	int error;

	if (!enabled)
		error = vm_munmap_memseg(
		    pi->pi_vmctx, pi->pi_bar[idx].addr, pi->pi_bar[idx].size);
	else
		error = vm_mmap_memseg(pi->pi_vmctx, pi->pi_bar[idx].addr,
		    VM_VIDEOBIOS, 0, pi->pi_bar[idx].size,
		    PROT_READ | PROT_EXEC);

	return error;
}
