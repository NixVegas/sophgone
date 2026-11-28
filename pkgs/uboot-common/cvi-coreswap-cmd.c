/*
 * `coreswap` -- ask the ARM FSBL to start the main C906 after the next reset,
 * and tell the kernel how the last request ended.
 *
 * `coreswap request` (ARM only) is run by nixbadge_coreswap (nixbadge.env). It
 * wants an SD boot whose first partition holds /coreswap.request and
 * /coreswap.pending, both exactly "riscv\n", and writes the request into two
 * RTC information words, which keep their value over a reset. The FSBL
 * (pkgs/fsbl/coreswap-transfer.inc.c) consumes it before it loads anything.
 *
 * RTC core at 0x05026000:
 *   INFO0 +0x1c  CORESWAP_RUN, written last
 *   INFO1 +0x20  its inverse, written first
 *   INFO2 +0x24
 *   INFO3 +0x28
 * All four must hold their defaults before anything is written, and a request
 * that does not read back is undone.
 *
 * The boot source is the flag the FSBL leaves at 0x0e000004 (see
 * cvi-env-medium.c).
 *
 * `coreswap report` appends nixbadge.coreswap=<result> to $nixbadge_args from
 * $nixbadge_coreswap_result: ok, timeout or disabled (also when unset).
 */
#include <common.h>
#include <command.h>
#include <env.h>
#include <fs.h>
#include <mapmem.h>
#include <asm/io.h>
#include <asm/cache.h>

#define CORESWAP_RTC_BASE	0x05026000UL
#define CORESWAP_INFO		(CORESWAP_RTC_BASE + 0x1c)
#define CORESWAP_INFO0_DEFAULT	0xabcd1234
#define CORESWAP_INFO1_DEFAULT	0xdeadbeef
#define CORESWAP_RUN		0x43535731	/* "CSW1" */

#define CORESWAP_BOOT_SOURCE	0x0e000004UL
#define CORESWAP_BOOT_SOURCE_SD	0x4d474e32	/* "MGN2" */

#ifdef __aarch64__
static int coreswap_request_file(const char *name)
{
	char data[ARCH_DMA_MINALIGN] __aligned(ARCH_DMA_MINALIGN);
	loff_t actual = 0;

	if (fs_set_blk_dev("mmc", "0:1", FS_TYPE_FAT) ||
	    fs_read(name, map_to_sysmem(data), 0, 7, &actual))
		return 0;
	return actual == 6 && !memcmp(data, "riscv\n", 6);
}

static int coreswap_request(void)
{
	volatile u32 *info = (void *)CORESWAP_INFO;
	const u32 defaults[] = {CORESWAP_INFO0_DEFAULT, CORESWAP_INFO1_DEFAULT,
				CORESWAP_INFO0_DEFAULT, CORESWAP_INFO1_DEFAULT};
	u32 magic = CORESWAP_RUN;
	unsigned int i;

	if (readl((void *)CORESWAP_BOOT_SOURCE) != CORESWAP_BOOT_SOURCE_SD ||
	    !coreswap_request_file("/coreswap.request") ||
	    !coreswap_request_file("/coreswap.pending")) {
		puts("coreswap: requires matching request and pending files on boot SD\n");
		return CMD_RET_FAILURE;
	}
	for (i = 0; i < ARRAY_SIZE(defaults); i++) {
		if (readl(info + i) != defaults[i]) {
			puts("coreswap: retained information words are occupied\n");
			return CMD_RET_FAILURE;
		}
	}
	writel(~magic, info + 1);
	__asm__ volatile ("dsb sy" ::: "memory");
	writel(magic, info);
	__asm__ volatile ("dsb sy" ::: "memory");
	if (readl(info) == magic && readl(info + 1) == ~magic)
		return CMD_RET_SUCCESS;
	writel(defaults[0], info);
	writel(defaults[1], info + 1);
	__asm__ volatile ("dsb sy" ::: "memory");
	puts("coreswap: request did not read back\n");
	return CMD_RET_FAILURE;
}
#endif

static int do_coreswap(struct cmd_tbl *cmdtp, int flag, int argc, char * const argv[])
{
	const char *result = env_get("nixbadge_coreswap_result");
	const char *old;
	char args[256];
	int length;

	if (argc != 2)
		return CMD_RET_USAGE;
	if (!strcmp(argv[1], "request")) {
#ifdef __aarch64__
		return coreswap_request();
#else
		puts("coreswap: forward requests require ARM\n");
		return CMD_RET_FAILURE;
#endif
	}
	if (strcmp(argv[1], "report"))
		return CMD_RET_USAGE;
	if (!result)
		result = "disabled";
	if (strcmp(result, "ok") && strcmp(result, "timeout") &&
	    strcmp(result, "retained") && strcmp(result, "disabled"))
		return CMD_RET_FAILURE;
	old = env_get("nixbadge_args");
	length = snprintf(args, sizeof(args), "%s nixbadge.coreswap=%s", old ? old : "", result);
	if (length < 0 || (size_t)length >= sizeof(args))
		return CMD_RET_FAILURE;
	return env_set("nixbadge_args", args) ? CMD_RET_FAILURE : CMD_RET_SUCCESS;
}

U_BOOT_CMD(coreswap, 2, 0, do_coreswap,
	"request a guarded software core handoff or report its result",
	"request - record one ARM-to-RISC-V request; requires matching SD pending file\n"
	"coreswap report - append the boot result to the kernel arguments\n"
	"Selection: /coreswap.request on boot SD contains riscv followed by newline.\n"
	"Absent or other contents retain the strap core; a pending attempt blocks retries.");
