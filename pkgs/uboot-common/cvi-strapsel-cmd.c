/*
 * `strapsel` -- read or set the core-select latch from the u-boot prompt.
 *
 * The Duo S badge picks its boot core with a 74AUP1G175 D flip-flop (U2) whose
 * output is the SoC's boot strap. Linux drives it via gpio-line-names on XGPIOB
 * and `nix-badge core <arm|riscv>`; this reaches the same latch before Linux
 * exists, which otherwise needs a working Linux on the core you are leaving, or
 * pulling the board to move the physical switch.
 *
 * XGPIOB (gpiochip1) at 0x03021000, DesignWare APB GPIO register layout:
 *   DR        +0x00  output data
 *   DDR       +0x04  direction, 1 = output
 *   EXT_PORTA +0x50  live input read
 * Lines (see pkgs/firmware/dts/sg2000-milkv-duo-s*.dts gpio-line-names):
 *   bit 11  core-sel-latch-clk   U2 CP
 *   bit 12  core-sel-latch-d     1 = ARM, 0 = RISC-V on the next boot
 *   bit 23  core-sel-strap       readback: 1 = RISC-V, 0 = ARM
 *
 * The readback reflects the latched selection only when the board switch is on
 * AUTO. If the switch is forced to a core, the strap will not follow the latch,
 * so we read back and report it rather than silently lying.
 */
#include <linux/delay.h>

#define STRAPSEL_GPIO_BASE	0x03021000UL
#define STRAPSEL_DR		(STRAPSEL_GPIO_BASE + 0x00)
#define STRAPSEL_DDR		(STRAPSEL_GPIO_BASE + 0x04)
#define STRAPSEL_EXT		(STRAPSEL_GPIO_BASE + 0x50)
#define STRAPSEL_CP_BIT		11
#define STRAPSEL_D_BIT		12
#define STRAPSEL_RB_BIT		23

/* 1 = RISC-V, 0 = ARM */
static int strapsel_readback(void)
{
	return (mmio_read_32(STRAPSEL_EXT) >> STRAPSEL_RB_BIT) & 1;
}

static void strapsel_latch(int want_arm)
{
	uint32_t ddr, dr;

	/* CP and D must be outputs; leave every other line alone. */
	ddr = mmio_read_32(STRAPSEL_DDR);
	ddr |= (1u << STRAPSEL_CP_BIT) | (1u << STRAPSEL_D_BIT);
	mmio_write_32(STRAPSEL_DDR, ddr);

	/*
	 * Present D and hold CP low first, so the rising edge below is the only
	 * edge the flip-flop sees; one combined write would race clock and data.
	 */
	dr = mmio_read_32(STRAPSEL_DR);
	if (want_arm)
		dr |= (1u << STRAPSEL_D_BIT);
	else
		dr &= ~(1u << STRAPSEL_D_BIT);
	dr &= ~(1u << STRAPSEL_CP_BIT);
	mmio_write_32(STRAPSEL_DR, dr);
	udelay(1000);

	mmio_write_32(STRAPSEL_DR, dr | (1u << STRAPSEL_CP_BIT));  /* latch */
	udelay(1000);

	mmio_write_32(STRAPSEL_DR, dr);                            /* CP idle low */
	udelay(1000);
}

static int do_strapsel(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	int want_arm, rb;

	if (argc == 1) {
		printf("core-select strap reads %d (%s)\n",
		       strapsel_readback(), strapsel_readback() ? "riscv" : "arm");
		return 0;
	}
	if (argc != 2)
		return CMD_RET_USAGE;

	if (!strcmp(argv[1], "arm"))
		want_arm = 1;
	else if (!strcmp(argv[1], "riscv"))
		want_arm = 0;
	else
		return CMD_RET_USAGE;

	strapsel_latch(want_arm);

	rb = strapsel_readback();
	printf("core-select latched to %s; strap now reads %d (%s)\n",
	       want_arm ? "arm" : "riscv", rb, rb ? "riscv" : "arm");
	if (rb != (want_arm ? 0 : 1)) {
		printf("WARNING: the strap did not follow the latch.\n");
		printf("         The board switch is probably NOT on AUTO, which\n");
		printf("         overrides the latch. Move it to AUTO and retry.\n");
		return 1;
	}
	printf("Run `reset` to boot the selected core.\n");
	return 0;
}

U_BOOT_CMD(strapsel, 2, 0, do_strapsel,
	   "read or set the core-select latch (which core boots next)",
	   "            - print the current core-select strap\n"
	   "strapsel arm    - latch ARM (A53) for the next boot\n"
	   "strapsel riscv  - latch RISC-V (C906) for the next boot\n"
	   "Needs the board switch on AUTO; follow with `reset`.");
