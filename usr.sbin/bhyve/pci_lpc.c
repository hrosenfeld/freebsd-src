/*-
 * SPDX-License-Identifier: BSD-2-Clause-FreeBSD
 *
 * Copyright (c) 2013 Neel Natu <neel@freebsd.org>
 * Copyright (c) 2013 Tycho Nightingale <tycho.nightingale@pluribusnetworks.com>
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
 * THIS SOFTWARE IS PROVIDED BY NETAPP, INC ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL NETAPP, INC OR CONTRIBUTORS BE LIABLE
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
#include <sys/pciio.h>
#include <machine/vmm.h>
#include <machine/vmm_snapshot.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vmmapi.h>

#include "acpi.h"
#include "debug.h"
#include "bootrom.h"
#include "config.h"
#include "inout.h"
#include "pci_emul.h"
#include "pci_irq.h"
#include "pci_lpc.h"
#include "pctestdev.h"
#include "uart_emul.h"

#define	IO_ICU1		0x20
#define	IO_ICU2		0xA0

SET_DECLARE(lpc_dsdt_set, struct lpc_dsdt);
SET_DECLARE(lpc_sysres_set, struct lpc_sysres);

#define	ELCR_PORT	0x4d0
SYSRES_IO(ELCR_PORT, 2);

#define	IO_TIMER1_PORT	0x40

#define	NMISC_PORT	0x61
SYSRES_IO(NMISC_PORT, 1);

static struct pci_devinst *lpc_bridge;

#define	LPC_UART_NUM	4
static struct lpc_uart_softc {
	struct uart_softc *uart_softc;
	int	iobase;
	int	irq;
	int	enabled;
} lpc_uart_softc[LPC_UART_NUM];

static const char *lpc_uart_names[LPC_UART_NUM] = {
	"com1", "com2", "com3", "com4"
};

static const char *lpc_uart_acpi_names[LPC_UART_NUM] = {
	"COM1", "COM2", "COM3", "COM4"
};

#ifndef _PATH_DEVPCI
#define _PATH_DEVPCI "/dev/pci"
#endif

static int pcifd = -1;

static uint32_t
read_config(struct pcisel *sel, long reg, int width)
{
	struct pci_io pi;
	pi.pi_sel.pc_domain = sel->pc_domain;
	pi.pi_sel.pc_bus = sel->pc_bus;
	pi.pi_sel.pc_dev = sel->pc_dev;
	pi.pi_sel.pc_func = sel->pc_func;
	pi.pi_reg = reg;
	pi.pi_width = width;

	if (ioctl(pcifd, PCIOCREAD, &pi) < 0)
		return (0);

	return (pi.pi_data);
}

/*
 * LPC device configuration is in the following form:
 * <lpc_device_name>[,<options>]
 * For e.g. "com1,stdio" or "bootrom,/var/romfile"
 */
int
lpc_device_parse(const char *opts)
{
	int unit, error;
	char *str, *cpy, *lpcdev, *node_name;

	error = -1;
	str = cpy = strdup(opts);
	lpcdev = strsep(&str, ",");
	if (lpcdev != NULL) {
		if (strcasecmp(lpcdev, "bootrom") == 0) {
			set_config_value("lpc.bootrom", str);
			error = 0;
			goto done;
		}
		for (unit = 0; unit < LPC_UART_NUM; unit++) {
			if (strcasecmp(lpcdev, lpc_uart_names[unit]) == 0) {
				asprintf(&node_name, "lpc.%s.path",
				    lpc_uart_names[unit]);
				set_config_value(node_name, str);
				free(node_name);
				error = 0;
				goto done;
			}
		}
		if (strcasecmp(lpcdev, pctestdev_getname()) == 0) {
			asprintf(&node_name, "lpc.%s", pctestdev_getname());
			set_config_bool(node_name, true);
			free(node_name);
			error = 0;
			goto done;
		}
	}

done:
	free(cpy);

	return (error);
}

void
lpc_print_supported_devices()
{
	size_t i;

	printf("bootrom\n");
	for (i = 0; i < LPC_UART_NUM; i++)
		printf("%s\n", lpc_uart_names[i]);
	printf("%s\n", pctestdev_getname());
}

const char *
lpc_bootrom(void)
{

	return (get_config_value("lpc.bootrom"));
}

static void
lpc_uart_intr_assert(void *arg)
{
	struct lpc_uart_softc *sc = arg;

	assert(sc->irq >= 0);

	vm_isa_pulse_irq(lpc_bridge->pi_vmctx, sc->irq, sc->irq);
}

static void
lpc_uart_intr_deassert(void *arg)
{
	/* 
	 * The COM devices on the LPC bus generate edge triggered interrupts,
	 * so nothing more to do here.
	 */
}

static int
lpc_uart_io_handler(struct vmctx *ctx, int vcpu, int in, int port, int bytes,
		    uint32_t *eax, void *arg)
{
	int offset;
	struct lpc_uart_softc *sc = arg;

	offset = port - sc->iobase;

	switch (bytes) {
	case 1:
		if (in)
			*eax = uart_read(sc->uart_softc, offset);
		else
			uart_write(sc->uart_softc, offset, *eax);
		break;
	case 2:
		if (in) {
			*eax = uart_read(sc->uart_softc, offset);
			*eax |= uart_read(sc->uart_softc, offset + 1) << 8;
		} else {
			uart_write(sc->uart_softc, offset, *eax);
			uart_write(sc->uart_softc, offset + 1, *eax >> 8);
		}
		break;
	default:
		return (-1);
	}

	return (0);
}

static int
lpc_init(struct vmctx *ctx)
{
	struct lpc_uart_softc *sc;
	struct inout_port iop;
	const char *backend, *name, *romfile;
	char *node_name;
	int unit, error;

	romfile = get_config_value("lpc.bootrom");
	if (romfile != NULL) {
		error = bootrom_loadrom(ctx, romfile);
		if (error)
			return (error);
	}

	/* COM1 and COM2 */
	for (unit = 0; unit < LPC_UART_NUM; unit++) {
		sc = &lpc_uart_softc[unit];
		name = lpc_uart_names[unit];

		if (uart_legacy_alloc(unit, &sc->iobase, &sc->irq) != 0) {
			EPRINTLN("Unable to allocate resources for "
			    "LPC device %s", name);
			return (-1);
		}
		pci_irq_reserve(sc->irq);

		sc->uart_softc = uart_init(lpc_uart_intr_assert,
				    lpc_uart_intr_deassert, sc);

		asprintf(&node_name, "lpc.%s.path", name);
		backend = get_config_value(node_name);
		free(node_name);
		if (uart_set_backend(sc->uart_softc, backend) != 0) {
			EPRINTLN("Unable to initialize backend '%s' "
			    "for LPC device %s", backend, name);
			return (-1);
		}

		bzero(&iop, sizeof(struct inout_port));
		iop.name = name;
		iop.port = sc->iobase;
		iop.size = UART_IO_BAR_SIZE;
		iop.flags = IOPORT_F_INOUT;
		iop.handler = lpc_uart_io_handler;
		iop.arg = sc;

		error = register_inout(&iop);
		assert(error == 0);
		sc->enabled = 1;
	}

	/* pc-testdev */
	asprintf(&node_name, "lpc.%s", pctestdev_getname());
	if (get_config_bool_default(node_name, false)) {
		error = pctestdev_init(ctx);
		if (error)
			return (error);
	}
	free(node_name);

	return (0);
}

static void
pci_lpc_write_dsdt(struct pci_devinst *pi)
{
	struct lpc_dsdt **ldpp, *ldp;

	dsdt_line("");
	dsdt_line("Device (ISA)");
	dsdt_line("{");
	dsdt_line("  Name (_ADR, 0x%04X%04X)", pi->pi_slot, pi->pi_func);
	dsdt_line("  OperationRegion (LPCR, PCI_Config, 0x00, 0x100)");
	dsdt_line("  Field (LPCR, AnyAcc, NoLock, Preserve)");
	dsdt_line("  {");
	dsdt_line("    Offset (0x60),");
	dsdt_line("    PIRA,   8,");
	dsdt_line("    PIRB,   8,");
	dsdt_line("    PIRC,   8,");
	dsdt_line("    PIRD,   8,");
	dsdt_line("    Offset (0x68),");
	dsdt_line("    PIRE,   8,");
	dsdt_line("    PIRF,   8,");
	dsdt_line("    PIRG,   8,");
	dsdt_line("    PIRH,   8");
	dsdt_line("  }");
	dsdt_line("");

	dsdt_indent(1);
	SET_FOREACH(ldpp, lpc_dsdt_set) {
		ldp = *ldpp;
		ldp->handler();
	}

	dsdt_line("");
	dsdt_line("Device (PIC)");
	dsdt_line("{");
	dsdt_line("  Name (_HID, EisaId (\"PNP0000\"))");
	dsdt_line("  Name (_CRS, ResourceTemplate ()");
	dsdt_line("  {");
	dsdt_indent(2);
	dsdt_fixed_ioport(IO_ICU1, 2);
	dsdt_fixed_ioport(IO_ICU2, 2);
	dsdt_fixed_irq(2);
	dsdt_unindent(2);
	dsdt_line("  })");
	dsdt_line("}");

	dsdt_line("");
	dsdt_line("Device (TIMR)");
	dsdt_line("{");
	dsdt_line("  Name (_HID, EisaId (\"PNP0100\"))");
	dsdt_line("  Name (_CRS, ResourceTemplate ()");
	dsdt_line("  {");
	dsdt_indent(2);
	dsdt_fixed_ioport(IO_TIMER1_PORT, 4);
	dsdt_fixed_irq(0);
	dsdt_unindent(2);
	dsdt_line("  })");
	dsdt_line("}");
	dsdt_unindent(1);

	dsdt_line("}");
}

static void
pci_lpc_sysres_dsdt(void)
{
	struct lpc_sysres **lspp, *lsp;

	dsdt_line("");
	dsdt_line("Device (SIO)");
	dsdt_line("{");
	dsdt_line("  Name (_HID, EisaId (\"PNP0C02\"))");
	dsdt_line("  Name (_CRS, ResourceTemplate ()");
	dsdt_line("  {");

	dsdt_indent(2);
	SET_FOREACH(lspp, lpc_sysres_set) {
		lsp = *lspp;
		switch (lsp->type) {
		case LPC_SYSRES_IO:
			dsdt_fixed_ioport(lsp->base, lsp->length);
			break;
		case LPC_SYSRES_MEM:
			dsdt_fixed_mem32(lsp->base, lsp->length);
			break;
		}
	}
	dsdt_unindent(2);

	dsdt_line("  })");
	dsdt_line("}");
}
LPC_DSDT(pci_lpc_sysres_dsdt);

static void
pci_lpc_uart_dsdt(void)
{
	struct lpc_uart_softc *sc;
	int unit;

	for (unit = 0; unit < LPC_UART_NUM; unit++) {
		sc = &lpc_uart_softc[unit];
		if (!sc->enabled)
			continue;
		dsdt_line("");
		dsdt_line("Device (%s)", lpc_uart_acpi_names[unit]);
		dsdt_line("{");
		dsdt_line("  Name (_HID, EisaId (\"PNP0501\"))");
		dsdt_line("  Name (_UID, %d)", unit + 1);
		dsdt_line("  Name (_CRS, ResourceTemplate ()");
		dsdt_line("  {");
		dsdt_indent(2);
		dsdt_fixed_ioport(sc->iobase, UART_IO_BAR_SIZE);
		dsdt_fixed_irq(sc->irq);
		dsdt_unindent(2);
		dsdt_line("  })");
		dsdt_line("}");
	}
}
LPC_DSDT(pci_lpc_uart_dsdt);

static int
pci_lpc_cfgwrite(struct vmctx *ctx, int vcpu, struct pci_devinst *pi,
		  int coff, int bytes, uint32_t val)
{
	int pirq_pin;

	if (bytes == 1) {
		pirq_pin = 0;
		if (coff >= 0x60 && coff <= 0x63)
			pirq_pin = coff - 0x60 + 1;
		if (coff >= 0x68 && coff <= 0x6b)
			pirq_pin = coff - 0x68 + 5;
		if (pirq_pin != 0) {
			pirq_write(ctx, pirq_pin, val);
			pci_set_cfgdata8(pi, coff, pirq_read(pirq_pin));
			return (0);
		}
	}
	return (-1);
}

static void
pci_lpc_write(struct vmctx *ctx, int vcpu, struct pci_devinst *pi,
	       int baridx, uint64_t offset, int size, uint64_t value)
{
}

static uint64_t
pci_lpc_read(struct vmctx *ctx, int vcpu, struct pci_devinst *pi,
	      int baridx, uint64_t offset, int size)
{
	return (0);
}

#define	LPC_DEV		0x7000
#define	LPC_VENDOR	0x8086

static int
pci_lpc_init(struct vmctx *ctx, struct pci_devinst *pi, nvlist_t *nvl)
{
        /* on Intel systems lpc is always connected to 0:1f.0 */
        struct pcisel sel = {
                .pc_domain = 0,
                .pc_bus = 0,
                .pc_dev = 0x1f,
                .pc_func = 0
        };

	/*
	 * Do not allow more than one LPC bridge to be configured.
	 */
	if (lpc_bridge != NULL) {
		EPRINTLN("Only one LPC bridge is allowed.");
		return (-1);
	}

	/*
	 * Enforce that the LPC can only be configured on bus 0. This
	 * simplifies the ACPI DSDT because it can provide a decode for
	 * all legacy i/o ports behind bus 0.
	 */
	if (pi->pi_bus != 0) {
		EPRINTLN("LPC bridge can be present only on bus 0.");
		return (-1);
	}

	if (lpc_init(ctx) != 0)
		return (-1);

	/* initialize config space */
	pci_set_cfgdata16(pi, PCIR_DEVICE, LPC_DEV);
	pci_set_cfgdata16(pi, PCIR_VENDOR, LPC_VENDOR);
	pci_set_cfgdata8(pi, PCIR_CLASS, PCIC_BRIDGE);
	pci_set_cfgdata8(pi, PCIR_SUBCLASS, PCIS_BRIDGE_ISA);

	/* open host device */
	if (pcifd < 0) {
		pcifd = open(_PATH_DEVPCI, O_RDWR, 0);
		if (pcifd < 0) {
			warn("failed to open %s", _PATH_DEVPCI);
			return (-1);
		}
	}

	if (read_config(&sel, PCIR_VENDOR, 2) == PCI_VENDOR_INTEL) {
		/*
		 * The VID, DID, REVID, SUBVID and SUBDID of igd-lpc need to be
		 * aligned with the physical ones. Without these physical
		 * values, GVT-d GOP driver couldn't work.
		 */
		pci_set_cfgdata16(
		    pi, PCIR_DEVICE, read_config(&sel, PCIR_DEVICE, 2));
		pci_set_cfgdata16(
		    pi, PCIR_VENDOR, read_config(&sel, PCIR_VENDOR, 2));
		pci_set_cfgdata8(
		    pi, PCIR_REVID, read_config(&sel, PCIR_REVID, 1));
		pci_set_cfgdata16(
		    pi, PCIR_SUBVEND_0, read_config(&sel, PCIR_SUBVEND_0, 2));
		pci_set_cfgdata16(
		    pi, PCIR_SUBDEV_0, read_config(&sel, PCIR_SUBDEV_0, 2));
	}

	lpc_bridge = pi;

	return (0);
}

char *
lpc_pirq_name(int pin)
{
	char *name;

	if (lpc_bridge == NULL)
		return (NULL);
	asprintf(&name, "\\_SB.PC00.ISA.LNK%c,", 'A' + pin - 1);
	return (name);
}

void
lpc_pirq_routed(void)
{
	int pin;

	if (lpc_bridge == NULL)
		return;

 	for (pin = 0; pin < 4; pin++)
		pci_set_cfgdata8(lpc_bridge, 0x60 + pin, pirq_read(pin + 1));
	for (pin = 0; pin < 4; pin++)
		pci_set_cfgdata8(lpc_bridge, 0x68 + pin, pirq_read(pin + 5));
}

#ifdef BHYVE_SNAPSHOT
static int
pci_lpc_snapshot(struct vm_snapshot_meta *meta)
{
	int unit, ret;
	struct uart_softc *sc;

	for (unit = 0; unit < LPC_UART_NUM; unit++) {
		sc = lpc_uart_softc[unit].uart_softc;

		ret = uart_snapshot(sc, meta);
		if (ret != 0)
			goto done;
	}

done:
	return (ret);
}
#endif

struct pci_devemu pci_de_lpc = {
	.pe_emu =	"lpc",
	.pe_init =	pci_lpc_init,
	.pe_write_dsdt = pci_lpc_write_dsdt,
	.pe_cfgwrite =	pci_lpc_cfgwrite,
	.pe_barwrite =	pci_lpc_write,
	.pe_barread =	pci_lpc_read,
#ifdef BHYVE_SNAPSHOT
	.pe_snapshot =	pci_lpc_snapshot,
#endif
};
PCI_EMUL_SET(pci_de_lpc);
