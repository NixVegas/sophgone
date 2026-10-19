/*
 * `btnsel` -- pick the boot profile from the BOOT and USER buttons at power-up.
 *
 *   hold BOOT (S1, marked UPDATE) -> $target=desktop, extlinux-desktop[-<slot>].conf
 *   hold USER (S3)                -> $target=video,   extlinux-video[-<slot>].conf
 *   hold both                     -> video (USER is sampled second and wins)
 *   hold neither                  -> $target=default, $bootconf untouched
 *
 * $target names the profile for the signed-FIT path (nixbadge_fit sources the
 * slot boot.itb's script-${target}, which boots conf-${target}); $bootconf
 * names the extlinux conf for the legacy tail (nixbadge_legacy, compiled in
 * only where sysboot is). The -<slot> suffix is added when $rauc_slot is set
 * (see btnsel_set_conf()).
 *
 * The running system claims USER (badge-video clips, OLED daemon), but only
 * once Linux is up, so U-Boot can read it here. Nothing below leaves the pad
 * or the line in a changed state.
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
 * S3 USER: RTCSYS_GPIO (snps,dw-apb-gpio @ 0x05021000, the always-on RTC/PWR
 * bank; Linux "porte") line 2, active low. Named "user-btn" in the badgeos
 * DTS gpio-line-names. Pad PWR_GPIO2, whose reset-default function 0 is
 * PWR_GPIO_2 (cv181x_pinlist_swconfig.h); the mux is forced to 0 for the read
 * in case anything changed it, and restored after, as is the direction bit.
 *
 *   RTC GPIO   0x05021000   (+0x04 DDR, 1=out;  +0x50 EXT_PORTA, live input)
 *   USER bit   2
 *   PWR_GPIO2 mux 0x030010AC (PINMUX_BASE + FUNCSEL_PWR_GPIO2 0xAC),
 *                           low 3 bits: 0 = PWR_GPIO_2
 *
 * bootcmd runs after the autoboot delay (main_loop -> autoboot_command ->
 * abortboot, then the command), so the buttons are read at the end of the
 * countdown; that is the window the STAT LED blinks through. (The secure
 * build has no countdown, BOOTDELAY=-2: hold the button from power-up.)
 *
 * Fails safe: $target is "default" unless a button reads held, and
 * nixbadge_legacy sets `bootconf` to the default conf just before running
 * btnsel, which only overrides it. The USER read also checks that its mux and
 * direction writes took, and reports "not held" if not. A profile the card
 * does not carry falls back to the default too: nixbadge_fit sources
 * script-default when script-${target} is missing, and nixbadge_legacy's
 * `sysboot ... ${bootconf}` is followed by a sysboot of the default conf.
 *
 * BTNSEL_DESKTOP_CONF and BTNSEL_VIDEO_CONF are #defined per core by the
 * U-Boot derivation's postPatch (/arm/... vs /riscv/...) before this file is
 * appended.
 */
#include <env.h>
#include <linux/delay.h>

#ifndef BTNSEL_DESKTOP_CONF
#define BTNSEL_DESKTOP_CONF "/arm/extlinux/extlinux-desktop.conf"
#endif
#ifndef BTNSEL_VIDEO_CONF
#define BTNSEL_VIDEO_CONF "/arm/extlinux/extlinux-video.conf"
#endif

#define XGPIOB_BASE		0x03021000UL
#define XGPIOB_DDR		(XGPIOB_BASE + 0x04)
#define XGPIOB_EXT		(XGPIOB_BASE + 0x50)
#define BOOT_BTN_BIT		4

#define BTNSEL_PINMUX_BASE	0x03001000UL
#define BTNSEL_USB_ID_FUNCSEL	(BTNSEL_PINMUX_BASE + 0xFC)
#define BTNSEL_FUNCSEL_MASK	0x7
#define BTNSEL_FUNC_XGPIOB_4	0x3

#define RTCGPIO_BASE		0x05021000UL
#define RTCGPIO_DDR		(RTCGPIO_BASE + 0x04)
#define RTCGPIO_EXT		(RTCGPIO_BASE + 0x50)
#define USER_BTN_BIT		2

#define BTNSEL_PWR_GPIO2_FUNCSEL (BTNSEL_PINMUX_BASE + 0xAC)
#define BTNSEL_FUNC_PWR_GPIO_2	0x0

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


/* Same contract as boot_btn_held(), for S3 USER on RTC GPIO line 2. A mux or
 * direction write that does not read back also means "not held", so a USER
 * misread can only leave $bootconf where BOOT put it. Pad mux and direction
 * bit are restored on every path. */
static int user_btn_held(void)
{
	uint32_t mux, ddr;
	int i, held = 1;

	/* PWR_GPIO2 pad -> PWR_GPIO_2 (its reset default), remembering it. */
	mux = mmio_read_32(BTNSEL_PWR_GPIO2_FUNCSEL);
	mmio_write_32(BTNSEL_PWR_GPIO2_FUNCSEL,
		      (mux & ~BTNSEL_FUNCSEL_MASK) | BTNSEL_FUNC_PWR_GPIO_2);

	/* Direction = input for line 2 only. */
	ddr = mmio_read_32(RTCGPIO_DDR);
	mmio_write_32(RTCGPIO_DDR, ddr & ~(1u << USER_BTN_BIT));

	if ((mmio_read_32(BTNSEL_PWR_GPIO2_FUNCSEL) & BTNSEL_FUNCSEL_MASK) !=
		    BTNSEL_FUNC_PWR_GPIO_2 ||
	    ((mmio_read_32(RTCGPIO_DDR) >> USER_BTN_BIT) & 1)) {
		held = 0;	/* setup did not take: fail safe */
	} else {
		for (i = 0; i < BTNSEL_SAMPLES; i++) {
			if ((mmio_read_32(RTCGPIO_EXT) >> USER_BTN_BIT) & 1) {
				held = 0;	/* high = released */
				break;
			}
			mdelay(BTNSEL_SAMPLE_MS);
		}
	}

	mmio_write_32(RTCGPIO_DDR, ddr);
	mmio_write_32(BTNSEL_PWR_GPIO2_FUNCSEL, mux);
	return held;
}

/*
 * With $rauc_slot set, splice "-<slot>" in before ".conf" of the compiled-in
 * per-core conf path (hush expands ${var} only one level, so the env strings
 * cannot build that name themselves). nixbadge_try runs btnsel with rauc_slot
 * set but only uses $target; nixbadge_legacy clears rauc_slot first and gets
 * the fixed legacy conf, the only one an ext4-mbr card has.
 *
 * conf is one of the two compiled-in paths and conf_size its sizeof;
 * what is the "<button> held -> <profile>" message prefix.
 */
#define BTNSEL_CONF_MAX							\
	(sizeof(BTNSEL_DESKTOP_CONF) > sizeof(BTNSEL_VIDEO_CONF) ?	\
	 sizeof(BTNSEL_DESKTOP_CONF) : sizeof(BTNSEL_VIDEO_CONF))

static void btnsel_set_conf(const char *conf, size_t conf_size,
			    const char *slot, const char *what)
{
	char buf[BTNSEL_CONF_MAX + 16];

	if (slot && *slot) {
		/* sizeof(STR) - sizeof(SUFFIX), both counting their own NUL,
		 * cancels down to strlen(STR) - strlen(SUFFIX): the length of
		 * conf before its known ".conf" suffix. */
		size_t base_len = conf_size - sizeof(".conf");

		snprintf(buf, sizeof(buf), "%.*s-%s.conf",
			 (int)base_len, conf, slot);
		conf = buf;
	}
	env_set("bootconf", conf);
	printf("btnsel: %s (%s)\n", what, conf);
}

static int do_btnsel(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	const char *slot = env_get("rauc_slot");
	const char *target = "default";

	if (boot_btn_held()) {
		target = "desktop";
		btnsel_set_conf(BTNSEL_DESKTOP_CONF, sizeof(BTNSEL_DESKTOP_CONF),
				slot, "BOOT held -> desktop");
	} else {
		printf("btnsel: BOOT not held -> default profile (hold BOOT for desktop)\n");
	}

	/* USER is sampled after BOOT and overrides it: both held -> video. */
	if (user_btn_held()) {
		target = "video";
		btnsel_set_conf(BTNSEL_VIDEO_CONF, sizeof(BTNSEL_VIDEO_CONF),
				slot, "USER held -> video");
	} else {
		printf("btnsel: USER not held (hold USER for video)\n");
	}

	env_set("target", target);
	printf("btnsel: target %s\n", target);
	return 0;
}

U_BOOT_CMD(btnsel, 1, 0, do_btnsel,
	   "set $target and $bootconf from the BOOT (desktop) and USER (video) buttons",
	   "  - read BOOT (XGPIOB 0x03021000 line 4, active low) for ~80ms:\n"
	   "    held throughout -> $target=desktop and the desktop conf; otherwise\n"
	   "    leave $bootconf alone. The USB_ID pad is muxed to XGPIOB_4 for the\n"
	   "    read and restored afterwards. Then read USER (RTC GPIO 0x05021000\n"
	   "    line 2, active low, pad PWR_GPIO2) the same way: held throughout ->\n"
	   "    $target=video and the video conf, overriding BOOT if both are held.\n"
	   "    $target is \"default\" when neither is held. With $rauc_slot set the\n"
	   "    conf is extlinux-<profile>-<slot>.conf, else extlinux-<profile>.conf.\n"
	   "    Runs from bootcmd, i.e. AFTER the autoboot countdown, so hold\n"
	   "    the button while STAT is blinking. It never fails.");
