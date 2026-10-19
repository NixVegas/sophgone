/*
 * `nixbadge_halt` -- the secure build's end of the boot walk: no slot booted
 * a verified FIT, so stop. Without it bootcmd would return and U-Boot would
 * start its command line. The secure env's nixbadge_legacy calls it last.
 *
 * It idles rather than calling hang(), which uboot-hang-reset.patch turns into
 * a reset that would rerun the same walk against the same card. mdelay() goes
 * through udelay(), which services the watchdog. A power cycle (or another
 * card) is the way out.
 *
 * Built only with CONFIG_FIT_SIGNATURE; the plain build keeps its sysboot
 * legacy tail.
 */
#ifdef CONFIG_FIT_SIGNATURE
#include <command.h>
#include <linux/delay.h>

static int do_nixbadge_halt(struct cmd_tbl *cmdtp, int flag, int argc,
			    char *const argv[])
{
	puts("nixbadge: no slot booted, halting\n");
	for (;;)
		mdelay(100);
	return CMD_RET_FAILURE;	/* not reached */
}

U_BOOT_CMD(nixbadge_halt, 1, 0, do_nixbadge_halt,
	   "idle forever (secure build: nothing verified booted)",
	   "  - print a message and idle until power-off; never returns to the\n"
	   "    command line and never resets (a reset would rerun the same walk).");
#endif /* CONFIG_FIT_SIGNATURE */
