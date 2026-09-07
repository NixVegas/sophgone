#ifndef __CVIPART_H__
#define __CVIPART_H__
/*
 * cvipart.h for Milk-V Duo S SD boot. The Sophgo SDK generates this with
 * mkcvipart.py from a partition XML; this is the minimal subset cv181x-asic.h
 * needs. That header #undefs CONFIG_ENV_OFFSET/CONFIG_ENV_SIZE before including
 * this, so we redefine them here.
 */

#define CONFIG_ENV_OFFSET     0x880000
#define CONFIG_ENV_SIZE       0x20000
#define CONFIG_ENV_IS_IN_MMC  1
#define ROOTFS_DEV            "/dev/mmcblk0p3"
#define PART_LAYOUT           ""
#define PARTS_OFFSET          ""

#endif /* __CVIPART_H__ */
