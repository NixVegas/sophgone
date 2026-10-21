/*
 * `btnsel` -- pick the boot profile from the BOOT and USER buttons at power-up.
 *
 *   hold neither                  -> $target=$nixbadge_profile_default
 *   hold BOOT (S1, marked UPDATE) -> $target=$nixbadge_profile_boot
 *   hold USER (S3)                -> $target=$nixbadge_profile_user
 *   hold both                     -> factory reset: $target=$nixbadge_profile_default
 *                                    and $nixbadge_args=nixbadge.reset=userdata
 *
 * $nixbadge_args is cleared in every other case. The profile variables default
 * to default, desktop and video (nixbadge.env); one that is unset, empty,
 * longer than BTNSEL_NAME_MAX or not [A-Za-z0-9_-] falls back to that
 * built-in name.
 *
 * $target names the profile for the signed-FIT path (nixbadge_fit sources the
 * slot boot.itb's script-${target}, which boots conf-${target}); the profile
 * script appends ${nixbadge_args} to bootargs. For the legacy tail
 * (nixbadge_legacy, compiled in only where sysboot is) a target other than
 * "default" sets $bootconf to BTNSEL_CONF_DIR/extlinux-<target>[-<slot>].conf,
 * with -<slot> only when $rauc_slot is set; "default" leaves $bootconf alone.
 *
 * The running system claims USER (nix-badge-video clips, OLED daemon), but only
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
 * Fails safe: a button reads held only if every sample agrees, and the USER
 * read also checks that its mux and direction writes took, so a misread means
 * "not held". nixbadge_legacy sets `bootconf` to the default conf just before
 * running btnsel, which only overrides it. A profile the card does not carry
 * falls back to the default too: nixbadge_fit sources script-default when
 * script-${target} is missing, and nixbadge_legacy's `sysboot ... ${bootconf}`
 * is followed by a sysboot of the default conf.
 *
 * BTNSEL_CONF_DIR is #defined per core by the U-Boot derivation's postPatch
 * (/arm/extlinux vs /riscv/extlinux) before this file is appended.
 */
#include <env.h>
#include <linux/ctype.h>
#include <linux/delay.h>

#ifndef BTNSEL_CONF_DIR
#define BTNSEL_CONF_DIR "/arm/extlinux"
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

#define BTNSEL_NAME_MAX		32
#define BTNSEL_RESET_ARGS	"nixbadge.reset=userdata"

/* Copy $var into name (BTNSEL_NAME_MAX + 1 bytes) if it is a usable profile
 * name, else fallback. The name ends up in a FAT path and a FIT node path. */
static void btnsel_profile(char *name, const char *var, const char *fallback)
{
	const char *s = env_get(var);
	size_t i, n = s ? strlen(s) : 0;

	for (i = 0; i < n; i++)
		if (!isalnum(s[i]) && s[i] != '-' && s[i] != '_')
			break;
	if (n == 0 || n > BTNSEL_NAME_MAX || i < n) {
		if (n)
			printf("btnsel: $%s is not a profile name, using %s\n",
			       var, fallback);
		s = fallback;
	}
	strlcpy(name, s, BTNSEL_NAME_MAX + 1);
}

/*
 * $bootconf for the legacy tail (hush expands ${var} only one level, so the
 * env strings cannot build that name themselves). nixbadge_try runs btnsel
 * with rauc_slot set but only uses $target; nixbadge_legacy clears rauc_slot
 * first and gets the per-profile conf without a slot suffix, the only one an
 * ext4-mbr card has.
 */
static void btnsel_set_conf(const char *target, const char *slot)
{
	char conf[sizeof(BTNSEL_CONF_DIR "/extlinux--.conf") + BTNSEL_NAME_MAX + 16];
	int n;

	if (!strcmp(target, "default"))
		return;
	if (slot && *slot)
		n = snprintf(conf, sizeof(conf), BTNSEL_CONF_DIR "/extlinux-%s-%s.conf",
			     target, slot);
	else
		n = snprintf(conf, sizeof(conf), BTNSEL_CONF_DIR "/extlinux-%s.conf",
			     target);
	if (n < 0 || n >= (int)sizeof(conf))
		return;
	env_set("bootconf", conf);
	printf("btnsel: conf %s\n", conf);
}

static int do_btnsel(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	char target[BTNSEL_NAME_MAX + 1];
	const char *args = "";
	const char *what;
	int boot = boot_btn_held();
	int user = user_btn_held();

	if (boot && user) {
		what = "BOOT and USER held, factory reset";
		btnsel_profile(target, "nixbadge_profile_default", "default");
		args = BTNSEL_RESET_ARGS;
	} else if (boot) {
		what = "BOOT held";
		btnsel_profile(target, "nixbadge_profile_boot", "desktop");
	} else if (user) {
		what = "USER held";
		btnsel_profile(target, "nixbadge_profile_user", "video");
	} else {
		what = "no button held";
		btnsel_profile(target, "nixbadge_profile_default", "default");
	}
	printf("btnsel: %s -> %s\n", what, target);

	btnsel_set_conf(target, env_get("rauc_slot"));
	/* An empty value deletes the variable: ${nixbadge_args} expands to "". */
	env_set("nixbadge_args", args);
	env_set("target", target);
	printf("btnsel: target %s\n", target);
	return 0;
}

U_BOOT_CMD(btnsel, 1, 0, do_btnsel,
	   "set $target, $nixbadge_args and $bootconf from the BOOT and USER buttons",
	   "  - read BOOT (XGPIOB 0x03021000 line 4, active low) and USER (RTC GPIO\n"
	   "    0x05021000 line 2, active low, pad PWR_GPIO2) for ~80ms each; a\n"
	   "    button is held only if it reads low throughout. Pad mux and\n"
	   "    direction are restored afterwards.\n"
	   "      neither -> $target=$nixbadge_profile_default\n"
	   "      BOOT    -> $target=$nixbadge_profile_boot\n"
	   "      USER    -> $target=$nixbadge_profile_user\n"
	   "      both    -> $target=$nixbadge_profile_default and\n"
	   "                 $nixbadge_args=" BTNSEL_RESET_ARGS "\n"
	   "    $nixbadge_args is cleared otherwise. Unset or invalid profile names\n"
	   "    fall back to default, desktop and video. A target other than\n"
	   "    default sets $bootconf to extlinux-<target>[-<rauc_slot>].conf.\n"
	   "    Runs from bootcmd, i.e. AFTER the autoboot countdown, so hold\n"
	   "    the buttons while STAT is blinking. It never fails.");
