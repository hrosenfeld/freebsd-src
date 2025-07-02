PACKAGE=	bhyve
FILESDIR=	${SHAREDIR}/bhyve/cpu
FILES_COMMON=	clear_cpuid.cfg 486.cfg \
		x86-64-v1.cfg x86-64-v2.cfg x86-64-v3.cfg x86-64-v4.cfg

FILES_AMD=	k5.cfg k6.cfg k6-2.cfg k6-3.cfg k6-3+.cfg \
		athlon.cfg athlon-xp.cfg athlon-64.cfg \
		opteron-g1.cfg opteron-g2.cfg opteron-g3.cfg \
		opteron-g4.cfg opteron-g5.cfg

FILES_INTEL=	pentium.cfg pentium-mmx.cfg pentiumpro.cfg pentium2.cfg \
		pentium3.cfg pentium4.cfg coreduo.cfg core2duo.cfg \
		nehalem.cfg westmere.cfg sandybridge.cfg ivybridge.cfg \
		haswell.cfg broadwell.cfg skylake.cfg cascadelake.cfg \
		icelake.cfg

FILES=		$(FILES_COMMON) $(FILES_AMD) $(FILES_INTEL)

.include <bsd.prog.mk>
