/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 The FreeBSD Foundation
 * All rights reserved.
 *
 * This software was developed by Hans Rosenfeld under sponsorship from
 * the FreeBSD Foundation.
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
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <assert.h>
#include <err.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>

#include <sys/nv.h>
#include <sys/queue.h>
#include <sys/types.h>
#include <vmmapi.h>

#include <machine/vmm.h>
#include <machine/specialreg.h>

#include "config.h"
#include "cpuid.h"
#include "bhyverun.h"

#define	CPUID_TYPE_MASK		0xf0000000
#define	CPUID_TYPE_SHIFT	28
#define	CPUID_TYPE(x)		(((x) & CPUID_TYPE_MASK) >> CPUID_TYPE_SHIFT)
#define	CPUID_FUNC_MASK		0x0fffffff
#define	CPUID_HV_FUNC_MASK	0x000000ff

#define	CPUID_TYPE_STD		0x0
#define	CPUID_TYPE_HV		0x4
#define	CPUID_TYPE_EXTD		0x8

/*
 * CPUID instruction Fn0000_0001:
 */
#define	CPUID_0000_0001_APICID_SHIFT	24

static const char *bhyve_regs[] = { "EAX", "EBX", "ECX", "EDX" };

enum bhyve_cpu_vendor { VENDOR_UNKNOWN = -1, VENDOR_INTEL, VENDOR_AMD };

static struct bhyve_cpu_vendors {
	const char *bcv_alias;
	const char *bcv_ident;
} bhyve_cpu_vendors[] = {
	[VENDOR_INTEL] =	{ "intel",	"GenuineIntel" },
	[VENDOR_AMD] =		{ "amd",	"AuthenticAMD" },
};

static struct bhyve_hv_vendors {
	const char *bhv_alias;
	const char *bhv_ident;
} bhyve_hv_vendors[] = {
	{ "hyperv",	"Microsoft Hv" },
	{ "kvm",	"KVMKVMKVM" },
	{ "virtualbox",	"VBoxVBoxVBox" },
	{ "vmware",	"VMwareVMware" },
	{ "xen",	"XenVMMXenVMM" },
};

/*
 * CPUID action
 *
 * A CPUID action modifies a single register of a CPUID function/index
 * by applying the given value using the operator against the register.
 *
 * The CPUID actions are linked together in a queue, to applied in the order
 * they appear in the configuration. There is a global CPUID action queue to
 * be applied to all vCPUs. For each vCPU, a vCPU-specific CPUID action queue
 * is temporarily created for CPUID actions specific to the vCPU.
 */
enum bhyve_cpuid_op { CPUID_OP_SET, CPUID_OP_OR, CPUID_OP_AND };

struct bhyve_cpuid_action {
	STAILQ_ENTRY(bhyve_cpuid_action)	bca_link;
	uint32_t				bca_function;
	uint32_t				bca_index;
	enum vce_reg				bca_reg;
	uint32_t				bca_val;
	enum bhyve_cpuid_op			bca_op;
};

STAILQ_HEAD(bhyve_cpuid_action_queue, bhyve_cpuid_action);

/*
 * Special CPUID options of the form "cpuid.<option>=<value>"
 */
typedef int bhyve_set_cpuid_opt_t(const char *,
    struct bhyve_cpuid_action_queue *);

static bhyve_set_cpuid_opt_t bhyve_set_cpuid_brand;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_check;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_family;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_fallback_style;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_features;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_hypervisor;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_level;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_linear;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_model;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_physical;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_pkgtype;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_stepping;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_vendor;
static bhyve_set_cpuid_opt_t bhyve_set_cpuid_xlevel;

static const struct {
	const char		*opt_name;
	bhyve_set_cpuid_opt_t	*opt_func;
} bhyve_cpuid_options[] = {
	{ "brand", bhyve_set_cpuid_brand },
	{ "check", bhyve_set_cpuid_check },
	{ "fallback-style", bhyve_set_cpuid_fallback_style },
	{ "family", bhyve_set_cpuid_family },
	{ "features", bhyve_set_cpuid_features },
	{ "hypervisor", bhyve_set_cpuid_hypervisor },
	{ "level", bhyve_set_cpuid_level },
	{ "linear", bhyve_set_cpuid_linear },
	{ "model", bhyve_set_cpuid_model },
	{ "physical", bhyve_set_cpuid_physical },
	{ "pkgtype", bhyve_set_cpuid_pkgtype },
	{ "stepping", bhyve_set_cpuid_stepping },
	{ "vendor", bhyve_set_cpuid_vendor },
	{ "xlevel", bhyve_set_cpuid_xlevel },
};

#define	CPUID_LEAF		0x00000001
#define	CPUID_IDX		0
#define	CPUID_REG		VCE_REG_EDX
#define	CPUID2_LEAF		0x00000001
#define	CPUID2_IDX		0
#define	CPUID2_REG		VCE_REG_ECX

#define	CPUTPM1_LEAF		0x00000006
#define	CPUTPM1_IDX		0
#define	CPUTPM1_REG		VCE_REG_EAX

#define	CPUID_STDEXT_LEAF	0x00000007
#define	CPUID_STDEXT_IDX	0
#define	CPUID_STDEXT_REG	VCE_REG_EBX
#define	CPUID_STDEXT2_LEAF	0x00000007
#define	CPUID_STDEXT2_IDX	0
#define	CPUID_STDEXT2_REG	VCE_REG_ECX
#define	CPUID_STDEXT3_LEAF	0x00000007
#define	CPUID_STDEXT3_IDX	0
#define	CPUID_STDEXT3_REG	VCE_REG_EDX

#define	CPUID_EXTSTATE_LEAF	0x0000000d
#define	CPUID_EXTSTATE_IDX	1
#define	CPUID_EXTSTATE_REG	VCE_REG_EAX

#define	XFEATURE_ENABLED_LEAF	0x0000000d
#define	XFEATURE_ENABLED_IDX	0
#define	XFEATURE_ENABLED_REG	VCE_REG_EAX

#define	AMDID_LEAF		0x80000001
#define	AMDID_IDX		0
#define	AMDID_REG		VCE_REG_EDX
#define	AMDID2_LEAF		0x80000001
#define	AMDID2_IDX		0
#define	AMDID2_REG		VCE_REG_ECX

#define	AMDFEID_LEAF		0x80000008
#define	AMDFEID_IDX		0
#define	AMDFEID_REG		VCE_REG_EBX

#define	AMDPM_LEAF		0x80000007
#define	AMDPM_IDX		0
#define	AMDPM_REG		VCE_REG_EDX

#define	CPUID_CONCAT(x, y)	x ## y
#define	CPUID_STRINGIFY(x)	#x
#define	CPUID_FEATURE_NAME(sect, feat, name)			\
	{							\
		name,						\
		CPUID_CONCAT(sect, _LEAF),			\
		CPUID_CONCAT(sect, _IDX),			\
		CPUID_CONCAT(sect, _REG),			\
		CPUID_CONCAT(sect, _##feat)			\
	}
#define	CPUID_FEATURE(sect, feat)				\
	CPUID_FEATURE_NAME(sect, feat, CPUID_STRINGIFY(feat))


static const struct bhyve_cpuid_feature {
	const char	*bcf_name;
	uint32_t	bcf_func;
	uint32_t	bcf_idx;
	uint32_t	bcf_reg;
	uint32_t	bcf_bit;
} bhyve_cpuid_features[] = {
	CPUID_FEATURE(AMDID,		3DNOW),
	CPUID_FEATURE_NAME(AMDID,	EXT_3DNOW,	"3dnowx"),
	CPUID_FEATURE(AMDID2,		ABM),
	CPUID_FEATURE(CPUID,		ACPI),
	CPUID_FEATURE(CPUID_STDEXT,	ADX),
	CPUID_FEATURE(CPUID2,		AESNI),
	CPUID_FEATURE_NAME(AMDID2,	EXT_APIC,	"amd_apic"),
	CPUID_FEATURE_NAME(AMDFEID,	IBPB,		"amd_ibpb"),
	CPUID_FEATURE_NAME(AMDID,	EXT_MMX,	"amd_mmx"),
	CPUID_FEATURE(CPUID,		APIC),
	CPUID_FEATURE(CPUTPM1,		ARAT),
	CPUID_FEATURE(CPUID_STDEXT3,	ARCH_CAP),
	CPUID_FEATURE(CPUID2,		AVX),
	CPUID_FEATURE(CPUID_STDEXT,	AVX2),
	CPUID_FEATURE(CPUID_STDEXT3,	AVX5124FMAPS),
	CPUID_FEATURE(CPUID_STDEXT3,	AVX5124VNNIW),
	CPUID_FEATURE(CPUID_STDEXT2,	AVX512BITALG),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512BW),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512CD),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512DQ),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512ER),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512F),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512IFMA),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512PF),
	CPUID_FEATURE(CPUID_STDEXT2,	AVX512VBMI),
	CPUID_FEATURE(CPUID_STDEXT2,	AVX512VBMI2),
	CPUID_FEATURE(CPUID_STDEXT,	AVX512VL),
	CPUID_FEATURE(CPUID_STDEXT2,	AVX512VNNI),
	CPUID_FEATURE(CPUID_STDEXT3,	AVX512VP2INTERSECT),
	CPUID_FEATURE(CPUID_STDEXT2,	AVX512VPOPCNTDQ),
	CPUID_FEATURE(CPUID,		B10),
	CPUID_FEATURE(CPUID,		B20),
	CPUID_FEATURE(CPUID_STDEXT,	BMI1),
	CPUID_FEATURE(CPUID_STDEXT,	BMI2),
	CPUID_FEATURE(XFEATURE_ENABLED,	BNDCSR),
	CPUID_FEATURE(XFEATURE_ENABLED,	BNDREGS),
	CPUID_FEATURE(CPUID_STDEXT2,	CLDEMOTE),
	CPUID_FEATURE(CPUID_STDEXT,	CLFLUSHOPT),
	CPUID_FEATURE(CPUID,		CLFSH),
	CPUID_FEATURE(CPUID_STDEXT,	CLWB),
	CPUID_FEATURE(CPUID,		CMOV),
	CPUID_FEATURE(AMDID2,		CMP),
	CPUID_FEATURE(CPUID2,		CNXTID),
	CPUID_FEATURE(CPUID_STDEXT3,	CORE_CAP),
	CPUID_FEATURE(AMDID2,		CR8),
	CPUID_FEATURE(CPUID2,		CX16),
	CPUID_FEATURE(CPUID,		CX8),
	CPUID_FEATURE(AMDID2,		DBE),
	CPUID_FEATURE(CPUID2,		DCA),
	CPUID_FEATURE(CPUID,		DE),
	CPUID_FEATURE(CPUID,		DS),
	CPUID_FEATURE(CPUID2,		DS_CPL),
	CPUID_FEATURE(CPUID2,		DTES64),
	CPUID_FEATURE(CPUID_STDEXT2,	ENQCMD),
	CPUID_FEATURE(CPUID_STDEXT,	ERMS),
	CPUID_FEATURE(CPUID2,		EST),
	CPUID_FEATURE(CPUID2,		F16C),
	CPUID_FEATURE(CPUID_STDEXT,	FDP_EXC),
	CPUID_FEATURE(AMDID,		FFXSR),
	CPUID_FEATURE(CPUID2,		FMA),
	CPUID_FEATURE(AMDID2,		FMA4),
	CPUID_FEATURE(CPUID,		FPU),
	CPUID_FEATURE(CPUID_STDEXT,	FSGSBASE),
	CPUID_FEATURE(CPUID_STDEXT3,	FSRM),
	CPUID_FEATURE(CPUID,		FXSR),
	CPUID_FEATURE(CPUID_STDEXT2,	GFNI),
	CPUID_FEATURE(XFEATURE_ENABLED,	HI16_ZMM),
	CPUID_FEATURE(CPUID_STDEXT,	HLE),
	CPUID_FEATURE(CPUID,		HTT),
	CPUID_FEATURE(CPUID2,		HV),
	CPUID_FEATURE(CPUID,		IA64),
	CPUID_FEATURE(AMDID2,		IBS),
	CPUID_FEATURE_NAME(CPUID_STDEXT3, IBPB,		"intel_ibpb"),
	CPUID_FEATURE(CPUID_STDEXT,	INVPCID),
	CPUID_FEATURE(CPUID_STDEXT3,	L1D_FLUSH),
	CPUID_FEATURE(CPUID_STDEXT2,	LA57),
	CPUID_FEATURE(AMDID2,		LAHF),
	CPUID_FEATURE(AMDID,		LM),
	CPUID_FEATURE(AMDID2,		LWP),
	CPUID_FEATURE(AMDID2,		MAS),
	CPUID_FEATURE(CPUID,		MCA),
	CPUID_FEATURE(CPUID,		MCE),
	CPUID_FEATURE(CPUID_STDEXT3,	MCUOPT),
	CPUID_FEATURE(CPUID_STDEXT3,	MD_CLEAR),
	CPUID_FEATURE(CPUID,		MMX),
	CPUID_FEATURE(CPUID2,		MON),
	CPUID_FEATURE(CPUID2,		MOVBE),
	CPUID_FEATURE(CPUID_STDEXT2,	MOVDIR64B),
	CPUID_FEATURE(CPUID_STDEXT2,	MOVDIRI),
	CPUID_FEATURE(AMDID,		MP),
	CPUID_FEATURE(CPUID_STDEXT,	MPX),
	CPUID_FEATURE(CPUID,		MSR),
	CPUID_FEATURE(CPUID,		MTRR),
	CPUID_FEATURE(AMDID2,		MWAITX),
	CPUID_FEATURE(CPUID_STDEXT,	NFPUSG),
	CPUID_FEATURE(AMDID2,		NODE_ID),
	CPUID_FEATURE(AMDID,		NX),
	CPUID_FEATURE(XFEATURE_ENABLED,	OPMASK),
	CPUID_FEATURE(CPUID_STDEXT2,	OSPKE),
	CPUID_FEATURE(AMDID2,		OSVW),
	CPUID_FEATURE(CPUID2,		OSXSAVE),
	CPUID_FEATURE(CPUID,		PAE),
	CPUID_FEATURE(AMDID,		PAGE1GB),
	CPUID_FEATURE(CPUID,		PAT),
	CPUID_FEATURE(CPUID,		PBE),
	CPUID_FEATURE(CPUID2,		PCID),
	CPUID_FEATURE(CPUID2,		PCLMULQDQ),
	CPUID_FEATURE(CPUID_STDEXT3,	PCONFIG),
	CPUID_FEATURE(AMDID2,		PCXC),
	CPUID_FEATURE(CPUID2,		PDCM),
	CPUID_FEATURE(CPUID,		PGE),
	CPUID_FEATURE(CPUID_STDEXT2,	PKU),
	CPUID_FEATURE(AMDID2,		PNXC),
	CPUID_FEATURE(CPUID2,		POPCNT),
	CPUID_FEATURE(CPUID_STDEXT,	PQE),
	CPUID_FEATURE(CPUID_STDEXT,	PQM),
	CPUID_FEATURE(AMDID2,		PREFETCH),
	CPUID_FEATURE(CPUID_STDEXT2,	PREFETCHWT1),
	CPUID_FEATURE(CPUID_STDEXT,	PROCTRACE),
	CPUID_FEATURE(CPUID,		PSE),
	CPUID_FEATURE(CPUID,		PSE36),
	CPUID_FEATURE(CPUID,		PSN),
	CPUID_FEATURE(AMDID2,		PTSC),
	CPUID_FEATURE(AMDID2,		PTSCEL2I),
	CPUID_FEATURE(CPUID_STDEXT2,	RDPID),
	CPUID_FEATURE(CPUID2,		RDRAND),
	CPUID_FEATURE(CPUID_STDEXT,	RDSEED),
	CPUID_FEATURE(AMDID,		RDTSCP),
	CPUID_FEATURE(CPUID_STDEXT,	RTM),
	CPUID_FEATURE(CPUID2,		SDBG),
	CPUID_FEATURE(CPUID,		SEP),
	CPUID_FEATURE(CPUID_STDEXT,	SGX),
	CPUID_FEATURE(CPUID_STDEXT2,	SGXLC),
	CPUID_FEATURE(CPUID_STDEXT,	SHA),
	CPUID_FEATURE(AMDID2,		SKINIT),
	CPUID_FEATURE(CPUID_STDEXT,	SMAP),
	CPUID_FEATURE(CPUID_STDEXT,	SMEP),
	CPUID_FEATURE(CPUID2,		SMX),
	CPUID_FEATURE(CPUID,		SS),
	CPUID_FEATURE(CPUID_STDEXT3,	SSBD),
	CPUID_FEATURE(CPUID,		SSE), /* XMM */
	CPUID_FEATURE(CPUID,		SSE2),
	CPUID_FEATURE(CPUID2,		SSE3),
	CPUID_FEATURE_NAME(CPUID2,	SSE41, "sse4.1"),
	CPUID_FEATURE_NAME(CPUID2,	SSE42, "sse4.2"),
	CPUID_FEATURE(AMDID2,		SSE4A),
	CPUID_FEATURE(CPUID2,		SSSE3),
	CPUID_FEATURE(CPUID_STDEXT3,	STIBP),
	CPUID_FEATURE(AMDID2,		SVM),
	CPUID_FEATURE(AMDID,		SYSCALL),
	CPUID_FEATURE(AMDID2,		TBM),
	CPUID_FEATURE(AMDID2,		TCE),
	CPUID_FEATURE(CPUID,		TM),
	CPUID_FEATURE(CPUID2,		TM2),
	CPUID_FEATURE(CPUID_STDEXT2,	TME),
	CPUID_FEATURE(AMDID2,		TOPOLOGY),
	CPUID_FEATURE(CPUID,		TSC),
	CPUID_FEATURE(CPUID_STDEXT,	TSC_ADJUST),
	CPUID_FEATURE(AMDPM,		TSC_INVARIANT),
	CPUID_FEATURE(CPUID2,		TSCDLT),
	CPUID_FEATURE(CPUID_STDEXT3,	TSXFA),
	CPUID_FEATURE(CPUID_STDEXT2,	UMIP),
	CPUID_FEATURE(CPUID_STDEXT2,	VAES),
	CPUID_FEATURE(CPUID,		VME),
	CPUID_FEATURE(CPUID2,		VMX),
	CPUID_FEATURE(CPUID_STDEXT2,	VPCLMULQDQ),
	CPUID_FEATURE(CPUID_STDEXT2,	WAITPKG),
	CPUID_FEATURE(AMDFEID,		WBNOINVD),
	CPUID_FEATURE(AMDID2,		WDT),
	CPUID_FEATURE(CPUID2,		X2APIC),
	CPUID_FEATURE(XFEATURE_ENABLED,	X87),
	CPUID_FEATURE(CPUID_EXTSTATE,	XINUSE),
	CPUID_FEATURE(XFEATURE_ENABLED,	XMM),
	CPUID_FEATURE(AMDID2,		XOP),
	CPUID_FEATURE(CPUID2,		XSAVE),
	CPUID_FEATURE(CPUID_EXTSTATE,	XSAVEC),
	CPUID_FEATURE(CPUID_EXTSTATE,	XSAVEOPT),
	CPUID_FEATURE(CPUID_EXTSTATE,	XSAVES),
	CPUID_FEATURE(CPUID2,		XTPR),
	CPUID_FEATURE(XFEATURE_ENABLED,	YMM_HI128),
	CPUID_FEATURE(XFEATURE_ENABLED,	ZMM_HI256),
};

/*
 * CPUID data validity checks
 *
 * We define several bitmasks for each CPUID constraint:
 * - immutable, bits which may not be changed at all
 *   (e.g. CPU Vendor Identification)
 * - clear only, bits which may only cleared
 *   (e.g. CPU features which aren't emulated)
 * - lower only, the numerical value of the bits may
 *   only be lowered (e.g. address space bits)
 *
 * The array must be sorted by function, index, and register.
 */
static const struct bhyve_cpuid_constraint {
	uint32_t	bcc_function;
	int32_t		bcc_index;
	enum vce_reg	bcc_reg;
	uint32_t	bcc_immutable;
	uint32_t	bcc_clear;
	uint32_t	bcc_lower;
} bhyve_cpuid_constraints[] = {
	/* 0x00000000, ebx, ecx, edx: Vendor Identification */
	{ 0x00000000, -1, VCE_REG_EBX, 0xffffffff, 0, 0 },
	{ 0x00000000, -1, VCE_REG_ECX, 0xffffffff, 0, 0 },
	{ 0x00000000, -1, VCE_REG_EDX, 0xffffffff, 0, 0 },

	/*
	 * 0x00000001, ebx: Topology
	 */
	{ 0x00000001, -1, VCE_REG_EBX, 0xffffff00, 0, 0 },

	/*
	 * 0x00000001, ecx: Standard Features
	 * v2: SSE3, SSSE3, CX16, SSE41, SSE42, POPCNT
	 * v3: FMA, MOVBE, OSXSAVE, AVX, F16C
	 * vmm masked: VMX, EST, TM2, SMX, X2APIC, MON, PDCM, TSCDLT
	 */
	{
		.bcc_function = 0x00000001,
		.bcc_index = -1,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = (CPUID2_VMX | CPUID2_EST | CPUID2_TM2 |
		    CPUID2_SMX | CPUID2_X2APIC | CPUID2_MON | CPUID2_PDCM |
		    CPUID2_TSCDLT),
		.bcc_clear = (CPUID2_SSE3 | CPUID2_SSSE3 | CPUID2_SSE41 |
		    CPUID2_SSE42 | CPUID2_POPCNT | CPUID2_FMA | CPUID2_MOVBE |
		    CPUID2_OSXSAVE | CPUID2_AVX | CPUID2_F16C | CPUID2_RDRAND),
		.bcc_lower = 0,
	},

	/*
	 * 0x00000001, edx: Standard Features
	 * v1: FPU, CX8, CMOV, MMX, FXSR, SSE, SSE2
	 * vmm masked: ACPI, TM, DS
	 * vmm set: HTT
	 */
	{
		.bcc_function = 0x00000001,
		.bcc_index = -1,
		.bcc_reg = VCE_REG_EDX,
		.bcc_immutable = (CPUID_ACPI | CPUID_TM | CPUID_DS),
		.bcc_clear = (CPUID_FPU | CPUID_CX8 | CPUID_CMOV | CPUID_MMX |
		    CPUID_FXSR | CPUID_SSE | CPUID_SSE2 | CPUID_HTT),
		.bcc_lower = 0,
	},

	/* 0x00000004: Cache Topology */
	{ 0x00000004, -1, VCE_REG_EAX, 0xfffffc00, 0, 0 },
	{ 0x00000004, -1, VCE_REG_EBX, 0x0000ffff, 0, 0xffc00000 },
	{ 0x00000004, -1, VCE_REG_EBX, 0x0000ffff, 0, 0x003f0000 },
	{ 0x00000004, -1, VCE_REG_ECX, 0, 0, 0xffffffff },

	/* 0x00000005: Monitor/MWAIT */
	{ 0x00000005, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x00000006: Thermal and Power Management */
	{ 0x00000006, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x00000007, 0x00: Structured Extended Features */
	{ 0x00000007, 0x00, VCE_REG_EAX, 0xffffffff, 0, 0 },
	{
		.bcc_function = 0x00000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EBX,
		.bcc_immutable = ~(CPUID_STDEXT_FSGSBASE | CPUID_STDEXT_BMI1 |
		    CPUID_STDEXT_HLE | CPUID_STDEXT_AVX2 | CPUID_STDEXT_SMEP |
		    CPUID_STDEXT_BMI2 | CPUID_STDEXT_ERMS |
		    CPUID_STDEXT_INVPCID | CPUID_STDEXT_RTM |
		    CPUID_STDEXT_AVX512F | CPUID_STDEXT_AVX512DQ |
		    CPUID_STDEXT_RDSEED | CPUID_STDEXT_SMAP |
		    CPUID_STDEXT_AVX512PF | CPUID_STDEXT_AVX512ER |
		    CPUID_STDEXT_AVX512CD | CPUID_STDEXT_SHA |
		    CPUID_STDEXT_AVX512BW | CPUID_STDEXT_AVX512VL),
		.bcc_clear = (CPUID_STDEXT_FSGSBASE | CPUID_STDEXT_BMI1 |
		    CPUID_STDEXT_HLE | CPUID_STDEXT_AVX2 | CPUID_STDEXT_SMEP |
		    CPUID_STDEXT_BMI2 | CPUID_STDEXT_ERMS |
		    CPUID_STDEXT_INVPCID | CPUID_STDEXT_RTM |
		    CPUID_STDEXT_AVX512F | CPUID_STDEXT_AVX512DQ |
		    CPUID_STDEXT_RDSEED | CPUID_STDEXT_SMAP |
		    CPUID_STDEXT_AVX512PF | CPUID_STDEXT_AVX512ER |
		    CPUID_STDEXT_AVX512CD | CPUID_STDEXT_SHA |
		    CPUID_STDEXT_AVX512BW | CPUID_STDEXT_AVX512VL),
		.bcc_lower = 0,
	},
	{
		.bcc_function = 0x00000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = ~(CPUID_STDEXT2_AVX512VBMI |
		    CPUID_STDEXT2_AVX512VBMI2 | CPUID_STDEXT2_VAES |
		    CPUID_STDEXT2_VPCLMULQDQ | CPUID_STDEXT2_AVX512VNNI |
		    CPUID_STDEXT2_AVX512BITALG | CPUID_STDEXT2_AVX512VPOPCNTDQ |
		    CPUID_STDEXT2_RDPID),
		.bcc_clear = (CPUID_STDEXT2_AVX512VBMI |
		    CPUID_STDEXT2_AVX512VBMI2 | CPUID_STDEXT2_VAES |
		    CPUID_STDEXT2_VPCLMULQDQ | CPUID_STDEXT2_AVX512VNNI |
		    CPUID_STDEXT2_AVX512BITALG | CPUID_STDEXT2_AVX512VPOPCNTDQ |
		    CPUID_STDEXT2_RDPID),
		.bcc_lower = 0,
	},
	{
		.bcc_function = 0x00000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EDX,
		.bcc_immutable = ~(CPUID_STDEXT3_AVX5124VNNIW |
		    CPUID_STDEXT3_AVX5124FMAPS |
		    CPUID_STDEXT3_AVX512VP2INTERSECT | CPUID_STDEXT3_MD_CLEAR),
		.bcc_clear = (CPUID_STDEXT3_AVX5124VNNIW |
		    CPUID_STDEXT3_AVX5124FMAPS |
		    CPUID_STDEXT3_AVX512VP2INTERSECT | CPUID_STDEXT3_MD_CLEAR),
		.bcc_lower = 0,
	},

	/* 0x00000009: Direct Cache Access Information */
	{ 0x00000009, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x0000000a: Architectural Performance Monitoring */
	{ 0x0000000a, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x0000000b: Intel CPU Topology */
	{ 0x0000000b, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x0000000d, 0x00: Extended State Enumeration (XCR0) */
	{ 0x0000000d, 0x00, VCE_REG_EAX, 0, 0xffffffff, 0 },
	{ 0x0000000d, 0x00, VCE_REG_EBX, 0xffffffff, 0, 0 },
	{ 0x0000000d, 0x00, VCE_REG_ECX, 0xffffffff, 0, 0 },
	{ 0x0000000d, 0x00, VCE_REG_EDX, 0, 0xffffffff, 0 },

	/* 0x0000000d, 0x01: Extended State Enumeration (IA32_XSS) */
	{ 0x0000000d, 0x01, VCE_REG_EAX, 0, 0xffffffff, 0 },
	{ 0x0000000d, 0x00, VCE_REG_EBX, 0xffffffff, 0, 0 },
	{ 0x0000000d, 0x00, VCE_REG_ECX, 0, 0xffffffff, 0 },
	{ 0x0000000d, 0x01, VCE_REG_EDX, 0, 0xffffffff, 0 },

	/* 0x0000000d, 0x02 and beyond: Extended State Enumeration (sizes) */
	{ 0x0000000d, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x0000000f: Resource Director Technology */
	{ 0x0000000f, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x00000010: Resource Director Technology */
	{ 0x00000010, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x00000015: TSC/Crystal */
	{ 0x00000015, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x00000018: Deterministic Address Translation Paramters */
	{ 0x00000018, 0x00, VCE_REG_EAX, 0, 0, 0xffffffff },
	{ 0x00000018, 0x00, VCE_REG_EBX, 0, 0xffffffff, 0 },
	{ 0x00000018, 0x00, VCE_REG_ECX, 0, 0xffffffff, 0 },
	{ 0x00000018, 0x00, VCE_REG_EDX, 0, 0xffffffff, 0 },
	{ 0x00000018, -1, VCE_REG_EAX, 0xffffffff, 0, 0 },
	{ 0x00000018, -1, VCE_REG_EBX, 0, 0, 0xffff0000 },
	{ 0x00000018, -1, VCE_REG_ECX, 0, 0, 0xffffffff },

	/* 0x0000001f: Intel CPU Topology v2 */
	{ 0x0000001f, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x40000100, -1: Backup Hypervisor Leaves */
	{ 0x40000100, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/* 0x80000000,  0x00: Extended CPUID Functions */
	{ 0x80000000, 0x00, VCE_REG_EBX, 0xffffffff, 0, 0 },
	{ 0x80000000, 0x00, VCE_REG_ECX, 0xffffffff, 0, 0 },
	{ 0x80000000, 0x00, VCE_REG_EDX, 0xffffffff, 0, 0 },

	/*
	 * 0x80000001, 0x00: ecx: AMD Extended Features
	 * x86-64-v2: LAHF
	 * x86-64-v3: ABM
	 * vmm masked:
	 * SVM, PCXC, PNXC, PTSCEL2I, IBS, NODE_ID, OSVW, MWAITX, TCE
	 */
	{
		.bcc_function = 0x80000001,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = (AMDID2_SVM | AMDID2_PCXC | AMDID2_PNXC |
		    AMDID2_PTSCEL2I | AMDID2_IBS | AMDID2_NODE_ID |
		    AMDID2_OSVW | AMDID2_MWAITX | AMDID2_TCE),
		.bcc_clear = 0xffffffff,
		.bcc_lower = 0,
	},

	/*
	 * 0x80000001, 0x00: edx: AMD Extended Features
	 */
	{
		.bcc_function = 0x80000001,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EDX,
		.bcc_immutable = 0,
		.bcc_clear = 0xffffffff,
		.bcc_lower = 0,
	},

	/* 0x80000005, 0x00: AMD L1 Cache / TLB Topology */
	{ 0x80000005, 0x00, VCE_REG_ANY, 0, 0, 0xff000000 },
	{ 0x80000005, 0x00, VCE_REG_ANY, 0, 0, 0x00ff0000 },
	{ 0x80000005, 0x00, VCE_REG_ANY, 0, 0, 0x0000ff00 },
	{ 0x80000005, 0x00, VCE_REG_ANY, 0, 0, 0x000000ff },

	/* 0x80000006, 0x00: AMD L2/L3 Cache Topology  */
	{ 0x80000006, 0x00, VCE_REG_EAX, 0, 0, 0xf0000000 },
	{ 0x80000006, 0x00, VCE_REG_EAX, 0, 0, 0x0fff0000 },
	{ 0x80000006, 0x00, VCE_REG_EAX, 0, 0, 0x0000f000 },
	{ 0x80000006, 0x00, VCE_REG_EAX, 0, 0, 0x00000fff },
	{ 0x80000006, 0x00, VCE_REG_EBX, 0, 0, 0xf0000000 },
	{ 0x80000006, 0x00, VCE_REG_EBX, 0, 0, 0x0fff0000 },
	{ 0x80000006, 0x00, VCE_REG_EBX, 0, 0, 0x0000f000 },
	{ 0x80000006, 0x00, VCE_REG_EBX, 0, 0, 0x00000fff },
	{ 0x80000006, 0x00, VCE_REG_ECX, 0, 0, 0xffff0000 },
	{ 0x80000006, 0x00, VCE_REG_ECX, 0, 0, 0x0000f000 },
	{ 0x80000006, 0x00, VCE_REG_ECX, 0, 0, 0x00000f00 },
	{ 0x80000006, 0x00, VCE_REG_ECX, 0, 0, 0x000000ff },
	{ 0x80000006, 0x00, VCE_REG_EDX, 0, 0, 0xfffc0000 },
	{ 0x80000006, 0x00, VCE_REG_EDX, 0, 0, 0x0000f000 },
	{ 0x80000006, 0x00, VCE_REG_EDX, 0, 0, 0x00000f00 },
	{ 0x80000006, 0x00, VCE_REG_EDX, 0, 0, 0x000000ff },

	/*
	 * 0x80000007, 0x00: AMD Extended Functions
	 * vmm masked: everything but TSC_INVARIANT
	 */
	{ 0x80000007, 0x00, VCE_REG_EAX, 0xffffffff, 0, 0 },
	{ 0x80000007, 0x00, VCE_REG_EBX, 0xffffffff, 0, 0 },
	{ 0x80000007, 0x00, VCE_REG_ECX, 0xffffffff, 0, 0 },
	{
		.bcc_function = 0x80000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EDX,
		.bcc_immutable = ~AMDPM_TSC_INVARIANT,
		.bcc_clear = AMDPM_TSC_INVARIANT,
		.bcc_lower = 0,
	},


	/* 0x80000008, 0x00: EAX: Long Mode Address Sizes */
	{ 0x80000008, 0x00, VCE_REG_EAX, 0, 0, 0x00ff0000 },
	{ 0x80000008, 0x00, VCE_REG_EAX, 0, 0, 0x0000ff00 },
	{ 0x80000008, 0x00, VCE_REG_EAX, 0, 0, 0x000000ff },

	/*
	 * 0x80000008, 0x00: EBX: AMD Extended Features
	 * vmm masked: everything but CLZERO, IRPERF, XSAVEERPTR
	 */
	{
		.bcc_function = 0x80000008,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EBX,
		.bcc_immutable = ~(AMDFEID_CLZERO | AMDFEID_XSAVEERPTR),
		.bcc_clear = (AMDFEID_CLZERO | AMDFEID_XSAVEERPTR),
		.bcc_lower = 0,
	},

	/* 0x80000008, 0x00: ECX: AMD APIC ID Size and Core Count */
	{ 0x80000008, 0x00, VCE_REG_ECX, 0xffffffff, 0, 0 },

	/* 0x80000019, 0x00: EAX, EBX: L1/L2 TLB 1G Identifiers */
	{ 0x80000019, 0x00, VCE_REG_EAX, 0, 0, 0xf0000000 },
	{ 0x80000019, 0x00, VCE_REG_EAX, 0, 0, 0x0fff0000 },
	{ 0x80000019, 0x00, VCE_REG_EAX, 0, 0, 0x0000f000 },
	{ 0x80000019, 0x00, VCE_REG_EAX, 0, 0, 0x00000fff },
	{ 0x80000019, 0x00, VCE_REG_EBX, 0, 0, 0xf0000000 },
	{ 0x80000019, 0x00, VCE_REG_EBX, 0, 0, 0x0fff0000 },
	{ 0x80000019, 0x00, VCE_REG_EBX, 0, 0, 0x0000f000 },
	{ 0x80000019, 0x00, VCE_REG_EBX, 0, 0, 0x00000fff },

	/*
	 * 0x8000001d: AMD Cache Topology
	 * vmm generates a fictitious cache topology
	 */
	{ 0x8000001d, -1, VCE_REG_EAX, 0, 0x00000300, 0x03fc0000 },
	{ 0x8000001d, -1, VCE_REG_EAX, 0, 0x00000300, 0x000000e0 },
	{ 0x8000001d, -1, VCE_REG_EAX, 0, 0x00000300, 0x0000001f },
	{ 0x8000001d, -1, VCE_REG_EBX, 0, 0, 0xffc00000 },
	{ 0x8000001d, -1, VCE_REG_EBX, 0, 0, 0x003ff000 },
	{ 0x8000001d, -1, VCE_REG_EBX, 0, 0, 0x00000fff },
	{ 0x8000001d, -1, VCE_REG_ECX, 0, 0, 0xffffffff },
	{ 0x8000001d, -1, VCE_REG_EDX, 0, 0, 0 },

	/*
	 * 0x8000001e, 0x00: AMD Extended Topology
	 */
	{ 0x8000001e, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },

	/*
	 * 0x80000020, 0x00: AMD PQOS Extended Features
	 */
	{ 0x80000020, -1, VCE_REG_ANY, 0xffffffff, 0, 0 },
};

static bool cpuid_0x0000000d_index_valid(struct vm_vcpu_cpuid_config *,
    uint32_t);
static bool cpuid_index_valid(struct vm_vcpu_cpuid_config *,
    const struct vcpu_cpuid_entry *, const struct vcpu_cpuid_entry *);
static uint32_t cpuid_max_index(uint32_t, uint32_t);
static uint32_t cpuid_base_function(uint32_t);

static struct vcpu_cpuid_entry *bhyve_alloc_cpuid_config_entry(
    struct vm_vcpu_cpuid_config *, uint32_t, uint32_t);
static struct vcpu_cpuid_entry *bhyve_get_cpuid_config_entry(
    struct vm_vcpu_cpuid_config *, uint32_t, uint32_t);

static int bhyve_cpuid_compare_feature(const void *, const void *);
static const struct bhyve_cpuid_feature *bhyve_get_cpuid_feature(char *);

static void bhyve_process_special_action(struct vm_vcpu_cpuid_config *,
    const struct bhyve_cpuid_action *);
static void bhyve_process_cpuid_action(struct vcpu_cpuid_entry *,
    const struct bhyve_cpuid_action *);
static int bhyve_apply_cpuid_actions(struct vm_vcpu_cpuid_config *,
    struct bhyve_cpuid_action_queue *);

static int bhyve_parse_special_option(const char *, const nvlist_t *,
    const char *, struct bhyve_cpuid_action_queue *);
static int bhyve_parse_cpuid_assignment(char *, struct bhyve_cpuid_action *,
    enum vce_reg *);
static int bhyve_add_cpuid_config_entry(const char *, const nvlist_t *,
    const char *, int, void *);
static int bhyve_build_cpuid_action_queue(const char *,
    struct bhyve_cpuid_action_queue *);

static int bhyve_compare_cpuid_entries(const void *, const void *);

static int bhyve_fixup_cpuid_00000001(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_00000002(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_00000004(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_0000000b(struct vm_vcpu_cpuid_config *);
static int bhyve_fixup_cpuid_0000000d(struct vm_vcpu_cpuid_config *);
static int bhyve_fixup_cpuid_00000018(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_0000001f(struct vm_vcpu_cpuid_config *);
static int bhyve_fixup_cpuid_80000000(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_80000001(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_80000005(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_80000006(struct vm_vcpu_cpuid_config *,
    enum bhyve_cpu_vendor);
static int bhyve_fixup_cpuid_8000001e(struct vm_vcpu_cpuid_config *);

static int bhyve_fixup_cpuid_config(struct vm_vcpu_cpuid_config *);

static const struct bhyve_cpuid_constraint *bhyve_get_next_cpuid_constraint(
    const struct bhyve_cpuid_constraint *, uint32_t, int32_t, enum vce_reg);
static bool bhyve_check_cpuid_constraint(uint32_t, uint32_t, enum vce_reg,
    uint32_t *, uint32_t, bool, bool);
static int bhyve_check_cpuid_constraints(struct vm_vcpu_cpuid_config *);

static int bhyve_get_legacy_cpuid(struct vcpu *, struct vm_legacy_cpuid *,
    uint32_t, uint32_t);
static struct vcpu_cpuid_entry *bhyve_get_legacy_cpuid_function_index(uint32_t,
    uint32_t, struct vm_vcpu_cpuid_config *);
static struct vcpu_cpuid_entry *bhyve_get_legacy_cpuid_function(uint32_t,
    struct vm_vcpu_cpuid_config *);
static struct vcpu_cpuid_entry *bhyve_get_legacy_cpuid_set(uint32_t,
    struct vm_vcpu_cpuid_config *);
static int bhyve_build_legacy_cpuid_config(struct vm_vcpu_cpuid_config *);


/*
 * Check whether the given index is valid for function 0x0000000d.
 *
 * Function 0x0000000d is quite special:
 * - Indices 0 and 1 are always valid.
 *
 * - For indices 2-31, the index is valid if the corresponding
 *   bits of either EAX of index 0 or ECX of index 1 are set.
 *
 * - For indices 32-64, the index is valid if the corresponding
 *   bits of EDX of either index 0 or index 1 are valid. The
 *   corresponding bits are index - 32.
 */
static bool
cpuid_0x0000000d_index_valid(struct vm_vcpu_cpuid_config *vvcc, uint32_t index)
{
	struct vcpu_cpuid_entry *vce;
	int reg = 0;

	if (index == 0 || index == 1)
		return (true);

	if (index >= 32) {
		reg = 3;
		index -= 32;
	}

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000d, 0);
	if (vce == NULL)
		return (false);

	if ((vce->vce_regs[reg] & (1 << index)) != 0)
		return (true);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000d, 1);
	if (vce == NULL)
		return (false);

	if (reg != 3)
		reg = 2;

	return ((vce->vce_regs[reg] & (1 << index)) != 0);
}

/*
 * Check whether a particular index is actually valid for the function, based on
 * the register values returned for this index or index 0 of the same function.
 */
static bool
cpuid_index_valid(struct vm_vcpu_cpuid_config *vvcc,
    const struct vcpu_cpuid_entry *vce0, const struct vcpu_cpuid_entry *vce)
{
	struct {
		uint32_t function;
		enum vce_reg reg;
		uint32_t mask;
	} fcfg[] = {
		{ 0x00000004, VCE_REG_EAX, 0x1f },
		{ 0x0000000b, VCE_REG_ECX, 0xff00 },
		{ 0x00000012, VCE_REG_EAX, 0xf },
		{ 0x0000001b, VCE_REG_EAX, 0xfff },
		{ 0x0000001f, VCE_REG_ECX, 0xff00 },
		{ 0x80000026, VCE_REG_EBX, 0xffff },
	};

	assert(vce->vce_function == vce0->vce_function);

	/* Assume index 0 is always valid. */
	if (vce->vce_index == 0)
		return (true);

	/*
	 * If index 0 was marked invalid by other means, all higher indices of
	 * the same function are invalid, too.
	 */
	if ((vce0->vce_flags & VCE_FLAG_INVALID) != 0)
		return (false);

	if (vce->vce_function == 0x0000000d) {
		return (cpuid_0x0000000d_index_valid(vvcc, vce->vce_index));
	}

	if (vce->vce_function == 0x0000000f) {
		/* valid if corresponding bit in EDX of index 0 is set */
		return ((vce0->vce_edx & (1 << vce->vce_index)) != 0);
	}

	if (vce->vce_function == 0x00000010) {
		/* valid if corresponding bit in EBX of index 0 is set */
		return ((vce0->vce_ebx & (1 << vce->vce_index)) != 0);
	}

	if (vce->vce_function == 0x00000012 && vce->vce_index < 2) {
		/* indices 0, 1, 2 always valid */
		return (true);
	}

	if (vce->vce_function == 0x00000014 ||
	    vce->vce_function == 0x00000017 ||
	    vce->vce_function == 0x00000018 ||
	    vce->vce_function == 0x0000001d ||
	    vce->vce_function == 0x00000020) {
		/* max index in EAX of index 0 */
		return (vce->vce_index <= vce0->vce_eax);
	}

	for (int i = 0; i != nitems(fcfg); i++) {
		if (fcfg[i].function != vce->vce_function)
			continue;

		return ((vce->vce_regs[fcfg[i].reg] & fcfg[i].mask) != 0);
	}

	return (false);
}

/*
 * Return the maximum index value for a given CPUID function. For most
 * functions this is a fixed value, but for some it's in EAX of the function.
 */
static uint32_t
cpuid_max_index(uint32_t function, uint32_t eax0)
{
	static const struct {
		uint32_t function;
		uint32_t max_index;
	} fcfg[] = {
		{ 0x00000004, 0x01f },
		{ 0x0000000b, 0x001 },
		{ 0x0000000d, 0x03f },
		{ 0x0000000f, 0x001 },
		{ 0x00000010, 0x003 },
		{ 0x00000012, 0x01f },
		{ 0x0000001b, 0x01f },
		{ 0x0000001f, 0x005 },
		{ 0x8000001d, 0x01f },
		{ 0x80000026, 0x003 },
	};

	if (function == 0x00000014 ||
	    function == 0x00000017 ||
	    function == 0x00000018) {
		/* max. index is in EAX of index 0 */
		return (eax0);
	}

	for (int i = 0; i != nitems(fcfg); i++) {
		if (fcfg[i].function == function) {
			return (fcfg[i].max_index);
		}
	}

	return (0);

}

/*
 * Return the base function for a given CPUID function set.
 */
static uint32_t
cpuid_base_function(uint32_t function)
{
	/* Of course, there's always an exception to every rule. */
	if (CPUID_TYPE(function) != CPUID_TYPE_HV)
		function &= ~CPUID_HV_FUNC_MASK;
	else
		function &= ~CPUID_HV_FUNC_MASK;

	return (function);
}

/*
 * Allocate a new CPUID config entry for a vm_vcpu_cpuid_config structure.
 * Reallocate the vvcc_entries array if needed to hold the new entry.
 */
static struct vcpu_cpuid_entry *
bhyve_alloc_cpuid_config_entry(struct vm_vcpu_cpuid_config *vvcc,
    uint32_t function, uint32_t index)
{
	struct vcpu_cpuid_entry *vce;

	if (vvcc->vvcc_nent >= vvcc->vvcc_ent_sz) {
		vvcc->vvcc_entries = recallocarray(vvcc->vvcc_entries,
		    vvcc->vvcc_ent_sz, vvcc->vvcc_ent_sz + 32, sizeof(*vce));

		if (vvcc->vvcc_entries == NULL) {
			warn("bhyve_alloc_cpuid_config_entry(): "
			    "failed to allocate %d config entries",
			    vvcc->vvcc_nent + 32);
			return (NULL);
		}

		vvcc->vvcc_ent_sz += 32;
	}

	vce = &vvcc->vvcc_entries[vvcc->vvcc_nent++];

	vce->vce_function = function;
	vce->vce_index = index;

	return (vce);
}

/*
 * Get a CPUID config entry matching the given function (and index, if
 * applicable) from a vm_vcpu_cpuid_config. If no such entry exists,
 * enter a new empty entry into the config and return a pointer to it.
 */
static struct vcpu_cpuid_entry *
bhyve_get_cpuid_config_entry(struct vm_vcpu_cpuid_config *vvcc,
    uint32_t function, uint32_t index)
{
	struct vcpu_cpuid_entry *vce = vvcc->vvcc_entries;
	bool match_index = false;
	uint32_t i;

	for (i = 0; i < vvcc->vvcc_nent; i++) {
		if (vce[i].vce_function != function)
			continue;

		if ((vce[i].vce_flags & VCE_FLAG_MATCH_INDEX) != 0)
			match_index = true;

		if (vce[i].vce_index == index)
			return (&vce[i]);
	}

	vce = bhyve_alloc_cpuid_config_entry(vvcc, function, index);
	if (vce != NULL && match_index)
		vce->vce_flags |= VCE_FLAG_MATCH_INDEX;

	return (vce);
}

/* Find a CPUID feature by name. */
static int
bhyve_cpuid_compare_feature(const void *key, const void *elem)
{
	const struct bhyve_cpuid_feature *bcf = elem;
	const char *name = key;

	return (strcasecmp(name, bcf->bcf_name));
}

static const struct bhyve_cpuid_feature *
bhyve_get_cpuid_feature(char *name)
{
	const struct bhyve_cpuid_feature *bcf;

	bcf = bsearch(name, bhyve_cpuid_features, nitems(bhyve_cpuid_features),
	    sizeof(struct bhyve_cpuid_feature), bhyve_cpuid_compare_feature);

	return (bcf);
}

/*
 * Handle the special global "cpuid.features" option.
 */
static int
bhyve_set_cpuid_features(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	char *stringp, *valstr, *tofree;

	tofree = stringp = strdup(value);
	if (stringp == NULL) {
		warn("bhyve_enable_cpuid_features()");
		return (-1);
	}

	while ((valstr = strsep(&stringp, ",")) != NULL) {
		const struct bhyve_cpuid_feature *bcf;
		struct bhyve_cpuid_action *act;
		enum bhyve_cpuid_op op = CPUID_OP_OR;

		if (valstr[0] == '-')
			op = CPUID_OP_AND;

		if (valstr[0] == '-' || valstr[0] == '+')
			valstr++;

		bcf = bhyve_get_cpuid_feature(valstr);
		if (bcf == NULL) {
			warn("bhyve_enable_cpuid_features(): "
			    "invalid feature '%s'", valstr);
			free(tofree);
			return (-1);
		}

		act = calloc(1, sizeof(struct bhyve_cpuid_action));

		if (act == NULL) {
			warn("bhyve_enable_cpuid_features()");
			free(tofree);
			return (-1);
		}

		act->bca_function = bcf->bcf_func;
		act->bca_index = bcf->bcf_idx;
		act->bca_reg = bcf->bcf_reg;
		act->bca_op = op;
		act->bca_val =
		    op == CPUID_OP_OR ? bcf->bcf_bit : ~bcf->bcf_bit;

		STAILQ_INSERT_TAIL(actq, act, bca_link);
	}

	free(tofree);
	return (0);
}

/*
 * Handle the special global "cpuid.fallback-style" option. Build a special
 * action to set or clear the flag in vvcc_flags accordingly.
 */
static int
bhyve_set_cpuid_fallback_style(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = UINT32_MAX;
	act->bca_index = 0;

	if (strcasecmp(value, "intel") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = VCC_FLAG_INTEL_FALLBACK;
	} else if (strcasecmp(value, "amd") == 0) {
		/* default behaviour */
		act->bca_op = CPUID_OP_AND;
		act->bca_val = ~VCC_FLAG_INTEL_FALLBACK;
	} else {
		warnx("bhyve_set_cpuid_fallback_style(): "
		    "invalid fallback style \"%s\"", value);
		free(act);
		return (-1);
	}

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_check(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = UINT32_MAX;
	act->bca_index = 0;

	if (strcasecmp(value, "none") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = VCC_FLAG_CHECK_SKIP;
	} else if (strcasecmp(value, "warn") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = VCC_FLAG_CHECK_WARN;
	} else if (strcasecmp(value, "fail") == 0) {
		act->bca_op = CPUID_OP_AND;
		act->bca_val = ~(VCC_FLAG_CHECK_SKIP | VCC_FLAG_CHECK_WARN |
		    VCC_FLAG_CHECK_FIX);
	} else if (strcasecmp(value, "fix") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = VCC_FLAG_CHECK_WARN | VCC_FLAG_CHECK_FIX;
	} else {
		warnx("bhyve_set_cpuid_check(): "
		    "invalid fallback style \"%s\"", value);
		free(act);
		return (-1);
	}

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_pkgtype(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000001;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EBX;

	if (strcasecmp(value, "am3") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = 0x10000000;
	} else {
		warnx("bhyve_set_cpuid_check(): "
		    "invalid fallback style \"%s\"", value);
		free(act);
		return (-1);
	}

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_family(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t fam, extfam;


	fam = strtonumx(value, 0, 1023, &errstr, 0);

	if (fam > 15) {
		extfam = fam - 15;
		fam = 15;
	} else {
		extfam = 0;
	}

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_family: invalid value: %s", value);
		return (-1);
	}

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x00000001;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_AND;
	act->bca_val = ~(CPUID_FAMILY | CPUID_EXT_FAMILY);

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x00000001;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_OR;
	act->bca_val = (fam << 8) | (extfam << 20);

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_model(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, 255, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_model: invalid value: %s", value);
		return (-1);
	}

	act = calloc(2, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act[0].bca_function = 0x00000001;
	act[0].bca_index = 0;
	act[0].bca_reg = VCE_REG_EAX;
	act[0].bca_op = CPUID_OP_AND;
	act[0].bca_val = ~(CPUID_MODEL | CPUID_EXT_MODEL);

	act[1].bca_function = 0x00000001;
	act[1].bca_index = 0;
	act[1].bca_reg = VCE_REG_EAX;
	act[1].bca_op = CPUID_OP_OR;
	act[1].bca_val = ((val & 0xf) << 4) | ((val & 0xf0) << 12);

	STAILQ_INSERT_TAIL(actq, &act[0], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[1], bca_link);

	return (0);
}

static int
bhyve_set_cpuid_stepping(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, 255, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_stepping: invalid value: %s", value);
		return (-1);
	}

	act = calloc(2, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act[0].bca_function = 0x00000001;
	act[0].bca_index = 0;
	act[0].bca_reg = VCE_REG_EAX;
	act[0].bca_op = CPUID_OP_AND;
	act[0].bca_val = ~CPUID_STEPPING;

	act[1].bca_function = 0x00000001;
	act[1].bca_index = 0;
	act[1].bca_reg = VCE_REG_EAX;
	act[1].bca_op = CPUID_OP_OR;
	act[1].bca_val = val & 0xf;

	STAILQ_INSERT_TAIL(actq, &act[0], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[1], bca_link);

	return (0);
}

static int
bhyve_set_cpuid_level(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, UINT32_MAX, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_level: invalid value: %s", value);
		return (-1);
	}

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x00000000;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_SET;
	act->bca_val = val;

	STAILQ_INSERT_TAIL(actq, act, bca_link);
	return (0);
}

static int
bhyve_set_cpuid_xlevel(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, UINT32_MAX, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_level: invalid value: %s", value);
		return (-1);
	}

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000000;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_SET;
	act->bca_val = val;

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_brand(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	uint32_t values[12] = { 0 };
	struct bhyve_cpuid_action *act;

	bcopy(value, values, MIN(sizeof(values), strlen(value)));

	act = calloc(12, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act[0].bca_function = 0x80000002;
	act[0].bca_index = 0;
	act[0].bca_reg = VCE_REG_EAX;
	act[0].bca_op = CPUID_OP_SET;
	act[0].bca_val = values[0];

	act[1].bca_function = 0x80000002;
	act[1].bca_index = 0;
	act[1].bca_reg = VCE_REG_EBX;
	act[1].bca_op = CPUID_OP_SET;
	act[1].bca_val = values[1];

	act[2].bca_function = 0x80000002;
	act[2].bca_index = 0;
	act[2].bca_reg = VCE_REG_ECX;
	act[2].bca_op = CPUID_OP_SET;
	act[2].bca_val = values[2];

	act[3].bca_function = 0x80000002;
	act[3].bca_index = 0;
	act[3].bca_reg = VCE_REG_EDX;
	act[3].bca_op = CPUID_OP_SET;
	act[3].bca_val = values[3];

	act[4].bca_function = 0x80000003;
	act[4].bca_index = 0;
	act[4].bca_reg = VCE_REG_EAX;
	act[4].bca_op = CPUID_OP_SET;
	act[4].bca_val = values[4];

	act[5].bca_function = 0x80000003;
	act[5].bca_index = 0;
	act[5].bca_reg = VCE_REG_EBX;
	act[5].bca_op = CPUID_OP_SET;
	act[5].bca_val = values[5];

	act[6].bca_function = 0x80000003;
	act[6].bca_index = 0;
	act[6].bca_reg = VCE_REG_ECX;
	act[6].bca_op = CPUID_OP_SET;
	act[6].bca_val = values[6];

	act[7].bca_function = 0x80000003;
	act[7].bca_index = 0;
	act[7].bca_reg = VCE_REG_EDX;
	act[7].bca_op = CPUID_OP_SET;
	act[7].bca_val = values[7];

	act[8].bca_function = 0x80000004;
	act[8].bca_index = 0;
	act[8].bca_reg = VCE_REG_EAX;
	act[8].bca_op = CPUID_OP_SET;
	act[8].bca_val = values[8];

	act[9].bca_function = 0x80000004;
	act[9].bca_index = 0;
	act[9].bca_reg = VCE_REG_EBX;
	act[9].bca_op = CPUID_OP_SET;
	act[9].bca_val = values[9];

	act[10].bca_function = 0x80000004;
	act[10].bca_index = 0;
	act[10].bca_reg = VCE_REG_ECX;
	act[10].bca_op = CPUID_OP_SET;
	act[10].bca_val = values[10];

	act[11].bca_function = 0x80000004;
	act[11].bca_index = 0;
	act[11].bca_reg = VCE_REG_EDX;
	act[11].bca_op = CPUID_OP_SET;
	act[11].bca_val = values[11];

	STAILQ_INSERT_TAIL(actq, &act[0], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[1], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[2], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[3], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[4], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[5], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[6], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[7], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[8], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[9], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[10], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[11], bca_link);

	return (0);
}

static int
bhyve_set_cpuid_linear(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, 57, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_linear: invalid value: %s", value);
		return (-1);
	}

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000008;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_AND;
	act->bca_val = 0xffff00ff;

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000008;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_OR;
	act->bca_val = val << 8;

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_physical(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *errstr;
	uint32_t val;

	val = strtonumx(value, 0, 48, &errstr, 0);

	if (errstr != NULL) {
		warnx("bhyve_set_cpuid_physical: invalid value: %s", value);
		return (-1);
	}

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000008;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_AND;
	act->bca_val = 0xffffff00;

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	act = calloc(1, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act->bca_function = 0x80000008;
	act->bca_index = 0;
	act->bca_reg = VCE_REG_EAX;
	act->bca_op = CPUID_OP_OR;
	act->bca_val = val;

	STAILQ_INSERT_TAIL(actq, act, bca_link);

	return (0);
}

static int
bhyve_set_cpuid_hypervisor(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *ident = value;
	int i;

	for (i = 0; i != nitems(bhyve_hv_vendors); i++) {
		if (strcasecmp(value, bhyve_hv_vendors[i].bhv_alias) == 0) {
			ident = bhyve_hv_vendors[i].bhv_ident;
			break;
		}
	}

	act = calloc(4, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act[0].bca_function = act[1].bca_function = act[2].bca_function =
	    act[3].bca_function = 0x40000000;
	act[0].bca_index = act[1].bca_index = act[2].bca_index =
	    act[3].bca_index = 0;
	act[0].bca_reg = VCE_REG_EAX;
	act[1].bca_reg = VCE_REG_EBX;
	act[2].bca_reg = VCE_REG_ECX;
	act[3].bca_reg = VCE_REG_EDX;
	act[0].bca_op = act[1].bca_op = act[2].bca_op =
	    act[3].bca_op = CPUID_OP_SET;

	act[0].bca_val = 0x40000000;
	act[1].bca_val = *(const uint32_t *)&ident[0];
	act[2].bca_val = *(const uint32_t *)&ident[4];
	act[3].bca_val = *(const uint32_t *)&ident[8];

	STAILQ_INSERT_TAIL(actq, &act[0], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[1], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[2], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[3], bca_link);

	return (0);
}

static int
bhyve_set_cpuid_vendor(const char *value,
    struct bhyve_cpuid_action_queue *actq)
{
	struct bhyve_cpuid_action *act;
	const char *ident = value;
	int i;

	for (i = 0; i != nitems(bhyve_cpu_vendors); i++) {
		if (strcasecmp(value, bhyve_cpu_vendors[i].bcv_alias) == 0) {
			ident = bhyve_cpu_vendors[i].bcv_ident;
			break;
		}
	}

	act = calloc(3, sizeof(struct bhyve_cpuid_action));
	if (act == NULL)
		return (-1);

	act[0].bca_function = act[1].bca_function = act[2].bca_function = 0;
	act[0].bca_index = act[1].bca_index = act[2].bca_index = 0;
	act[0].bca_reg = VCE_REG_EBX;
	act[1].bca_reg = VCE_REG_EDX;
	act[2].bca_reg = VCE_REG_ECX;
	act[0].bca_op = act[1].bca_op = act[2].bca_op = CPUID_OP_SET;

	act[0].bca_val = *(const uint32_t *)&ident[0];
	act[1].bca_val = *(const uint32_t *)&ident[4];
	act[2].bca_val = *(const uint32_t *)&ident[8];

	STAILQ_INSERT_TAIL(actq, &act[0], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[1], bca_link);
	STAILQ_INSERT_TAIL(actq, &act[2], bca_link);

	return (0);
}

/*
 * Process a special action.
 *
 * At this time, a special action only modifies vvcc_flags.
 */
static void
bhyve_process_special_action(struct vm_vcpu_cpuid_config *vvcc,
    const struct bhyve_cpuid_action *bca)
{
	switch (bca->bca_op) {
	case CPUID_OP_OR:
		vvcc->vvcc_flags |= bca->bca_val;
		break;

	case CPUID_OP_AND:
		vvcc->vvcc_flags &= bca->bca_val;
		break;

	default:
		assert(0);
	}
}

/*
 * Process a CPUID action.
 */
static void
bhyve_process_cpuid_action(struct vcpu_cpuid_entry *vce,
    const struct bhyve_cpuid_action *bca)
{
	assert(bca->bca_reg <= VCE_REG_EDX);

	if (vce->vce_function != bca->bca_function ||
	    vce->vce_index != bca->bca_index) {
		errx(4, "bhyve_process_cpuid_action(): invalid CPUID action "
		    "0x%.8x,0x%.2x %s%*s=0x%.8x applied against 0x%.8x,0x%.2x"
		    "(%s = 0x%.8x)", bca->bca_function, bca->bca_index,
		    bhyve_regs[bca->bca_reg],
		    bca->bca_op == CPUID_OP_SET ? 0 : 1,
		    bca->bca_op == CPUID_OP_OR ? "|" : "&",
		    bca->bca_val, vce->vce_function, vce->vce_index,
		    bhyve_regs[bca->bca_reg], vce->vce_regs[bca->bca_reg]);
	}

	switch (bca->bca_op) {
	case CPUID_OP_SET:
		vce->vce_regs[bca->bca_reg] = bca->bca_val;
		break;

	case CPUID_OP_OR:
		vce->vce_regs[bca->bca_reg] |= bca->bca_val;
		break;

	case CPUID_OP_AND:
		vce->vce_regs[bca->bca_reg] &= bca->bca_val;
		break;

	default:
		assert(0);
	}

	/*
	 * Indicate that we've modified this entry and that it should
	 * be checked in bhyve_fixup_cpuid_config().
	 */
	vce->vce_flags |= VCE_FLAG_MODIFIED;
}

/*
 * Apply a set of CPUID actions against an existing struct
 * vm_vcpu_cpuid_config. This may modify existing entries
 * or add new entries, if necessary.
 */
static int
bhyve_apply_cpuid_actions(struct vm_vcpu_cpuid_config *vvcc,
    struct bhyve_cpuid_action_queue *actq)
{
	struct vcpu_cpuid_entry *vce;
	const struct bhyve_cpuid_action *act;

	if (STAILQ_EMPTY(actq))
		return (0);

	STAILQ_FOREACH(act, actq, bca_link) {
		if (act->bca_function == UINT32_MAX &&
		    act->bca_index == 0) {
			bhyve_process_special_action(vvcc, act);
			continue;
		}

		/* Get the existing values, if any. */
		vce = bhyve_get_cpuid_config_entry(vvcc, act->bca_function,
		    act->bca_index);
		if (vce == NULL)
			return (-1);

		bhyve_process_cpuid_action(vce, act);
	}

	/*
	 * We got at least one valid CPUID config option. Clear the LEGACY flag.
	 */
	vvcc->vvcc_flags &= ~VCC_FLAG_LEGACY_HANDLING;

	return (0);
}

/*
 * Handle global options.
 *
 * In addition to returning 0 on success and -1 on error,
 * this will return -2 if name didn't match any known option.
 */
static int
bhyve_parse_special_option(const char *prefix, const nvlist_t *parent,
    const char *name, struct bhyve_cpuid_action_queue *actq)
{
	int i;

	for (i = 0; i != nitems(bhyve_cpuid_options); i++) {
		if (strcmp(bhyve_cpuid_options[i].opt_name, name) == 0) {
			const char *value;

			if (strcmp(prefix, "cpuid") != 0) {
				warnx("bhyve_parse_special_option(): invalid "
				    "global flag on per-VCPU config '%s': %s",
				    prefix, name);
				return (-1);
			}

			value = nvlist_get_string(parent, name);
			if (bhyve_cpuid_options[i].opt_func(value, actq) != 0) {
				return (-1);
			}

			return (0);
		}
	}

	return (-2);
}

/*
 * Parse a CPUID register assignment.
 *
 * The syntax for register assignments uses this form:
 *	[<reg><op>[~]]<val>
 * <reg> is one of "EAX", "EBX", "ECX", or "EDX" (case-insensitive)
 * <op> is one of "=", "|=", or "&="
 * <val> is the hexadecimal value to be assignend
 *
 * If <val> is preceded by a '~', the value will be inverted before the
 * assignment.
 *
 * If <reg> and <op> are omitted, <val> will be implicitly assigned to
 * one of the registers EAX, EBX, ECX, and EDX as indicated by the regidx
 * argument.
 */
static int
bhyve_parse_cpuid_assignment(char *valstr, struct bhyve_cpuid_action *bca,
    enum vce_reg *reg)
{
	bool invert = false;
	const char *errstr;
	char *regname;


	regname = strsep(&valstr, "=");
	if (valstr == NULL) {
		if (*reg > VCE_REG_EDX + 1) {
			warnx("bhyve_process_cpuid_assignment(): too many "
			    "CPUID register values: %s", regname);
			return (-1);
		}

		bca->bca_op = CPUID_OP_SET;
		bca->bca_reg = (*reg)++;
		valstr = regname;
	} else {
		if (strncasecmp(regname, "eax", 3) == 0) {
			bca->bca_reg = VCE_REG_EAX;
		} else if (strncasecmp(regname, "ebx", 3) == 0) {
			bca->bca_reg = VCE_REG_EBX;
		} else if (strncasecmp(regname, "ecx", 3) == 0) {
			bca->bca_reg = VCE_REG_ECX;
		} else if (strncasecmp(regname, "edx", 3) == 0) {
			bca->bca_reg = VCE_REG_EDX;
		} else {
			warnx("bhyve_process_cpuid_assignment(): invalid "
			    "CPUID register: %s", regname);
			return (-1);
		}

		if (regname[3] == '|') {
			bca->bca_op = CPUID_OP_OR;
		} else if (regname[3] == '&') {
			bca->bca_op = CPUID_OP_AND;
		} else if (regname[3] == '\0') {
			bca->bca_op = CPUID_OP_SET;
		} else {
			warnx("bhyve_process_cpuid_assignment(): invalid "
			    "CPUID register operation: '%c='", regname[3]);
			return (-1);
		}

		if (valstr[0] == '~') {
			invert = true;
			valstr++;
		}
	}

	bca->bca_val = (uint32_t)strtonumx(valstr, 0, UINT32_MAX, &errstr, 16);
	if (errstr != NULL) {
		warnx("bhyve_process_cpuid_assignment(): invalid CPUID "
		    "register value: %s", valstr);
		return (-1);
	}

	if (invert)
		bca->bca_val = ~bca->bca_val;

	return (0);
}

/*
 * Parse a single cpuid option into a struct bhyve_cpuid_action and enter it
 * into the given struct bhyve_cpuid_action_queue.
 */
static int
bhyve_add_cpuid_config_entry(const char *prefix, const nvlist_t *parent,
    const char *name, int type, void *arg)
{
	struct bhyve_cpuid_action_queue *actq = arg;
	uint32_t function = 0, index = 0;
	const char *value, *errstr;
	char *stringp, *valstr, *tofree;
	enum vce_reg reg;
	int ret = -1;

	if (type != NV_TYPE_STRING) {
		warnx("bhyve_add_cpuid_config_entry(): value for "
		    "function/index \"%s\" not string type", name);
		return (-1);
	}

	/*
	 * Get the CPUID function and optional index from the name.
	 * The index follows the function, separated by a comma.
	 */
	tofree = stringp = strdup(name);
	if (stringp == NULL) {
		warn("bhyve_add_cpuid_config_entry()");
		return (-1);
	}

	valstr = strsep(&stringp, ",");
	function = (uint32_t)strtonumx(valstr, 0, UINT32_MAX, &errstr, 16);

	if (errstr != NULL) {
		ret = bhyve_parse_special_option(prefix, parent, name, actq);
		if (ret < 0)
			warnx("bhyve_add_cpuid_config_entry(): "
			    "invalid CPUID function: %s", valstr);
		goto out;
	}

	if (stringp != NULL) {
		index = (uint32_t)strtonumx(stringp, 0, 0x3f, &errstr, 16);

		if (errstr != NULL) {
			warnx("bhyve_add_cpuid_config_entry(): "
			    "invalid CPUID index: %s", stringp);
			goto out;
		}
	}
	free(tofree);

	/*
	 * Get the comma-separated register assignments.
	 */
	value = nvlist_get_string(parent, name);
	tofree = stringp = strdup(value);
	if (stringp == NULL) {
		warn("bhyve_add_cpuid_config_entry()");
		return (-1);
	}

	reg = VCE_REG_EAX;
	while ((valstr = strsep(&stringp, ",")) != NULL) {
		struct bhyve_cpuid_action *act =
		    calloc(1, sizeof(struct bhyve_cpuid_action));

		if (act == NULL) {
			warn("bhyve_add_cpuid_config_entry()");
			goto out;
		}

		act->bca_function = function;
		act->bca_index = index;

		if (bhyve_parse_cpuid_assignment(valstr, act, &reg) != 0) {
			free(act);
			goto out;
		}

		STAILQ_INSERT_TAIL(actq, act, bca_link);
	}

	ret = 0;

out:
	free(tofree);
	return (ret);
}

/*
 * Parse all cpuid options under the given config node_name into
 * entries of a struct bhyve_cpuid_action_queue.
 */
static int
bhyve_build_cpuid_action_queue(const char *node_name,
    struct bhyve_cpuid_action_queue *actq)
{
	nvlist_t *parent;

	/*
	 * If there are no [vcpu.X.]cpuid.* config options, our work here is
	 * done.
	 */
	parent = find_config_node(node_name);
	if (parent == NULL)
		return (0);

	/*
	 * Walk all options under the parent to parse and enter them in the
	 * cpuid entries buffer.
	 */
	if (walk_config_nodes(node_name, parent, actq,
	    bhyve_add_cpuid_config_entry) != 0)
		return (-1);

	return (0);
}

/*
 * Compare two struct vcpu_cpuid_entry based on CPUID function and index.
 */
static int
bhyve_compare_cpuid_entries(const void *p1, const void *p2)
{
	const struct vcpu_cpuid_entry *v1 = p1;
	const struct vcpu_cpuid_entry *v2 = p2;
	int cmp;

	/*
	 * Handle the case of duplicates here, which aren't allowed.
	 */
	if (v1->vce_function == v2->vce_function) {
		cmp = (v1->vce_index > v2->vce_index) -
		    (v1->vce_index < v2->vce_index);
	} else {
		cmp = (v1->vce_function > v2->vce_function) -
		    (v1->vce_function < v2->vce_function);
	}

	return (cmp);
}

/*
 * Fix APIC ID and CPU family/model/stepping in function 0x00000001,
 * if necessary.
 */
static int
bhyve_fixup_cpuid_00000001(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce;

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000001, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	/*
	 * If unset, set a default family/model/stepping based on CPU
	 * vendor:
	 *
	 * AMD: family 0xf, model 6, stepping 1 (K8)
	 * Intel: family 6, model 15, stepping 1 (Core)
	 */
	if (vce->vce_eax == 0) {
		switch (vendor) {
		case VENDOR_AMD:
			vce->vce_eax = 0xf61;
			break;

		case VENDOR_INTEL:
		default:
			vce->vce_eax = 0x6f1;
			break;
		}
	}

	/* Set correct APIC ID. */
	vce->vce_ebx &= ~(CPUID_LOCAL_APIC_ID);
	vce->vce_ebx |= (vvcc->vvcc_vcpuid << CPUID_0000_0001_APICID_SHIFT);

	return (0);
}

/*
 * Clear Intel legacy Cache/TLB descriptors on AMD.
 */
static int
bhyve_fixup_cpuid_00000002(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce;

	if (vendor == VENDOR_INTEL)
		return (0);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000002, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	vce->vce_eax = 0;
	vce->vce_ebx = 0;
	vce->vce_ecx = 0;
	vce->vce_edx = 0;

	return (0);
}

/*
 * Clear Intel Deterministic Cache Parameters on AMD.
 */
static int
bhyve_fixup_cpuid_00000004(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce;
	uint32_t max_idx = cpuid_max_index(0x00000004, 0);
	uint32_t idx;

	if (vendor == VENDOR_INTEL)
		return (0);

	for (idx = 0; idx <= max_idx; idx++) {
		vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000004, idx);
		if (vce == NULL)
			return (-1);

		if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
			continue;

		vce->vce_eax = 0;
		vce->vce_ebx = 0;
		vce->vce_ecx = 0;
		vce->vce_edx = 0;
	}

	return (0);
}

/*
 * Fix x2APIC ID in function 0x0000000b, if necessary.
 */
static int
bhyve_fixup_cpuid_0000000b(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce;
	uint32_t max_idx = cpuid_max_index(0x0000000b, 0);
	uint32_t idx;

	for (idx = 0; idx != max_idx; idx++) {
		vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000b, idx);
		if (vce == NULL)
			return (-1);

		if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0)
			vce->vce_edx = vvcc->vvcc_vcpuid;
	}

	return (0);
}

/*
 * Fix CPUID leaf 0x0000000d indices based on supported states.
 */
static int
bhyve_fixup_cpuid_0000000d(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce0, *vce;
	uint64_t xcr0_xss;
	uint32_t max_idx;
	uint32_t idx;

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000001, 0);
	if (vce == NULL)
		return (-1);

	vce0 = bhyve_get_cpuid_config_entry(vvcc, 0x0000000d, 0);
	if (vce0 == NULL)
		return (-1);

	/* If XSAVE is unsupported, mark 0x0000000d invalid. */
	if ((vce->vce_ecx & CPUID2_XSAVE) == 0) {
		vce0->vce_flags |= VCE_FLAG_INVALID;
		return (0);
	}

	/* Get XCR0 supported states. */
	xcr0_xss = (uint64_t)vce0->vce_eax | ((uint64_t)vce0->vce_edx << 32);

	/* Get IA32_XSS supported states. */
	vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000d, 1);
	if (vce == NULL)
		return (-1);

	xcr0_xss |= (uint64_t)vce->vce_ecx | ((uint64_t)vce->vce_edx << 32);

	/*
	 * Mark indices 2 and up invalid if their respective feature bits
	 * aren't enabled in either XCR0 or IA32_XSS.
	 */
	max_idx = cpuid_max_index(0x0000000d, vce0->vce_eax);
	assert(max_idx >= 2);

	for (idx = 2; idx != max_idx; idx++) {
		if ((xcr0_xss & (1 << idx)) != 0)
			continue;

		vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000d, idx);
		if (vce == NULL)
			return (-1);

		vce->vce_flags |= VCE_FLAG_INVALID;
	}

	return (0);
}

/*
 * Clear Intel Deterministic Cache Parameters on AMD.
 */
static int
bhyve_fixup_cpuid_00000018(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce;

	if (vendor == VENDOR_INTEL)
		return (0);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000018, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	vce->vce_eax = 0;
	vce->vce_ebx = 0;
	vce->vce_ecx = 0;
	vce->vce_edx = 0;

	return (0);
}

/*
 * Fix x2APIC ID in function 0x00000001f, if necessary.
 */
static int
bhyve_fixup_cpuid_0000001f(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce;
	uint32_t max_idx = cpuid_max_index(0x00000001f, 0);
	uint32_t idx;

	for (idx = 0; idx != max_idx; idx++) {
		vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000001f, idx);
		if (vce == NULL)
			return (-1);

		if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0)
			vce->vce_edx = vvcc->vvcc_vcpuid;
	}

	return (0);
}

/*
 * Fix AMD leaf 0x80000000, which duplicate some information of 0x00000000
 * on AMD CPUs.
 */
static int
bhyve_fixup_cpuid_80000000(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce, *vce0;

	if (vendor != VENDOR_AMD)
		return (0);

	vce0 = bhyve_get_cpuid_config_entry(vvcc, 0x00000000, 0);
	if (vce0 == NULL)
		return (-1);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x80000000, 0);
	if (vce == NULL)
		return (-1);

	/*
	 * Only AMD CPUs since the K7 have done this, but it's probably
	 * not worth the hassle to check for the CPU family here.
	 */
	vce->vce_ebx = vce0->vce_ebx;
	vce->vce_ecx = vce0->vce_ecx;
	vce->vce_edx = vce0->vce_edx;

	return (0);
}

/*
 * Fix AMD leaf 0x80000000, which duplicate some information of 0x00000000
 * on AMD CPUs.
 */
#define	BHYVE_COMMON_FEATURES	(				\
	    CPUID_FPU | CPUID_VME | CPUID_DE | CPUID_PSE |	\
	    CPUID_TSC | CPUID_MSR | CPUID_PAE | CPUID_MCE |	\
	    CPUID_CX8 | CPUID_APIC |				\
	    CPUID_MTRR | CPUID_PGE | CPUID_MCA | CPUID_CMOV |	\
	    CPUID_PAT | CPUID_PSE36 |				\
	    CPUID_MMX |						\
	    CPUID_FXSR)

static int
bhyve_fixup_cpuid_80000001(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce, *vce0;

	if (vendor != VENDOR_AMD)
		return (0);

	vce0 = bhyve_get_cpuid_config_entry(vvcc, 0x00000001, 0);
	if (vce0 == NULL)
		return (-1);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x80000001, 0);
	if (vce == NULL)
		return (-1);

	vce->vce_eax = vce0->vce_eax;

	/*
	 * The AMD K6 family reported family 5 in 0x00000001 and
	 * family 6 in 0x80000001. Fix 0x00000001 here if this is
	 * a K6.
	 */
	if (CPUID_TO_FAMILY(vce->vce_eax) == 6) {
		vce0->vce_eax &= ~CPUID_FAMILY;
		vce0->vce_eax |= 0x500;
	}

	vce->vce_edx &= ~(BHYVE_COMMON_FEATURES);
	vce->vce_edx |= (vce0->vce_edx & BHYVE_COMMON_FEATURES);

	return (0);
}

/*
 * Clear AMD L1 Cache/TLB information on Intel
 */
static int
bhyve_fixup_cpuid_80000005(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce;

	if (vendor == VENDOR_AMD)
		return (0);

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x80000005, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	vce->vce_eax = 0;
	vce->vce_ebx = 0;
	vce->vce_ecx = 0;
	vce->vce_edx = 0;

	return (0);
}

/*
 * Clear AMD L2/L3 Cache/TLB information on Intel
 */
static int
bhyve_fixup_cpuid_80000006(struct vm_vcpu_cpuid_config *vvcc,
    enum bhyve_cpu_vendor vendor)
{
	struct vcpu_cpuid_entry *vce, *vce4;
	uint32_t max_idx = cpuid_max_index(0x00000004, 0);
	uint32_t ecx = 0;
	uint32_t idx;

	if (vendor == VENDOR_AMD)
		return (0);


	vce = bhyve_get_cpuid_config_entry(vvcc, 0x80000006, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	/*
	 * Intel CPUs that support this leaf put their L2 parameters in ECX.
	 * All of those CPUs do also support leaf 0x00000004, so get the L2
	 * parameters from there to put it in ECX of leaf 0x80000006.
	 */
	for (idx = 0; idx <= max_idx; idx++) {
		vce4 = bhyve_get_cpuid_config_entry(vvcc, 0x00000004, idx);
		if (vce4 == NULL)
			return (-1);

		if ((vce4->vce_eax & 0x3) == 0)
			break;

		if ((vce4->vce_eax & 0xff) == 0x43) {
			uint64_t ways = 1 + ((vce4->vce_ebx >> 22) & 0x3ff);
			uint64_t part = 1 + ((vce4->vce_ebx >> 12) & 0x3ff);
			uint64_t line = 1 + (vce4->vce_ebx & 0xfff);
			uint64_t sets = 1 + vce4->vce_ecx;

			ecx = ((line * part * ways * sets) >> 10) << 16;
			ecx |= line;
			ecx |=
			    ways >= 256 ? 0xf000 :
			    ways >= 128 ? 0xe000 :
			    ways >= 96 ? 0xd000 :
			    ways >= 64 ? 0xc000 :
			    ways >= 48 ? 0xb000 :
			    ways >= 32 ? 0xa000 :
			    ways >= 16 ? 0x8000 :
			    ways >= 8 ? 0x6000 :
			    ways >= 4 ? 0x4000 :
			    ways >= 2 ? 0x2000 :
			    ways >= 1 ? 0x1000 : 0;
			break;
		}
	}

	vce->vce_eax = 0;
	vce->vce_ebx = 0;
	vce->vce_ecx = ecx;
	vce->vce_edx = 0;

	return (0);
}

/*
 * Fix AMD Family 16h+ and Hygon Family 18h topology, if necessary.
 */
static int
bhyve_fixup_cpuid_8000001e(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce;

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x8000001E, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) == 0)
		return (0);

	vce->vce_eax = vvcc->vvcc_vcpuid;
	vce->vce_ebx &= 0xffffff00;
	vce->vce_ebx |= (vvcc->vvcc_vcpuid >> fls(cpu_threads));

	return (0);
}

static bool
bhyve_match_cpuid_vendor(struct vcpu_cpuid_entry *vce,
    enum bhyve_cpu_vendor vendor)
{
	if (vce->vce_ebx !=
	    *(const uint32_t *)&bhyve_cpu_vendors[vendor].bcv_ident[0])
		return (false);

	if (vce->vce_edx !=
	    *(const uint32_t *)&bhyve_cpu_vendors[vendor].bcv_ident[4])
		return (false);

	if (vce->vce_ecx !=
	    *(const uint32_t *)&bhyve_cpu_vendors[vendor].bcv_ident[8])
		return (false);

	return (true);
}

/*
 * Traverse a vcpu config entries array and perform fixups and checks:
 * - discard all entries if the flags indicate "legacy" CPUID emulation
 * - sort the array by function/index
 * - perform leaf-specific fixups
 * - remove entries with invalid index
 * - remove "unreachable" entries
 * - remove INVALID entries
 * - set the MATCH INDEX flag on entries that need it
 * - clear the MODIFIED flag
 * - exit with an error if we encounter any duplicates of function and
 *   index, which aren't allowed.
 */
static int
bhyve_fixup_cpuid_config(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce, *last_vce, *last_vce_idx0;
	uint32_t max_function;
	enum bhyve_cpu_vendor vendor;

	if ((vvcc->vvcc_flags & VCC_FLAG_LEGACY_HANDLING) != 0) {
		free(vvcc->vvcc_entries);
		vvcc->vvcc_nent = 0;
		vvcc->vvcc_ent_sz = 0;
		vvcc->vvcc_entries = NULL;
		return (0);
	}

	if (vvcc->vvcc_entries == NULL)
		return (-1);

	/* Get the first entry in the array. */
	last_vce_idx0 = last_vce = vvcc->vvcc_entries;

	/* This really should be function 0x00000000, index 0x000 */
	assert(last_vce_idx0->vce_function == 0x00000000);
	assert(last_vce_idx0->vce_index == 0x000);
	last_vce_idx0->vce_flags &= ~VCE_FLAG_MODIFIED;

	max_function = last_vce_idx0->vce_eax;

	/* Get the CPU vendor. We relly only care about Intel/AMD for now. */
	if (bhyve_match_cpuid_vendor(last_vce_idx0, VENDOR_INTEL))
		vendor = VENDOR_INTEL;
	else if (bhyve_match_cpuid_vendor(last_vce_idx0, VENDOR_AMD))
		vendor = VENDOR_AMD;
	else
		vendor = VENDOR_UNKNOWN;

	if (bhyve_fixup_cpuid_00000001(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_00000002(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_00000004(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_0000000b(vvcc) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_0000000d(vvcc) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_00000018(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_0000001f(vvcc) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_80000000(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_80000001(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_80000005(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_80000006(vvcc, vendor) != 0)
		return (-1);

	if (bhyve_fixup_cpuid_8000001e(vvcc) != 0)
		return (-1);

	/*
	 * The kernel wants the cpuid entries in sorted in ascending order.
	 * Also, the code further down relies on the ordering.
	 */
	qsort(vvcc->vvcc_entries, vvcc->vvcc_nent,
	    sizeof (struct vcpu_cpuid_entry), bhyve_compare_cpuid_entries);

	/*
	 * Check each entry in the array:
	 * - remove invalid or unreachable entries
	 * - check for duplicates
	 * - set the MATCH INDEX flag where necessary
	 * - clear the MODIFIED flag
	 */
	for (vce = &vvcc->vvcc_entries[1];
	    vce != &vvcc->vvcc_entries[vvcc->vvcc_nent];
	    vce++) {
		struct vcpu_cpuid_entry *save_vce = vce;

		/* Skip over invalid entries, if any. */
		for (; vce != &vvcc->vvcc_entries[vvcc->vvcc_nent]; vce++) {
			if (((vce->vce_function & CPUID_FUNC_MASK) == 0) ||
			    (CPUID_TYPE(vce->vce_function) == CPUID_TYPE_HV &&
			    (vce->vce_function & CPUID_HV_FUNC_MASK) == 0))
				max_function = vce->vce_eax;

			if (vce->vce_index == 0)
				last_vce_idx0 = vce;

			if (cpuid_index_valid(vvcc, last_vce_idx0, vce) &&
			    (vce->vce_function <= max_function) &&
			    (vce->vce_flags & VCE_FLAG_INVALID) == 0)
				break;
		}

		/* Get rid of the invalid entries, if any. */
		if (save_vce != vce) {
			(void) memmove(save_vce, vce,
			    (&vvcc->vvcc_entries[vvcc->vvcc_nent] - vce) *
			    sizeof(struct vcpu_cpuid_entry));
			vvcc->vvcc_nent -= (vce - save_vce);

			if (save_vce >= &vvcc->vvcc_entries[vvcc->vvcc_nent])
				break;

			vce = save_vce;
		}

		if (vce->vce_function == last_vce->vce_function) {
			if (vce->vce_index == last_vce->vce_index) {
				warnx("duplicate CPUID entry 0x%.8x,0x%.2x",
				    vce->vce_function, vce->vce_index);
				return (-1);
			}
			last_vce->vce_flags |= VCE_FLAG_MATCH_INDEX;
			vce->vce_flags |= VCE_FLAG_MATCH_INDEX;
		}

		vce->vce_flags &= ~VCE_FLAG_MODIFIED;
		last_vce = vce;
	}

	return (0);
}

/*
 * Find the next CPUID constraint for this CPUID action, if any.
 */
static const struct bhyve_cpuid_constraint *
bhyve_get_next_cpuid_constraint(const struct bhyve_cpuid_constraint *bcc,
    uint32_t function, int32_t index, enum vce_reg reg)
{
	const struct bhyve_cpuid_constraint *end =
	    &bhyve_cpuid_constraints[nitems(bhyve_cpuid_constraints)];

	assert(bcc >= bhyve_cpuid_constraints);

	for (; bcc < end; bcc++) {
		if (function > bcc->bcc_function)
			continue;

		if (function < bcc->bcc_function)
			return (NULL);

		if (bcc->bcc_index != -1 &&
		    index > bcc->bcc_index)
			continue;

		if (index < bcc->bcc_index)
			return (NULL);

		if (bcc->bcc_reg != VCE_REG_ANY &&
		    reg > bcc->bcc_reg)
			continue;

		if (reg < bcc->bcc_reg)
			return (NULL);

		return (bcc);
	}

	return (NULL);
}

/*
 * Check a CPUID entry against the CPUID constraints.
 *
 * There may be more than one constraint per CPUID entry. No constraints
 * means the values are valid.
 */
static bool
bhyve_check_cpuid_constraint(uint32_t func, uint32_t idx, enum vce_reg reg,
    uint32_t *val, uint32_t orig_val, bool fail, bool fix)
{
	const struct bhyve_cpuid_constraint *bcc;

	bcc = bhyve_get_next_cpuid_constraint(bhyve_cpuid_constraints, func,
	    idx, reg);
	if (bcc == NULL)
		return (true);

	do {
		if (bcc->bcc_immutable != 0 &&
		    (orig_val & bcc->bcc_immutable) !=
		    (*val & bcc->bcc_immutable)) {
			warnx("bhyve_check_cpuid_constraint: Can't change "
			    "immutable CPUID bits: 0x%.8x,0x%.2x %s: "
			    "0x%.8x -> 0x%.8x", func, idx, bhyve_regs[reg],
			    orig_val & bcc->bcc_immutable,
			    *val & bcc->bcc_immutable);

			if (fail)
				return (false);

			if (fix) {
				*val &= ~bcc->bcc_immutable;
				*val |= orig_val & bcc->bcc_immutable;
			}
		}

		if (bcc->bcc_clear != 0 &&
		    (*val & bcc->bcc_clear & ~orig_val) != 0) {
			warnx("bhyve_check_cpuid_constraint(): Can't set "
			    "clear-only CPUID bits: 0x%.8x,0x%.2x %s: 0x%.8x",
			    func, idx, bhyve_regs[reg],
			    *val & bcc->bcc_clear & ~orig_val);

			if (fail)
				return (false);

			if (fix) {
				*val &= ~(~orig_val & bcc->bcc_clear & *val);
			}
		}

		if (bcc->bcc_lower != 0 &&
		    (*val & bcc->bcc_lower) >
		    (orig_val & bcc->bcc_lower)) {
			warnx("bhyve_check_cpuid_constraint(): Can't increase "
			    "lower-only CPUID bits: 0x%.8x,0x%.2x %s: "
			    "0x%.8x > 0x%.8x", func, idx, bhyve_regs[reg],
			    *val & bcc->bcc_lower, orig_val & bcc->bcc_lower);

			if (fail)
				return (false);

			if (fix) {
				*val &= ~bcc->bcc_lower;
				*val |= orig_val & bcc->bcc_lower;
			}
		}

		bcc = bhyve_get_next_cpuid_constraint(bcc + 1, func, idx, reg);
	} while (bcc != NULL);

	return (true);
}

/*
 * Check a whole CPUID configuration against the CPUID constraints.
 */
static int
bhyve_check_cpuid_constraints(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu *vcpu = fbsdrun_vcpu(vvcc->vvcc_vcpuid);
	bool fail = true;
	bool fix = false;

	if ((vvcc->vvcc_flags & VCC_FLAG_LEGACY_HANDLING) != 0)
		goto out;

	if ((vvcc->vvcc_flags & VCC_FLAG_CHECK_SKIP) != 0)
		goto out;

	if ((vvcc->vvcc_flags & VCC_FLAG_CHECK_WARN) != 0)
		fail = false;

	if ((vvcc->vvcc_flags & VCC_FLAG_CHECK_FIX) != 0)
		fix = true;

	for (uint32_t i = 0; i != vvcc->vvcc_nent; i++) {
		struct vcpu_cpuid_entry *vce = &vvcc->vvcc_entries[i];
		struct vm_legacy_cpuid vlc;
		uint32_t base;

		base = cpuid_base_function(vce->vce_function);
		if (bhyve_get_legacy_cpuid(vcpu, &vlc, base, 0) != 0)
			return (-1);

		if (vce->vce_function > vlc.vlc_eax || vce->vce_index >
		    cpuid_max_index(vce->vce_function, vlc.vlc_eax)) {
			bzero(&vlc, sizeof (vlc));
		} else {
			(void) bhyve_get_legacy_cpuid(vcpu, &vlc,
			    vce->vce_function, vce->vce_index);
		}

		for (int reg = 0; reg != 4; reg++) {
			if (!bhyve_check_cpuid_constraint(vce->vce_function,
			    vce->vce_index, reg, &vce->vce_regs[reg],
			    vlc.vlc_regs[reg], fail, fix))
				return (-1);
		}
	}

out:
	vvcc->vvcc_flags &= VCC_FLAGS_VALID;
	return (0);
}

/*
 * Get the CPUID values for a function and index from the legacy CPUID emulation
 * for a VCPU.
 */
static int
bhyve_get_legacy_cpuid(struct vcpu *vcpu, struct vm_legacy_cpuid *vlc,
    uint32_t function, uint32_t index)
{
	int error;

	bzero(vlc, sizeof(struct vm_legacy_cpuid));
	vlc->vlc_eax = function;
	vlc->vlc_ecx = index;

	error = vm_legacy_cpuid(vcpu, vlc);
	if (error != 0) {
		warn("bhyve_get_legacy_cpuid(): "
		    "failed to fetch CPUID 0x%.8x,0x%.2x", function, index);
	}

	return (error);
}

/*
 * Get the CPUID values for a function and index from the legacy CPUID emulation
 * for a VCPU, and enter it into the vm_vcpu_cpuid_config for this VCPU.
 */
static struct vcpu_cpuid_entry *
bhyve_get_legacy_cpuid_function_index(uint32_t function, uint32_t index,
    struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu *vcpu;
	struct vm_legacy_cpuid vlc;
	struct vcpu_cpuid_entry *vce;
	int error;

	vcpu = fbsdrun_vcpu(vvcc->vvcc_vcpuid);

	error = bhyve_get_legacy_cpuid(vcpu, &vlc, function, index);
	if (error != 0)
		return (NULL);

	vce = bhyve_get_cpuid_config_entry(vvcc, function, index);
	if (vce == NULL)
		return (NULL);

	vce->vce_eax = vlc.vlc_eax;
	vce->vce_ebx = vlc.vlc_ebx;
	vce->vce_ecx = vlc.vlc_ecx;
	vce->vce_edx = vlc.vlc_edx;

	return (vce);
}

/*
 * Get the CPUID values for a function and all its indices from the legacy CPUID
 * emulation for a VCPU and enter them into the vm_vcpu_cpuid_config for this
 * VCPU.
 *
 * Return the CPUID config entry for index 0.
 */
static struct vcpu_cpuid_entry *
bhyve_get_legacy_cpuid_function(uint32_t function,
    struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce0;
	uint32_t max_index;

	vce0 = bhyve_get_legacy_cpuid_function_index(function, 0, vvcc);
	if (vce0 == NULL)
		return (NULL);

	max_index = cpuid_max_index(function, vce0->vce_eax);

	if (max_index > 0)
		vce0->vce_flags |= VCE_FLAG_MATCH_INDEX;

	for (uint32_t index = 1; index <= max_index; index++) {
		struct vcpu_cpuid_entry *vce;

		vce = bhyve_get_legacy_cpuid_function_index(function, index,
		    vvcc);
		if (vce == NULL)
			return (NULL);

		if (!cpuid_index_valid(vvcc, vce0, vce)) {
			vce->vce_flags |= VCE_FLAG_INVALID;
			break;
		}

		vce->vce_flags |= VCE_FLAG_MATCH_INDEX;
	}

	return (vce0);
}

/*
 * Populate a vm_vcpu_cpuid_config structure with the CPUID values from the
 * CPUID set beginning at the given function, fetched from the legacy CPUID
 * emulation for the given VCPU.
 *
 * The given function must be function 0 within its CPUID set and return the
 * maximum number of functions in EAX.
 */
static struct vcpu_cpuid_entry *
bhyve_get_legacy_cpuid_set(uint32_t function, struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce0;
	uint32_t max_function;

	if (function != cpuid_base_function(function))
		return (NULL);

	vce0 = bhyve_get_legacy_cpuid_function(function, vvcc);
	if (vce0 == NULL)
		return (NULL);

	max_function = vce0->vce_eax;

	for (function += 1; function <= max_function; function++) {
		if (bhyve_get_legacy_cpuid_function(function, vvcc) == NULL)
			return (NULL);
	}

	return (vce0);
}

/*
 * Get the whole set of CPUID information from the legacy emulation for
 * this vcpu, populating an vm_vcpu_cpuid_config structure.
 *
 * There are several sets of CPUID functions, some of which we can safely
 * ignore:
 * - 0x0000_0000: Standard CPUID functions
 * - 0x2000_0000: Intel Xeon PHI functions (ignored, we don't run on Xeon PHI)
 * - 0x4000_0000: Hypervisor CPUID functions (may be overridden)
 * - 0x4000_0100: bhyve CPUID functions (must not be overridden)
 * - 0x8000_0000: Extended CPUID functions
 * - 0x8fff_fffe: AMD Easter Egg (ignored)
 * - 0xC000_0000: Centaur CPUID functions (ignored, we don't run on Centaur)
 */
static int
bhyve_build_legacy_cpuid_config(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce0;

	vce0 = bhyve_get_legacy_cpuid_set(0x00000000, vvcc);
	if (vce0 == NULL)
		return (-1);

	if (bhyve_get_legacy_cpuid_set(0x40000000, vvcc) == NULL)
		return (-1);

	if (bhyve_get_legacy_cpuid_set(0x40000100, vvcc) == NULL)
		return (-1);

	if (bhyve_get_legacy_cpuid_set(0x80000000, vvcc) == NULL)
		return (-1);

	/*
	 * If this is an Intel CPU, set the default fallback behavior
	 * accordingly.
	 */
	if (bhyve_match_cpuid_vendor(vce0, VENDOR_INTEL))
		vvcc->vvcc_flags |= VCC_FLAG_INTEL_FALLBACK;

	/* Set the "legacy" flag as this is all "legacy" emulated CPUID data. */
	vvcc->vvcc_flags |= VCC_FLAG_LEGACY_HANDLING;

	return (0);
}

/*
 * Build the per-VCPU CPUID configuration from any vcpu.X.cpuid.* config
 * options, if any.
 */
int
bhyve_init_vcpu_cpuid_config(struct vcpu *vcpu)
{
	static struct bhyve_cpuid_action_queue *global_cpuid_actq;

	struct bhyve_cpuid_action_queue vcpu_actq =
	    STAILQ_HEAD_INITIALIZER(vcpu_actq);
	struct vm_vcpu_cpuid_config vcpu_vvcc = { 0 };
	char *node_name = NULL;
	int ret = -1;

	/*
	 * If the global CPUID action queue is still empty, parse the
	 * global "cpuid" config options, if any, into the global queue.
	 */
	if (global_cpuid_actq == NULL) {
		global_cpuid_actq = calloc(1, sizeof(*global_cpuid_actq));
		STAILQ_INIT(global_cpuid_actq);

		ret = bhyve_build_cpuid_action_queue("cpuid",
		    global_cpuid_actq);

		if (ret != 0)
			goto out;
	}

	/*
	 * Parse the per-VCPU "vcpu.X.cpuid" config options, if any, into
	 * a per-VCPU CPUID action queue.
	 */
	asprintf(&node_name, "vcpu.%d.cpuid", vcpu_id(vcpu));
	if (node_name == NULL) {
		warn("Failed to allocate node name for CPUID config");
		ret = -1;
		goto out;
	}
	ret = bhyve_build_cpuid_action_queue(node_name, &vcpu_actq);
	if (ret != 0)
		goto out;

	/* If there's no work to be done, get out of here. */
	if (STAILQ_EMPTY(global_cpuid_actq) && STAILQ_EMPTY(&vcpu_actq))
		goto out;

	/*
	 * Pre-populate the per-VCPU config with "legacy" emulated CPUID values.
	 *
	 * This will always set the LEGACY flag in vcpu_vvcc, which will cause
	 * all entries to be discarded during fixup unless cleared by applying
	 * CPUID actions.
	 */
	vcpu_vvcc.vvcc_vcpuid = vcpu_id(vcpu);
	ret = bhyve_build_legacy_cpuid_config(&vcpu_vvcc);
	if (ret != 0)
		goto out;

	/* Apply the global CPUID actions to the per-VCPU CPUID configuration */
	ret = bhyve_apply_cpuid_actions(&vcpu_vvcc, global_cpuid_actq);
	if (ret != 0)
		goto out;

	/* Apply the per-VCPU CPUID actions. */
	ret = bhyve_apply_cpuid_actions(&vcpu_vvcc, &vcpu_actq);
	if (ret != 0)
		goto out;

	/* Perform any needed fixups before we hand it to the kernel. */
	ret = bhyve_fixup_cpuid_config(&vcpu_vvcc);
	if (ret != 0)
		goto out;

	ret = bhyve_check_cpuid_constraints(&vcpu_vvcc);
	if (ret != 0)
		goto out;

	ret = vm_set_cpuid(vcpu, &vcpu_vvcc);
	if (ret != 0)
		warn("vm_set_cpuid()");

out:
	/*
	 * We don't currently keep the per-VCPU CPUID config around as it is
	 * only used by the kernel so far.
	 */
	if (vcpu_vvcc.vvcc_entries != NULL)
		free(vcpu_vvcc.vvcc_entries);

	while (!STAILQ_EMPTY(&vcpu_actq)) {
		struct bhyve_cpuid_action *tmp = STAILQ_FIRST(&vcpu_actq);

		STAILQ_REMOVE_HEAD(&vcpu_actq, bca_link);
		free(tmp);
	}

	free(node_name);

	return (ret);
}
