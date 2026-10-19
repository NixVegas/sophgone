#ifndef __CVIPART_H__
#define __CVIPART_H__
/*
 * cvipart.h for Milk-V Duo S SD boot. The Sophgo SDK generates this with
 * mkcvipart.py from a partition XML; this is the minimal subset cv181x-asic.h
 * needs. That header #undefs CONFIG_ENV_OFFSET, CONFIG_ENV_OFFSET_REDUND,
 * CONFIG_ENV_SIZE and CONFIG_ENV_IS_IN_MMC before including this, so these
 * are the real values, not the defconfig lines of the same name. The offsets
 * are partition-relative; cvi-env-medium.c's mmc_get_env_addr() places the
 * copies itself, but CONFIG_ENV_OFFSET_REDUND must be defined for env/mmc.c
 * to compile in the redundant-env path at all.
 */

#define CONFIG_ENV_OFFSET        0x0
#define CONFIG_ENV_OFFSET_REDUND 0x20000
#define CONFIG_ENV_SIZE          0x20000
#define CONFIG_ENV_IS_IN_MMC     1
#define ROOTFS_DEV            "/dev/mmcblk0p3"
#define PART_LAYOUT           ""
#define PARTS_OFFSET          ""

#endif /* __CVIPART_H__ */
