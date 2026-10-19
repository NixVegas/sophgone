/* nix-badge uboot-sandbox compat shim (not part of the vendor tree): common/
 * (autoboot.c, image.c, spl.c, spl_fit.c) calls board_save_time_record() and
 * TIME_RECORDS_FIELD_* unconditionally, but they are declared only in
 * arch/{arm,riscv}'s u-boot-{arm,riscv}.h, which sandbox never includes.
 */
#ifndef NIXBADGE_SANDBOX_COMPAT_H
#define NIXBADGE_SANDBOX_COMPAT_H
enum {
	TIME_RECORDS_FIELD_BOOTCMD_START,
	TIME_RECORDS_FIELD_KERNEL_START,
	TIME_RECORDS_FIELD_UBOOT_START,
	TIME_RECORDS_FIELD_DECOMPRESS_KERNEL_START,
};
static inline void board_save_time_record(unsigned long saveaddr)
{
	(void)saveaddr;
}
#endif
