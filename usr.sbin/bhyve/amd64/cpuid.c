/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Hans Rosenfeld
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

enum bhyve_cpuid_op { CPUID_OP_SET, CPUID_OP_OR, CPUID_OP_AND };

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

static bhyve_set_cpuid_opt_t bhyve_set_cpuid_fallback_style;

static const struct {
	const char		*opt_name;
	bhyve_set_cpuid_opt_t	*opt_func;
} bhyve_cpuid_options[] = {
	{ "fallback-style", bhyve_set_cpuid_fallback_style },
};


/*
 * CPUID data validity checks
 *
 * We define two bitmasks for each CPUID constraint:
 * - immutable, bits which may not be changed at all
 *   (e.g. CPU Vendor Identification)
 * - clear only, bits which may only cleared
 *   (e.g. CPU features which aren't emulated)
 *
 * The array must be sorted by function, index, and register.
 */
static const struct bhyve_cpuid_constraint {
	uint32_t	bcc_function;
	uint32_t	bcc_index;
	enum vce_reg	bcc_reg;
	uint32_t	bcc_immutable;
	uint32_t	bcc_clear;
} bhyve_cpuid_constraints[] = {
	/* 0x00000000,0x00, ebx, ecx, edx: Vendor Identification */
	{ 0x00000000, 0x00, VCE_REG_EBX, 0xffffffff, 0 },
	{ 0x00000000, 0x00, VCE_REG_ECX, 0xffffffff, 0 },
	{ 0x00000000, 0x00, VCE_REG_EDX, 0xffffffff, 0 },

	/*
	 * 0x00000001, 0x00, ecx: Standard Features
	 * v2: SSE3, VMX, SSSE3, CX16, SSE41, SSE42, POPCNT
	 * v3: FMA, MOVBE, OSXSAVE, AVX, F16C
	 */
	{
		.bcc_function = 0x00000001,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = 0,
		.bcc_clear = (CPUID2_SSE3 | CPUID2_VMX | CPUID2_SSSE3 |
		    CPUID2_SSE41 | CPUID2_SSE42 | CPUID2_POPCNT | CPUID2_FMA |
		    CPUID2_MOVBE | CPUID2_OSXSAVE | CPUID2_AVX | CPUID2_F16C)
	},

	/*
	 * 0x00000001, 0x00, edx: Standard Features
	 * v1: FPU, CX8, CMOV, MMX, FXSR, SSE, SSE2
	 */
	{
		.bcc_function = 0x00000001,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EDX,
		.bcc_immutable = 0,
		.bcc_clear = (CPUID_FPU | CPUID_CX8 | CPUID_CMOV | CPUID_MMX |
		    CPUID_FXSR | CPUID_SSE | CPUID_SSE2)
	},

	/*
	 * 0x00000007, 0x00, ebx: Structured Extended Features
	 * v3: BMI1, AVX2, BMI2
	 * v4: AVX512F, AVX512DQ, AVX512BW, AVX512VL
	 * beyond v4: AVX512PF, AVX512ER, AVX512CD, SHA
	 */
	{
		.bcc_function = 0x00000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_EBX,
		.bcc_immutable = 0,
		.bcc_clear = (CPUID_STDEXT_BMI1 | CPUID_STDEXT_AVX2 |
		    CPUID_STDEXT_BMI2 | CPUID_STDEXT_AVX512F |
		    CPUID_STDEXT_AVX512DQ | CPUID_STDEXT_AVX512BW |
		    CPUID_STDEXT_AVX512VL | CPUID_STDEXT_AVX512PF |
		    CPUID_STDEXT_AVX512ER | CPUID_STDEXT_AVX512CD |
		    CPUID_STDEXT_SHA)
	},

	/*
	 * 0x00000007, 0x00, ecx: Structured Extended Features
	 * beyond v4: VAES, VPCLMULQDQ
	 */
	{
		.bcc_function = 0x00000007,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = 0,
		.bcc_clear = (CPUID_STDEXT2_VAES | CPUID_STDEXT2_VPCLMULQDQ)
	},

	/*
	 * 0x80000001, 0x00: ecx: AMD Extended Features
	 * v2: LAHF
	 * v3: ABM
	 */
	{
		.bcc_function = 0x80000001,
		.bcc_index = 0x00,
		.bcc_reg = VCE_REG_ECX,
		.bcc_immutable = 0,
		.bcc_clear = (AMDID2_LAHF | AMDID2_ABM)
	}
};

static bool cpuid_0x0000000d_index_valid(struct vm_vcpu_cpuid_config *,
    uint32_t);
static bool cpuid_index_valid(struct vm_vcpu_cpuid_config *,
    const struct vcpu_cpuid_entry *, const struct vcpu_cpuid_entry *);
static uint32_t cpuid_max_index(uint32_t, uint32_t);

static int bhyve_cpuid_compare(const void *, const void *);
static const struct bhyve_cpuid_constraint *bhyve_get_cpuid_constraint(
    const struct bhyve_cpuid_action *);
static bool bhyve_check_cpuid_constraints(const struct vcpu_cpuid_entry *,
    const struct bhyve_cpuid_action *);

static struct vcpu_cpuid_entry *bhyve_alloc_cpuid_config_entry(
    struct vm_vcpu_cpuid_config *, uint32_t, uint32_t);
static struct vcpu_cpuid_entry *bhyve_get_cpuid_config_entry(
    struct vm_vcpu_cpuid_config *, uint32_t, uint32_t);

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
static int bhyve_fixup_cpuid_config(struct vm_vcpu_cpuid_config *);

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

	/* Assume index 0 is always valid. */
	if (vce->vce_index == 0)
		return (true);

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
 * Return the maxmimum index value for a given CPUID function. For most
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
 * Comparison function for bhyve_get_cpuid_constraint()
 *
 * Compares a CPUID action against a CPUID constraint,
 * checking function, index, and register in this order.
 */
static int
bhyve_cpuid_compare(const void *a, const void *c)
{
	const struct bhyve_cpuid_action *act = a;
	const struct bhyve_cpuid_constraint *bcc = c;

	if (act->bca_function < bcc->bcc_function)
		return (-1);
	else if (act->bca_function > bcc->bcc_function)
		return (1);
	else if (act->bca_index < bcc->bcc_index)
		return (-1);
	else if (act->bca_index > bcc->bcc_index)
		return (1);
	else if (act->bca_reg < bcc->bcc_reg)
		return (-1);
	else if (act->bca_reg > bcc->bcc_reg)
		return (1);
	else
		return (0);
}

/*
 * Find a CPUID constraint for this CPUID action, if any.
 */
static const struct bhyve_cpuid_constraint *
bhyve_get_cpuid_constraint(const struct bhyve_cpuid_action *bca)
{
	return (bsearch(bca, bhyve_cpuid_constraints,
	    nitems(bhyve_cpuid_constraints),
	    sizeof(struct bhyve_cpuid_constraint), bhyve_cpuid_compare));
}

/*
 * Check a CPUID action against the CPUID constraints for a CPUID
 * entry.
 */
static bool
bhyve_check_cpuid_constraints(const struct vcpu_cpuid_entry *vce,
    const struct bhyve_cpuid_action *bca)
{
	static const char *regs[] = { "EAX", "EBX", "ECX", "EDX" };

	const struct bhyve_cpuid_constraint *bcc;
	struct vcpu_cpuid_entry tmp_vce;
	uint32_t function = bca->bca_function;
	uint32_t index = bca->bca_index;
	enum vce_reg reg = bca->bca_reg;
	uint32_t val = bca->bca_val;

	bcc = bhyve_get_cpuid_constraint(bca);

	if (bcc == NULL)
		return (true);

	memcpy(&tmp_vce, vce, sizeof(tmp_vce));
	bhyve_process_cpuid_action(&tmp_vce, bca);

	if (bcc->bcc_immutable != 0 &&
	    (tmp_vce.vce_regs[reg] & bcc->bcc_immutable) !=
	    (vce->vce_regs[reg] & bcc->bcc_immutable)) {
		warnx("bhyve_apply_cpuid_action(): Can't change immutable CPUID"
		    " bits: 0x%.8x,0x%.3x %s: 0x%.8x", function, index,
		    regs[reg], val & bcc->bcc_immutable);
		return (false);
	}

	if ((bca->bca_op != CPUID_OP_AND) &&
	    (val & bcc->bcc_clear & ~vce->vce_regs[reg]) != 0) {
		warnx("bhyve_apply_cpuid_action(): Can't set clear-only CPUID"
		    " bits: 0x%.8x,0x%.3x %s: 0x%.8x", function, index,
		    regs[reg], val & bcc->bcc_clear & ~vce->vce_regs[reg]);
		return (false);
	}

	return (true);
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
	uint32_t i;

	for (i = 0; i < vvcc->vvcc_nent; i++) {
		if (vce[i].vce_function != function)
			continue;

		if ((vce[i].vce_flags & VCE_FLAG_MATCH_INDEX) == 0 ||
		    vce[i].vce_index == index) {
			return (&vce[i]);
		}
	}

	return (bhyve_alloc_cpuid_config_entry(vvcc, function, index));
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

	if (strcmp(value, "intel") == 0) {
		act->bca_op = CPUID_OP_OR;
		act->bca_val = VCC_FLAG_INTEL_FALLBACK;
	} else if (strcmp(value, "amd") == 0) {
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
	assert(vce->vce_function == bca->bca_function);
	assert(vce->vce_index == bca->bca_index);
	assert(bca->bca_reg <= VCE_REG_EDX);

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
				warnx("bhyve_add_cpuid_config_entry(): "
				    "invalid global flag on per-VCPU config "
				    "'%s': %s", prefix, name);
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
	/*
	 * To check against the user-provided CPUID configuration entry against
	 * the CPUID constraints, we need the emulated CPUID values for this
	 * vCPU as a baseline to check against. At this time we require that all
	 * CPUID values to which certain constraints apply are the same for all
	 * vCPUs (e.g. vendor identification, ISA features), so we can just use
	 * vCPU 0 here to keep things simple.
	 *
	 * We'll keep any queried CPUID values around in case they are used more
	 * than once.
	 */
	static struct vm_vcpu_cpuid_config vcpu0_vvcc;

	struct bhyve_cpuid_action_queue *actq = arg;
	uint32_t function = 0, index = 0;
	const struct vcpu_cpuid_entry *vce;
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

	vce = bhyve_get_legacy_cpuid_function_index(function, index,
	    &vcpu0_vvcc);

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

		if (bhyve_check_cpuid_constraints(vce, act) == false) {
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
 * Traverse a vcpu config entries array and perform fixups and checks:
 * - discard all entries if the flags indicate "legacy" CPUID emulation
 * - sort the array by function/index
 * - write the correct vCPU ID in each CPUID entry that needs it, in case
 *   it was manually overwritten
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

	if ((vvcc->vvcc_flags & VCC_FLAG_LEGACY_HANDLING) != 0) {
		free(vvcc->vvcc_entries);
		vvcc->vvcc_nent = 0;
		vvcc->vvcc_ent_sz = 0;
		vvcc->vvcc_entries = NULL;
		return (0);
	}

	if (vvcc->vvcc_entries == NULL)
		return (-1);

	/*
	 * The kernel wants the cpuid entries in sorted in ascending order.
	 * Also, the code further down relies on the ordering.
	 */
	qsort(vvcc->vvcc_entries, vvcc->vvcc_nent,
	    sizeof (struct vcpu_cpuid_entry), bhyve_compare_cpuid_entries);

	/* Get the first entry in the array. */
	last_vce_idx0 = last_vce = vvcc->vvcc_entries;

	/* This really should be function 0x00000000, index 0x000 */
	assert(last_vce_idx0->vce_function == 0x00000000);
	assert(last_vce_idx0->vce_index == 0x000);
	last_vce_idx0->vce_flags &= ~VCE_FLAG_MODIFIED;

	max_function = last_vce_idx0->vce_eax;

	/* Fix APIC ID in function 0x00000001, if necessary. */
	vce = bhyve_get_cpuid_config_entry(vvcc, 0x00000001, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0) {
		vce->vce_ebx &= ~(CPUID_LOCAL_APIC_ID);
		vce->vce_ebx |=
		    (vvcc->vvcc_vcpuid << CPUID_0000_0001_APICID_SHIFT);
	}

	/* Fix x2APIC ID in function 0x0000000b, if necessary. */
	vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000b, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0)
		vce->vce_edx = vvcc->vvcc_vcpuid;

	vce = bhyve_get_cpuid_config_entry(vvcc, 0x0000000b, 1);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0)
		vce->vce_edx = vvcc->vvcc_vcpuid;

	/* Fix AMD Family 16h+ and Hygon Family 18h topology, if necessary. */
	vce = bhyve_get_cpuid_config_entry(vvcc, 0x8000001E, 0);
	if (vce == NULL)
		return (-1);

	if ((vce->vce_flags & VCE_FLAG_MODIFIED) != 0) {
		vce->vce_eax = vvcc->vvcc_vcpuid;
		vce->vce_ebx &= 0xffffff00;
		vce->vce_ebx |= (vvcc->vvcc_vcpuid >> fls(cpu_threads));
	}

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

			if (vce->vce_flags & VCE_FLAG_MODIFIED) {
				warnx("invalid CPUID entry 0x%.8x,0x%.3x",
				    vce->vce_function, vce->vce_index);
				return (-1);
			}
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
				warnx("duplicate CPUID entry 0x%.8x,0x%.3x",
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

	bzero(&vlc, sizeof(vlc));
	vlc.vlc_eax = function;
	vlc.vlc_ecx = index;

	error = vm_legacy_cpuid(vcpu, &vlc);
	if (error != 0) {
		warn("bhyve_fetch_legacy_cpuid_function_index(): "
		    "failed to fetch CPUID 0x%.8x,0x%.3x", function, index);

		return (NULL);
	}

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

	/* Of course, there's always an exception to every rule. */
	if (CPUID_TYPE(function) != CPUID_TYPE_HV)
		assert((function & CPUID_FUNC_MASK) == 0);
	else
		assert((function & CPUID_HV_FUNC_MASK) == 0);

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
	if (vce0->vce_ebx == 0x756e6547 &&
	    vce0->vce_edx == 0x49656e69 &&
	    vce0->vce_ecx == 0x6c65746e) {
		vvcc->vvcc_flags |= VCC_FLAG_INTEL_FALLBACK;
	}

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
