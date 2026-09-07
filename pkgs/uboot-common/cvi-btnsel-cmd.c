/*
 * `btnsel` -- pick the boot profile from the BOOT button at power-up.
 *
 * Hold BOOT (S1, marked UPDATE) while powering on for the desktop/video
 * profile; release it for the default badge profile. BOOT is used rather than
 * USER because USER is claimed by the running system (badge-video clips, OLED
 * daemon), while BOOT is otherwise unused after the mask ROM reads its strap.
 *
 * S1 BOOT: XGPIOB (snps,dw-apb-gpio @ 0x03021000) line 4, active low (rests
 * high, pressed pulls low). Named "btn-boot-n" in the DTS gpio-line-names. The
 * pad is USB_ID (mux 0 = USB_ID, mux 3 = XGPIOB_4), so it must be muxed to 3
 * before the line reads; it is restored after (nothing in our Linux DTS uses
 * USB_ID or btn-boot-n, so this only avoids perturbing later USB-OTG detect).
 *
 *   XGPIOB     0x03021000   (+0x04 DDR, 1=out;  +0x50 EXT_PORTA, live input)
 *   BOOT bit   4
 *   USB_ID mux 0x030010FC   (PINMUX_BASE 0x03001000 + FUNCSEL_USB_ID 0xFC),
 *                           low 3 bits: 0 = USB_ID, 3 = XGPIOB_4
 *
 * bootcmd runs after the autoboot delay (main_loop -> autoboot_command ->
 * abortboot, then the command), so the button is read at the end of the
 * countdown; that is the window the STAT LED blinks through.
 *
 * Fails safe: `bootconf` defaults to the badge conf in
 * CONFIG_EXTRA_ENV_SETTINGS and this command only overrides it, so a misread,
 * an unmuxed pad, or a missing command all land on the default profile. bootcmd
 * also keeps a trailing `sysboot ... extlinux.conf` as a second net.
 *
 * BTNSEL_DESKTOP_CONF is #defined per core by the U-Boot derivation's
 * postPatch (/arm/... vs /riscv/...) before this file is appended.
 */
#include <env.h>
#include <linux/delay.h>

#ifndef BTNSEL_DESKTOP_CONF
#define BTNSEL_DESKTOP_CONF "/arm/extlinux/extlinux-desktop.conf"
#endif

#define XGPIOB_BASE		0x03021000UL
#define XGPIOB_DDR		(XGPIOB_BASE + 0x04)
#define XGPIOB_EXT		(XGPIOB_BASE + 0x50)
#define BOOT_BTN_BIT		4

#define BTNSEL_PINMUX_BASE	0x03001000UL
#define BTNSEL_USB_ID_FUNCSEL	(BTNSEL_PINMUX_BASE + 0xFC)
#define BTNSEL_FUNCSEL_MASK	0x7
#define BTNSEL_FUNC_XGPIOB_4	0x3

/* Sampling window. Long enough to ride out contact bounce and to be an
 * unambiguous "hold" rather than a stray level, short enough that it is not
 * felt in the boot time. */
#define BTNSEL_SAMPLES		16
#define BTNSEL_SAMPLE_MS	5

/* 1 = held for the whole window; 0 = released at any point during it.
 *
 * Every sample must agree before we call it held, so a transient low on the
 * just-switched-to-input pad cannot flip the profile; a single high means "not
 * held" (the safe answer). The pad is muxed to GPIO for the duration and
 * restored before returning, on every path including the early-out. */
static int boot_btn_held(void)
{
	uint32_t mux, v;
	int i, held = 1;

	/* USB_ID pad -> XGPIOB_4, remembering what it was. */
	mux = mmio_read_32(BTNSEL_USB_ID_FUNCSEL);
	mmio_write_32(BTNSEL_USB_ID_FUNCSEL,
		      (mux & ~BTNSEL_FUNCSEL_MASK) | BTNSEL_FUNC_XGPIOB_4);

	/* Direction = input, leaving every other XGPIOB line alone. */
	v = mmio_read_32(XGPIOB_DDR);
	mmio_write_32(XGPIOB_DDR, v & ~(1u << BOOT_BTN_BIT));

	for (i = 0; i < BTNSEL_SAMPLES; i++) {
		if ((mmio_read_32(XGPIOB_EXT) >> BOOT_BTN_BIT) & 1) {
			held = 0;	/* high = released */
			break;
		}
		mdelay(BTNSEL_SAMPLE_MS);
	}

	mmio_write_32(BTNSEL_USB_ID_FUNCSEL, mux);
	return held;
}

static int do_btnsel(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	if (boot_btn_held()) {
		env_set("bootconf", BTNSEL_DESKTOP_CONF);
		printf("btnsel: BOOT held -> desktop (%s)\n",
		       BTNSEL_DESKTOP_CONF);
	} else {
		printf("btnsel: BOOT not held -> default profile (hold BOOT for desktop)\n");
	}
	return 0;
}

U_BOOT_CMD(btnsel, 1, 0, do_btnsel,
	   "set $bootconf to the desktop extlinux.conf while the BOOT button is held",
	   "  - read BOOT (XGPIOB 0x03021000 line 4, active low) for ~80ms:\n"
	   "    held throughout -> desktop conf; otherwise leave $bootconf alone.\n"
	   "    The USB_ID pad is muxed to XGPIOB_4 for the read and restored\n"
	   "    afterwards. Runs from bootcmd, i.e. AFTER the autoboot countdown,\n"
	   "    so hold the button while STAT is blinking. It never fails.");
