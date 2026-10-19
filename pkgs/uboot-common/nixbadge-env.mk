# Builds include/generated/nixbadge-env.h from nixbadge.env. Read after the
# vendor Makefile (make -f Makefile -f nixbadge-env.mk), which supplies CPP,
# cpp_flags, srctree, ARCH and the include/config/auto.conf rule that also
# writes include/config.h. The two rules mirror U-Boot v2026.04's
# include/generated/env.in and environment.h rules (Makefile, "Environment
# processing"); NIXBADGE_CORE is the one addition. The vendor env_default.h
# reads CONFIG_EXTRA_ENV_SETTINGS, so the header maps it to the awk's
# CONFIG_EXTRA_ENV_TEXT.
#
# Variables: NIXBADGE_ENV (nixbadge.env), NIXBADGE_ENV_AWK (env2string.awk),
# NIXBADGE_CORE (arm or riscv).

include/generated/nixbadge-env.in: $(NIXBADGE_ENV) include/config/auto.conf
	$(CPP) -P $(cpp_flags) -x assembler-with-cpp -undef \
		-D__ASSEMBLY__ \
		-D__UBOOT_CONFIG__ \
		-DDEFAULT_DEVICE_TREE=$(subst ",,$(CONFIG_DEFAULT_DEVICE_TREE)) \
		-DNIXBADGE_CORE=$(NIXBADGE_CORE) \
		-I . -I include -I $(srctree)/include \
		-include linux/kconfig.h -include include/config.h \
		-I$(srctree)/arch/$(ARCH)/include \
		$< -o $@

include/generated/nixbadge-env.h: include/generated/nixbadge-env.in $(NIXBADGE_ENV_AWK)
	awk -f $(NIXBADGE_ENV_AWK) $< > $@
	echo '#define CONFIG_EXTRA_ENV_SETTINGS CONFIG_EXTRA_ENV_TEXT' >> $@
