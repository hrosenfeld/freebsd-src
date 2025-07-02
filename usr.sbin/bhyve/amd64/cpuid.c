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

/*
 * Count the number of "[vcpu.X.]cpuid.*" config options by counting the
 * number of times being called.
 */
static int
bhyve_count_cpuid_entry(const char *prefix, const nvlist_t *parent __unused,
    const char *name, int type, void *arg)
{
	struct vm_vcpu_cpuid_config *vvcc = arg;

	if (type != NV_TYPE_STRING)
		errx(4, "bhyve_count_cpuid_entry: "
		    "leaf/index \"%s\" not string type", name);

	/*
	 * Don't count any of the known global flags:
	 * - fallback-style={intel|amd}
	 *
	 * Also, error out if any flag is set on a per-vcpu cpuid config.
	 */
	if (strcmp(name, "fallback-style") == 0) {
		if (strcmp(prefix, "cpuid") != 0) {
			errx(4, "bhyve_count_cpuid_entry: "
			    "invalid global flag %s on per-vcpu config %s",
			    name, prefix);
		}
	} else {
		vvcc->vvcc_nent++;
	}

	return (0);
}

/*
 * Parse a single cpuid options into a struct vcpu_cpuid_entry and place it
 * into the next slot of the entries array of a struct vm_vcpu_cpuid_config.
 *
 * The entries array needs to be pre-allocated large enough to hold all
 * entries, there is no check for a buffer overflow in this function.
 */
static int
bhyve_add_cpuid_entry(const char *prefix, const nvlist_t *parent,
    const char *name, int type, void *arg)
{
	struct vm_vcpu_cpuid_config *vvcc = arg;
	struct vcpu_cpuid_entry *vce =
	    &((struct vcpu_cpuid_entry *)vvcc->vvcc_entries)[vvcc->vvcc_nent];
	long long regs[4] = { 0 };
	long long leaf = 0, index = 0;
	const char *errstr;
	const char *value;
	char *stringp, *val;
	u_long i;

	if (type != NV_TYPE_STRING)
		errx(4, "bhyve_add_cpuid_entry: "
		    "leaf/index \"%s\" not string type", name);

	/* If this is a global flag, apply it and return. */
	if (strcmp(name, "fallback-style") == 0) {
		assert(strcmp(prefix, "cpuid") == 0);

		value = nvlist_get_string(parent, name);
		if (strcmp(value, "intel") == 0) {
			vvcc->vvcc_flags |= VCC_FLAG_INTEL_FALLBACK;
		} else if (strcmp(value, "amd") == 0) {
			/* default behaviour */
		} else {
			errx(4, "bhyve_add_cpuid_entry: "
			    "invalid fallback-style \"%s\"", value);
		}

		return (0);
	}

	/*
	 * Get the CPUID function and optional index from the name.
	 * The index follows the function, separated by a comma.
	 */
	stringp = strdup(name);
	if ((val = strsep(&stringp, ",")) != NULL) {
		leaf = strtonumx(val, 0, UINT32_MAX, &errstr, 0);
		if (errstr != NULL) {
			errx(4, "bhyve_add_cpuid_entry: "
			    "invalid CPUID leaf '%s': %s", val, errstr);
		}
	}
	if ((val = strsep(&stringp, ",")) != NULL) {
		index = strtonumx(val, 0, UINT8_MAX, &errstr, 0);
		if (errstr != NULL) {
			errx(4, "bhyve_add_cpuid_entry: "
			    "invalid CPUID index '%s': %s", val, errstr);
		}
	}
	free(stringp);

	/*
	 * The node value is a list of the values for EAX, EBX, ECX, and EDX,
	 * in that order and separated by commata.
	 */
	value = nvlist_get_string(parent, name);
	stringp = strdup(value);
	i = 0;
	while ((val = strsep(&stringp, ",")) != NULL) {
		if (i > nitems(regs))
			errx(4, "bhyve_add_cpuid_entry: "
			    "too many tokens in CPUID values: %s", value);

		regs[i++] = strtonumx(val, 0, UINT32_MAX, &errstr, 0);
		if (errstr != NULL) {
			errx(4, "bhyve_add_cpuid_entry: "
			    "invalid CPUID registers value '%s': %s",
			    val, errstr);
		}
	}

	vce->vce_function = leaf;
	vce->vce_index = index;

	vce->vce_eax = regs[0];
	vce->vce_ebx = regs[1];
	vce->vce_ecx = regs[2];
	vce->vce_edx = regs[3];

	/*
	 * Advance the number of entries, which will also be used when this
	 * function is called again for the next cpuid option to select the
	 * next free slot in the cpuid entries array.
	 */
	vvcc->vvcc_nent++;

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
 * Populate a struct vm_vcpu_cpuid_config, parsing all cpuid options either for
 * a particular vcpu or for all vcpus if a NULL vcpu was passed.
 */
static void
bhyve_build_cpuid_config(struct vcpu *vcpu, struct vm_vcpu_cpuid_config *vvcc)
{
	char *node_name;
	nvlist_t *parent;
	size_t entries_sz;

	bzero(vvcc, sizeof (struct vm_vcpu_cpuid_config));

	if (vcpu != NULL)
		asprintf(&node_name, "vcpu.%d.cpuid", vcpu_id(vcpu));
	else
		asprintf(&node_name, "cpuid");

	if (node_name == NULL)
		err(4, "Failed to allocate node name for CPUID config");

	parent = find_config_node(node_name);

	/*
	 * If there are no [vcpu.X.]cpuid.* config options, our work here is
	 * done. Mark the cpuid config to use legacy cpuid handling.
	 */
	if (parent == NULL) {
		vvcc->vvcc_flags |= VCC_FLAG_LEGACY_HANDLING;
		return;
	}

	/*
	 * First, count the options under the parent node so we know how big of
	 * a cpuid entries array we'll need to hold them all.
	 */
	assert(walk_config_nodes(node_name, parent, vvcc,
	    bhyve_count_cpuid_entry) == 0);

	if (vvcc->vvcc_nent == 0) {
		/*
		 * This is really unexpected as we should have returned already
		 * above if there were no "[vcpu.X.]cpuid.*" config options.
		 */
		errx(4, "Failed to parse CPUID config options");
	}

	entries_sz = sizeof (struct vcpu_cpuid_entry) * vvcc->vvcc_nent;
	vvcc->vvcc_entries = malloc(entries_sz);
	if (vvcc->vvcc_entries == NULL)
		err(4, "Failed to allocate %d CPUID entries", vvcc->vvcc_nent);
	bzero(vvcc->vvcc_entries, entries_sz);

	/*
	 * Walk all options under the parent again, this time to parse and store
	 * them in the cpuid entries buffer. We clear vvcc_nent so we can use it
	 * to find the next free entry in bhyve_add_cpuid_entry().
	 */
	vvcc->vvcc_nent = 0;
	assert(walk_config_nodes(node_name, parent, vvcc,
	    bhyve_add_cpuid_entry) == 0);

	/*
	 * The kernel wants the cpuid entries in sorted in ascending order.
	 */
	qsort(vvcc->vvcc_entries, vvcc->vvcc_nent,
	    sizeof (struct vcpu_cpuid_entry), bhyve_compare_cpuid_entries);
}

/*
 * Merge the cpuid entries of two structs vm_vcpu_cpuid_config into a new
 * entries array. If an entry for a cpuid function/index found in src already
 * exists in dst, the one in dst is kept and the one in src is discarded.
 *
 * The new merged entries array will replace that of dst.
 */
static void
bhyve_merge_cpuid_config(struct vm_vcpu_cpuid_config *src,
    struct vm_vcpu_cpuid_config *dst)
{
	struct vcpu_cpuid_entry dummy_vce = {
		.vce_function = UINT32_MAX,
		.vce_index = UINT32_MAX
	};
	struct vcpu_cpuid_entry *src_vce, *src_vce_end;
	struct vcpu_cpuid_entry *dst_vce, *dst_vce_end;
	struct vcpu_cpuid_entry *new_entries, *new_vce;
	size_t entries_sz;
	uint32_t new_nent, i;

	/* If there are no src cpuid entries, there's nothing to do. */
	if (src->vvcc_nent == 0)
		return;

	/*
	 * Allocate a new cpuid entries array big enough to hold all entries of
	 * the src and dst arrays.
	 */
	new_nent = dst->vvcc_nent + src->vvcc_nent;
	entries_sz = new_nent * sizeof (struct vcpu_cpuid_entry);
	new_entries = malloc(entries_sz);
	memset(new_entries, 0, entries_sz);

	/*
	 * Copy the cpuid entries from src and dst into new. The cpuid entries
	 * in both src and dst are already ordered by function and index, and
	 * we keep it that way. If both function and index are the same, the
	 * dst entry overrides the src one. This of course reduces the total
	 * number of entries in the new merged array.
	 *
	 * The dummy_vce is used when the end of one array is reached, it'll
	 * always compare higher to any "real" cpuid entries so that we'll
	 * continue copying the remaining "real" entries until we're done.
	 */
	src_vce = src->vvcc_entries;
	src_vce_end = &src_vce[src->vvcc_nent];
	dst_vce = dst->vvcc_entries;
	dst_vce_end = &dst_vce[dst->vvcc_nent];

	for (i = 0; i != new_nent; i++) {
		if (src_vce != &dummy_vce && src_vce >= src_vce_end)
			src_vce = &dummy_vce;

		if (dst_vce != &dummy_vce && dst_vce >= dst_vce_end)
			dst_vce = &dummy_vce;

		new_vce = &new_entries[i];


		if (src_vce->vce_function < dst_vce->vce_function) {
			*new_vce++ = *src_vce++;
		} else if (src_vce->vce_function > dst_vce->vce_function) {
			*new_vce++ = *dst_vce++;
		} else if (src_vce->vce_index < dst_vce->vce_index) {
			*new_vce++ = *src_vce++;
		} else if (src_vce->vce_index > dst_vce->vce_index) {
			*new_vce++ = *dst_vce++;
		} else {
			src_vce++;
			*new_vce++ = *dst_vce++;
			new_nent--;
		}
	}

	/* If we skipped some entries, reallocate the entries array. */
	if (new_nent < dst->vvcc_nent + src->vvcc_nent) {
		entries_sz = new_nent * sizeof (struct vcpu_cpuid_entry);
		new_entries = realloc(new_entries, entries_sz);
		if (new_entries == NULL)
			err(4, "Failed to allocate %d CPUID entries", new_nent);
	}

	free(dst->vvcc_entries);
	dst->vvcc_nent = new_nent;
	dst->vvcc_entries = new_entries;
	dst->vvcc_flags |= src->vvcc_flags;

	if (new_nent == 0)
		dst->vvcc_flags |= VCC_FLAG_LEGACY_HANDLING;
	else
		dst->vvcc_flags &= ~VCC_FLAG_LEGACY_HANDLING;
}

/*
 * Traverse a vcpu config entries array and set the MATCH INDEX flag where
 * needed. Exit with an error if we encounter any duplicates of function and
 * index, which aren't allowed.
 */
static void
bhyve_fixup_cpuid_config(struct vm_vcpu_cpuid_config *vvcc)
{
	struct vcpu_cpuid_entry *vce, *last_vce;

	last_vce = vvcc->vvcc_entries;
	if (last_vce == NULL)
		return;

	for (uint32_t i = 1; i < vvcc->vvcc_nent; i++) {
		vce = &((struct vcpu_cpuid_entry *)vvcc->vvcc_entries)[i];

		if (vce->vce_function == last_vce->vce_function) {
			if (vce->vce_index == last_vce->vce_index)
				errx(4, "duplicate CPUID entry for EAX=%x, "
				    "ECX=%x", vce->vce_function,
				    vce->vce_index);
			last_vce->vce_flags |= VCE_FLAG_MATCH_INDEX;
			vce->vce_flags |= VCE_FLAG_MATCH_INDEX;
		}

		last_vce = vce;
	}
}

/*
 * Build the per-VCPU cpuid configuration from any vcpu.X.cpuid.* config
 * options, if any. When called for the first time, build the global cpuid
 * configuration from any cpuid.* config options, if any.
 */
void
bhyve_init_vcpu_cpuid_config(struct vcpu *vcpu)
{
	/* Global VM cpuid config shared by all VCPUs. */
	static struct vm_vcpu_cpuid_config global_vvcc;

	/*
	 * Per-VCPU cpuid config. We don't currently keep this around as it's
	 * only used by the kernel so far.
	 */
	struct vm_vcpu_cpuid_config vcpu_vvcc;

	/*
	 * Once the global cpuid config has been built, it'll either have zero
	 * entries and the legacy flag is set, or it'll have non-zero entries
	 * and the legacy flag is clear.
	 *
	 * If it hasn't been done yet, do it now.
	 */
	if (global_vvcc.vvcc_nent == 0 &&
	    (global_vvcc.vvcc_flags & VCC_FLAG_LEGACY_HANDLING) == 0) {
		bhyve_build_cpuid_config(NULL, &global_vvcc);
	}

	/*
	 * Now build the per-VCPU cpuid configuration for this VCPU, which will
	 * merge in the global cpuid configuration.
	 */
	bhyve_build_cpuid_config(vcpu, &vcpu_vvcc);
	bhyve_merge_cpuid_config(&global_vvcc, &vcpu_vvcc);
	bhyve_fixup_cpuid_config(&vcpu_vvcc);

	if (vm_set_cpuid(vcpu, &vcpu_vvcc) != 0)
		err(4, "vm_set_cpuid()");

	if (vcpu_vvcc.vvcc_entries != NULL)
		free(vcpu_vvcc.vvcc_entries);
}
