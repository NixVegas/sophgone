/* Prelude for the real cvi-btnsel-cmd.c in the sandbox: MMIO reads of BOOT's
 * EXT_PORTA (0x03021050, bit 4) and USER's (0x05021050, bit 2) read low when
 * $sb_btn / $sb_user = held, high otherwise; writes are dropped. Arm conf paths,
 * as tests/hush-rauc-walk.sh expects. */
#include <common.h>
#include <command.h>
#include <env.h>
#include <linux/string.h>
static uint32_t nixbadge_sb_mmio_read(uintptr_t a)
{
	const char *b = env_get("sb_btn");
	const char *u = env_get("sb_user");

	if (a == 0x03021050UL)
		return (b && !strcmp(b, "held")) ? 0 : (1u << 4);
	if (a == 0x05021050UL)
		return (u && !strcmp(u, "held")) ? 0 : (1u << 2);
	return 0;
}
#define mmio_read_32(a) nixbadge_sb_mmio_read((uintptr_t)(a))
#define mmio_write_32(a, v) ((void)(a), (void)(v))
#define BTNSEL_DESKTOP_CONF "/arm/extlinux/extlinux-desktop.conf"
#define BTNSEL_VIDEO_CONF "/arm/extlinux/extlinux-video.conf"
