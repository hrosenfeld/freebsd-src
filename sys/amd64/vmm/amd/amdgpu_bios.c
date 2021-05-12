/*
 * Copyright 2008 Advanced Micro Devices, Inc.
 * Copyright 2008 Red Hat Inc.
 * Copyright 2009 Jerome Glisse.
 * Copyright 2021 Beckhoff Automation GmbH & Co. KG
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 * Authors: Dave Airlie
 *          Alex Deucher
 *          Jerome Glisse
 */

/*
 * This file is a modified copy of <https://github.com/torvalds/linux/blob/bddbacc9e0373fc1f1f7963fa2a7838dd06e4b1b/drivers/gpu/drm/amd/amdgpu/amdgpu_bios.c>
 */

/* includes */
#include <sys/cdefs.h>
__FBSDID("$FreeBSD$");

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/sysctl.h>
#include <sys/malloc.h>

#include <dev/pci/pcivar.h>

#include "amdgpu_bios.h"
#include "atombios.h"
#include "contrib/dev/acpica/include/acpi.h"
#include "contrib/dev/acpica/include/acpixf.h"

/* type definitons */
#define __iomem
#define true 1
#define false 0
typedef uint32_t acpi_size;

/* log definitions */
#define DRM_ERROR	uprintf

#define	GFP_NATIVE_MASK	(M_NOWAIT | M_WAITOK | M_USE_RESERVE | M_ZERO)
#define	GFP_KERNEL	M_WAITOK
#define	__GFP_ZERO	M_ZERO
#define	kzalloc(size, flags)		kmalloc(size, (flags) | __GFP_ZERO)

#define	memcpy_fromio(a, b, c)	memcpy((a), (b), (c))

#define	acpi_get_table		AcpiGetTable

#define PCI_DEVFN(bus, slot, func)   ((((bus) & 0xff) << 8) | (((slot) & 0x1f) << 3) | ((func) & 0x07))
#define PCI_SLOT(devfn)		(((devfn) >> 3) & 0x1f)
#define PCI_FUNC(devfn)		((devfn) & 0x07)
#define	PCI_BUS_NUM(devfn)	(((devfn) >> 8) & 0xff)

MALLOC_DECLARE(M_VMMDEV);

typedef unsigned gfp_t;

static inline gfp_t
linux_check_m_flags(gfp_t flags)
{
	const gfp_t m = M_NOWAIT | M_WAITOK;

	/* make sure either M_NOWAIT or M_WAITOK is set */
	if ((flags & m) == 0)
		flags |= M_NOWAIT;
	else if ((flags & m) == m)
		flags &= ~M_WAITOK;

	/* mask away LinuxKPI specific flags */
	return (flags & GFP_NATIVE_MASK);
}

static inline void *
kmalloc(size_t size, gfp_t flags)
{
	return (malloc(size, M_VMMDEV, linux_check_m_flags(flags)));
}

static inline void
kfree(const void *ptr)
{
	free(__DECONST(void *, ptr), M_VMMDEV);
}

static inline void *
kmemdup(const void *src, size_t len, gfp_t gfp)
{
	void *dst;

	dst = kmalloc(len, gfp);
	if (dst != NULL) {
		memcpy(dst, src, len);
	}
	return (dst);
}

struct device {
	device_t	bsddev;
};

struct pci_dev {
	struct device	dev;
	uint16_t	device;
	uint16_t	vendor;
	unsigned int	devfn;
};
struct amdgpu_device {
	struct pci_dev	*pdev;
	uint8_t		*bios;
	uint32_t	bios_size;
};

/*
 * BIOS.
 */

#define AMD_VBIOS_SIGNATURE " 761295520"
#define AMD_VBIOS_SIGNATURE_OFFSET 0x30
#define AMD_VBIOS_SIGNATURE_SIZE sizeof(AMD_VBIOS_SIGNATURE)
#define AMD_VBIOS_SIGNATURE_END (AMD_VBIOS_SIGNATURE_OFFSET + AMD_VBIOS_SIGNATURE_SIZE)
#define AMD_IS_VALID_VBIOS(p) ((p)[0] == 0x55 && (p)[1] == 0xAA)
#define AMD_VBIOS_LENGTH(p) ((p)[2] << 9)

/* Check if current bios is an ATOM BIOS.
 * Return true if it is ATOM BIOS. Otherwise, return false.
 */
static bool check_atom_bios(uint8_t *bios, size_t size)
{
	uint16_t tmp, bios_header_start;

	if (!bios || size < 0x49) {
		return false;
	}

	if (!AMD_IS_VALID_VBIOS(bios)) {
		return false;
	}

	bios_header_start = bios[0x48] | (bios[0x49] << 8);
	if (!bios_header_start) {
		return false;
	}

	tmp = bios_header_start + 4;
	if (size < tmp) {
		return false;
	}

	if (!memcmp(bios + tmp, "ATOM", 4) ||
	    !memcmp(bios + tmp, "MOTA", 4)) {
		return true;
	}

	return false;
}

#define pci_map_rom(pdev, sizep)					\
	vga_pci_map_bios(pdev->dev.bsddev, sizep)
#define pci_unmap_rom(pdev, bios)					\
	vga_pci_unmap_bios(pdev->dev.bsddev, bios)

static
bool amdgpu_read_bios(struct amdgpu_device *adev)
{
	uint8_t __iomem *bios;
	size_t size;

	adev->bios = NULL;
	/* XXX: some cards may return 0 for rom size? ddx has a workaround */
	bios = pci_map_rom(adev->pdev, &size);
	if (!bios) {
		return false;
	}

	adev->bios = kzalloc(size, GFP_KERNEL);
	if (adev->bios == NULL) {
		pci_unmap_rom(adev->pdev, bios);
		return false;
	}
	adev->bios_size = size;
	memcpy_fromio(adev->bios, bios, size);
	pci_unmap_rom(adev->pdev, bios);

	if (!check_atom_bios(adev->bios, size)) {
		kfree(adev->bios);
		return false;
	}

	return true;
}

static bool amdgpu_acpi_vfct_bios(struct amdgpu_device *adev)
{
	struct acpi_table_header *hdr;
	acpi_size tbl_size;
	UEFI_ACPI_VFCT *vfct;
	unsigned offset;

	if (!ACPI_SUCCESS(acpi_get_table("VFCT", 1, &hdr)))
		return false;
	tbl_size = hdr->Length;
	if (tbl_size < sizeof(UEFI_ACPI_VFCT)) {
		DRM_ERROR("ACPI VFCT table present but broken (too short #1)\n");
		return false;
	}

	vfct = (UEFI_ACPI_VFCT *)hdr;
	offset = vfct->VBIOSImageOffset;

	while (offset < tbl_size) {
		GOP_VBIOS_CONTENT *vbios = (GOP_VBIOS_CONTENT *)((char *)hdr + offset);
		VFCT_IMAGE_HEADER *vhdr = &vbios->VbiosHeader;

		offset += sizeof(VFCT_IMAGE_HEADER);
		if (offset > tbl_size) {
			DRM_ERROR("ACPI VFCT image header truncated\n");
			return false;
		}

		offset += vhdr->ImageLength;
		if (offset > tbl_size) {
			DRM_ERROR("ACPI VFCT image truncated\n");
			return false;
		}

		if (vhdr->ImageLength &&
		    vhdr->PCIBus == PCI_BUS_NUM(adev->pdev->devfn) &&
		    vhdr->PCIDevice == PCI_SLOT(adev->pdev->devfn) &&
		    vhdr->PCIFunction == PCI_FUNC(adev->pdev->devfn) &&
		    vhdr->VendorID == adev->pdev->vendor &&
		    vhdr->DeviceID == adev->pdev->device) {
			adev->bios = kmemdup(&vbios->VbiosContent,
					     vhdr->ImageLength,
					     GFP_KERNEL);

			if (!check_atom_bios(adev->bios, vhdr->ImageLength)) {
				kfree(adev->bios);
				return false;
			}
			adev->bios_size = vhdr->ImageLength;
			return true;
		}
	}

	DRM_ERROR("ACPI VFCT table present but broken (too short #2)\n");
	return false;
}

static
bool amdgpu_get_bios(struct amdgpu_device *adev)
{
	if (amdgpu_acpi_vfct_bios(adev)) {
		goto success;
	}

	if (amdgpu_read_bios(adev)) {
		goto success;
	}

	DRM_ERROR("Unable to locate a BIOS ROM\n");
	return false;

success:
	return true;
}

int
vm_amdgpu_get_vbios(struct vm *vm, int bus, int slot, int func,
		    uint16_t vendor, uint16_t dev_id, void *bios, uint64_t *size)
{
	int error = 0;

	struct pci_dev pdev;
	struct amdgpu_device adev;

	adev.pdev = &pdev;
	pdev.dev.bsddev = pci_find_bsf(bus, slot, func);
	pdev.devfn = PCI_DEVFN(bus, slot, func);
	pdev.vendor = vendor;
	pdev.device = dev_id;

	if (!amdgpu_get_bios(&adev))
		return ENOENT;

	if (bios) {
		*size = min(adev.bios_size, *size);
		error = copyout(adev.bios, bios, *size);
	} else if (size) {
		*size = adev.bios_size;
	}

	kfree(adev.bios);

	return (error);
}
