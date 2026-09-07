/*
 * `sdready` -- make sure mmc 0 is up before anything boots off it, resetting
 * the board if it will not come up.
 *
 * The SG2000 sometimes runs U-Boot before the SD has finished initialising:
 *
 *   ** No partition table - mmc 0 **
 *   mmc fail to send stop cmd
 *
 * followed by a failed extlinux read. It always works after a reset: the card
 * is fine, it just was not ready. The window is around the environment load
 * ("Loading Environment from MMC..." / "mmc1 : finished tuning"), i.e. the
 * other controller is still tuning while the SD comes up. bootcmd runs after
 * that, so a rescan here sticks.
 *
 * So: poke the device, and if it does not answer, rescan (re-runs the raced
 * card identification) and retry a few times. If it still will not come up,
 * reset -- on a badge there is no keyboard, so a U-Boot prompt is
 * indistinguishable from a hang. A genuinely dead card reset-loops, but
 * recovers by itself once a working card is present.
 *
 * Uses run_command() rather than the mmc API to keep block-layer headers out
 * of this file; `mmc dev 0` already returns non-zero for the condition we want.
 */
#include <command.h>
#include <linux/delay.h>

#define SDREADY_TRIES	5
#define SDREADY_DELAY_MS 200

static int do_sdready(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	int i;

	for (i = 1; i <= SDREADY_TRIES; i++) {
		/*
		 * The second check is the important one. "No partition table -
		 * mmc 0" means the device did initialise (`mmc dev 0` succeeds)
		 * but the partition-table read lost the race, so checking only the
		 * device would miss it. `mmc part` re-reads the table, the very
		 * operation that fails.
		 */
		if (run_command("mmc dev 0", 0) == 0 &&
		    run_command("mmc part", 0) == 0) {
			if (i > 1)
				printf("sdready: mmc 0 readable on try %d\n", i);
			return 0;
		}
		printf("sdready: mmc 0 not readable (try %d/%d), rescanning\n",
		       i, SDREADY_TRIES);
		mdelay(SDREADY_DELAY_MS);
		run_command("mmc rescan", 0);
	}

	printf("sdready: mmc 0 still down after %d tries -- resetting\n",
	       SDREADY_TRIES);
	/* Let the message reach the console before the board goes away. */
	mdelay(50);
	run_command("reset", 0);
	return 1;		/* not reached */
}

U_BOOT_CMD(sdready, 1, 0, do_sdready,
	   "wait for mmc 0 to initialise, resetting the board if it will not",
	   "  - the SD is occasionally not ready when U-Boot starts (\"No partition\n"
	   "    table - mmc 0\", \"mmc fail to send stop cmd\"); rescan a few times\n"
	   "    and reset if that does not fix it. Run before sysboot.");
