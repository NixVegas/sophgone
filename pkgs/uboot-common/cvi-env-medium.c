/* nix-badge: which MMC device and hardware partition hold the U-Boot
 * environment. SD boot: device 0, user area, GPT partition UBOOT (control DT
 * /config u-boot,mmc-env-partition). eMMC boot: device 1, hardware partition 2
 * (boot area 2), copies at raw offsets 0x0 and 0x20000 (no GPT lookup).
 */
#include <common.h>
#include <mmc.h>
#include <env.h>
#include <env_internal.h>
#include <part.h>

/* The FSBL's bl2_main() -> setup_dl_flag() leaves the ROM's boot source in AXI
 * SRAM at BOOT_SOURCE_FLAG_ADDR (0x0E000004): 0x4D474E32 ("MGN2") after an SD
 * boot, 0x0000CE03 after an eMMC boot. Anything other than 0xCE03 is treated
 * as SD. GP registers and PARTITION_CONFIG are not usable: the FSBL overwrites
 * the former, and the ROM leaves 0x08 in the latter after both kinds of boot.
 */
#define NIXBADGE_BOOT_SRC_EMMC		0x0000CE03
#define NIXBADGE_MMC_SD			0	/* control DTS alias mmc0 = &sd   */
#define NIXBADGE_MMC_EMMC		1	/* control DTS alias mmc1 = &emmc */
#define NIXBADGE_EMMC_ENV_HWPART	2	/* EXT_CSD PARTITION_ACCESS 2 = boot area 2 */

static int nixbadge_booted_from_emmc(void)
{
	return readl((void *)(uintptr_t)BOOT_SOURCE_FLAG_ADDR) == NIXBADGE_BOOT_SRC_EMMC;
}

int mmc_get_env_dev(void)
{
	return nixbadge_booted_from_emmc() ? NIXBADGE_MMC_EMMC : NIXBADGE_MMC_SD;
}

/* CONFIG_SYS_MMC_ENV_PART=0 comes from env/Kconfig, so env/mmc.c's
 * mmc_set_env_part()/fini_mmc_for_env() are compiled and call this. */
uint mmc_get_env_part(struct mmc *mmc)
{
	return nixbadge_booted_from_emmc() ? NIXBADGE_EMMC_ENV_HWPART : 0;
}

/*
 * mmc_get_env_addr() override. SD: both copies at the start of the "UBOOT"
 * partition (copy 0 at 0x0, copy 1 at 0x20000), where the image builder dd's
 * a `mkenvimage -s 0x20000 -r` blob. The stock mmc_offset_try_partition()
 * counts back from the end of the partition instead and never consults
 * CONFIG_ENV_OFFSET(_REDUND), so it would read the zeroed tail, fail both
 * CRCs and fall back to the default env every boot. This strong definition
 * replaces env/mmc.c's __weak one; the offsets in cvipart.h stay defined
 * because ENV_IS_IN_MMC and the redundant-env path in env/mmc.c need them.
 *
 * mmc_get_blk_desc() does not probe the device, and nothing between initr_mmc
 * and initr_env calls mmc_init(), so its descriptor reads lba 0 and every
 * partition lookup fails. blk_get_devnum_by_type() probes (blk_get_device()
 * -> device_probe() -> mmc_init()), as blk_get_device_by_str() does for the
 * stock code.
 *
 * eMMC: init_mmc_for_env() has already switched to hardware partition 2, so
 * the copies sit at raw offsets 0 and CONFIG_ENV_SIZE inside it.
 */
int mmc_get_env_addr(struct mmc *mmc, int copy, u32 *env_addr)
{
	struct disk_partition info;
	struct blk_desc *desc;

	if (nixbadge_booted_from_emmc()) {
		/* init_mmc_for_env() already switched the eMMC to boot area 2 (and
		 * probed it, so capacity_boot is valid); offsets are relative to that
		 * hardware partition: copy 0 at 0, copy 1 at CONFIG_ENV_SIZE, the same
		 * layout as the SD's UBOOT partition and as fw_env.config. */
		if ((u64)(copy + 1) * CONFIG_ENV_SIZE > mmc->capacity_boot) {
			printf("nixbadge: eMMC boot area 2 too small for env copy %d\n", copy);
			return -1;
		}
		*env_addr = (u32)copy * CONFIG_ENV_SIZE;
		return 0;
	}

	/* SD: start of the GPT partition "UBOOT". */
	desc = blk_get_devnum_by_type(IF_TYPE_MMC, mmc_get_env_dev());
	if (!desc || part_get_info_by_name(desc, "UBOOT", &info) < 0) {
		printf("nixbadge: no \"UBOOT\" partition on mmc %d; using compiled-in env\n",
		       mmc_get_env_dev());
		return -1;
	}
	*env_addr = (u32)(info.start * info.blksz) + (u32)copy * CONFIG_ENV_SIZE;
	return 0;
}

/*
 * env_get_location() override: load the compiled-in default env first
 * (ENVL_NOWHERE, priority 0), then overlay the stored env (ENVL_MMC, priority
 * 1); save and erase always target MMC. Same pattern as
 * board/aristainetos/aristainetos.c.
 *
 * NOWHERE must load first: an H_EXTERNAL import starts from an empty table
 * unless H_NOCLEAR is set (lib/hashtable.c), and CONFIG_ENV_WRITEABLE_LIST
 * rejects every variable without the 'w' flag (env/flags.c), so an MMC-only
 * load would leave just the six write-listed variables and no bootcmd.
 * CONFIG_ENV_APPEND makes env_load() continue past the first driver and adds
 * H_NOCLEAR to every import, so MMC's variables merge onto the defaults.
 *
 * Save/erase switch on `op`, not `prio`: env_save() uses gd->env_load_prio,
 * which is 0 (NOWHERE, no ->save) on a blank or corrupt card, so a
 * prio-based answer would silently drop the first saveenv on exactly the
 * card that needs it.
 */
enum env_location env_get_location(enum env_operation op, int prio)
{
	if (op == ENVOP_SAVE || op == ENVOP_ERASE)
		return ENVL_MMC;

	switch (prio) {
	case 0:
		return ENVL_NOWHERE;
	case 1:
		return ENVL_MMC;
	default:
		return ENVL_UNKNOWN;
	}
}

/* Expose the medium to the shell. Runs after initr_env (board_r.c:717) and
 * before bootcmd (board_r.c:768). A stored env cannot override these values:
 * bootmedium/mmcdev/rauc_ext are not on CONFIG_ENV_WRITEABLE_LIST, and these
 * env_set() calls run after the load has finished. The flag is read once so
 * the log line shows the value the decision was made on.
 */
int board_late_init(void)
{
	u32 flag = readl((void *)(uintptr_t)BOOT_SOURCE_FLAG_ADDR);
	int emmc = flag == NIXBADGE_BOOT_SRC_EMMC;

	env_set("bootmedium", emmc ? "0" : "1");	/* 1 = SD, 0 = eMMC */
	env_set("mmcdev", emmc ? "1" : "0");		/* U-Boot mmc index */
	/* rauc_ext sits next to rauc.slot=${rauc_slot} on every gpt-squashfs
	 * APPEND line (badgeos modules/duo-s/storage.nix). On an SD boot it is
	 * "rauc.external", so RAUC treats every slot in system.conf (all on the
	 * eMMC) as inactive instead of matching rauc.slot=A to eMMC slot A. On an
	 * eMMC boot it is unset and expands to nothing. */
	env_set("rauc_ext", emmc ? NULL : "rauc.external");
	printf("nixbadge: boot source 0x%08x -> %s (mmc %d)\n",
	       flag, emmc ? "eMMC" : "SD",
	       emmc ? NIXBADGE_MMC_EMMC : NIXBADGE_MMC_SD);
	return 0;
}
