/*
 * STAT LED, blinked during the autoboot countdown and handed back after.
 *
 * The countdown is time the board already spends, so blinking there adds no
 * boot time (unlike an earlier version that busy-waited in board_early_init_f /
 * board_late_init). It is also the honest signal: the LED is lit exactly while
 * holding BOOT or pressing ENTER does something, then the pad returns to JTAG.
 *
 * Not a blink routine but three pieces the countdown loop drives, so nothing
 * here delays anything:
 *
 *   statled_begin()    save the pad mux, borrow the pad, drive the line
 *   statled_toggle()   flip the line, called from the poll loop
 *   statled_end()      put direction and mux back
 *
 * The pad: STAT is XGPIOA_29 on the IIC0_SDA pad:
 *
 *   IIC0_SDA__CV_SDA0__CR_4WTDO  0    <- i2c0 SDA and C906 4-wire JTAG TDO
 *   IIC0_SDA__XGPIOA_29          3    <- what we want, for the countdown only
 *
 * so lighting the LED takes the pad off JTAG TDO; begin saves the mux and end
 * restores it, so the borrow lasts only the countdown. The saved value can live
 * in a file-scope variable because begin and end both run in the main loop,
 * after relocation, so nothing must survive the image copy.
 *
 *   XGPIOA        0x03020000   (+0x00 DR data, +0x04 DDR direction 1=out)
 *   STAT bit      29
 *   IIC0_SDA mux  0x03001074   (PINMUX_BASE 0x03001000 + FUNCSEL_IIC0_SDA 0x74)
 *                              low 3 bits: 0 = i2c0/JTAG TDO, 3 = XGPIOA_29
 *
 * Polarity is not assumed: the line is toggled, so it blinks whether the LED is
 * wired active-high or active-low.
 */

#define STATLED_PINMUX_BASE	0x03001000UL
#define STATLED_IIC0_SDA_FUNCSEL (STATLED_PINMUX_BASE + 0x74)
#define STATLED_FUNCSEL_MASK	0x7
#define STATLED_FUNC_XGPIOA_29	0x3

#define STATLED_XGPIOA_BASE	0x03020000UL
#define STATLED_XGPIOA_DR	(STATLED_XGPIOA_BASE + 0x00)
#define STATLED_XGPIOA_DDR	(STATLED_XGPIOA_BASE + 0x04)
#define STATLED_BIT		29

static uint32_t statled_saved_mux;
static uint32_t statled_saved_ddr;
static int statled_active;

void statled_begin(void)
{
	uint32_t ddr;

	if (statled_active)
		return;

	statled_saved_mux = mmio_read_32(STATLED_IIC0_SDA_FUNCSEL);
	mmio_write_32(STATLED_IIC0_SDA_FUNCSEL,
		      (statled_saved_mux & ~STATLED_FUNCSEL_MASK) |
		      STATLED_FUNC_XGPIOA_29);

	/* Drive just our bit; every other XGPIOA line is left as found. */
	ddr = mmio_read_32(STATLED_XGPIOA_DDR);
	statled_saved_ddr = ddr;
	mmio_write_32(STATLED_XGPIOA_DDR, ddr | (1u << STATLED_BIT));

	statled_active = 1;
}

void statled_toggle(void)
{
	uint32_t dr;

	if (!statled_active)
		return;

	dr = mmio_read_32(STATLED_XGPIOA_DR);
	mmio_write_32(STATLED_XGPIOA_DR, dr ^ (1u << STATLED_BIT));
}

void statled_end(void)
{
	if (!statled_active)
		return;

	/* Direction first, so the line is not left driven while it becomes a
	 * JTAG pin again. */
	mmio_write_32(STATLED_XGPIOA_DDR, statled_saved_ddr);
	mmio_write_32(STATLED_IIC0_SDA_FUNCSEL, statled_saved_mux);

	statled_active = 0;
}
