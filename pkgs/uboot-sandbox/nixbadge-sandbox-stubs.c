/* nix-badge uboot-sandbox test stand-ins (not part of the vendor tree); see
 * pkgs/uboot-sandbox/package.nix. sysboot echoes its arguments; with $sb_files
 * set it also models a missing conf (return 1) and a successful boot (print,
 * exit 0). load copies a fixture file named by $sb_files from $sb_dir into RAM.
 * sdready echoes a marker and always fails. part answers `uuid` and `start`
 * from $sb_parts / $sb_ubs, and `number` (a partition by name). Per-device
 * $sb_parts<dev> (`<n>:<name>` words), $sb_files<dev> and $sb_dir<dev> model a second
 * card; without them $sb_parts, $sb_files and $sb_dir stand for whichever device is
 * asked.
 */
#include <common.h>
#include <command.h>
#include <env.h>
#include <mapmem.h>
#include <os.h>
#include <vsprintf.h>
#include <linux/string.h>

/* 1 if `word` is one of the space-separated words of env var `list` */
static int nixbadge_sb_has(const char *list, const char *word)
{
	const char *l = env_get(list), *p;
	size_t n = strlen(word);

	if (!l)
		return 0;
	for (p = l; *p; ) {
		while (*p == ' ')
			p++;
		if (!strncmp(p, word, n) && (p[n] == ' ' || p[n] == '\0'))
			return 1;
		while (*p && *p != ' ')
			p++;
	}
	return 0;
}

/* The `<n>:<name>` word of $sb_parts<dev> whose number is `num` (match on
 * "num:") or whose name is `name` (match on ":name"); its number in *out. */
static int nixbadge_sb_part(const char *dev, const char *num, const char *name,
			    char *out, size_t outlen)
{
	char var[24];
	const char *l, *p;

	snprintf(var, sizeof(var), "sb_parts%s", dev);
	l = env_get(var);
	if (!l)
		return -1;
	for (p = l; *p; ) {
		const char *w, *c;
		size_t n;

		while (*p == ' ')
			p++;
		w = p;
		while (*p && *p != ' ')
			p++;
		n = p - w;
		c = memchr(w, ':', n);
		if (!c)
			continue;
		if ((num && (size_t)(c - w) == strlen(num) && !strncmp(w, num, c - w)) ||
		    (name && (size_t)(w + n - c - 1) == strlen(name) &&
		     !strncmp(c + 1, name, w + n - c - 1))) {
			snprintf(out, outlen, "%.*s", (int)(c - w), w);
			return 0;
		}
	}
	return 1;
}

/* The device of a `dev[:part]` argument, into buf. */
static const char *nixbadge_sb_dev(const char *arg, char *buf, size_t len)
{
	const char *c = strchr(arg, ':');

	snprintf(buf, len, "%.*s", c ? (int)(c - arg) : (int)strlen(arg), arg);
	return buf;
}

/* A boot happened and, like a real one, never returns: print "BOOTED <what>"
 * and one "name=value" line per word of $sb_show, then exit the sandbox 0.
 * Called by the sysboot stand-in and by the bootm hook in
 * arch/sandbox/lib/bootm.c. */
static void nixbadge_sb_show(void)
{
	const char *show, *p;
	char name[64];

	show = env_get("sb_show");
	for (p = show; p && *p; ) {
		size_t n = 0;

		while (*p == ' ')
			p++;
		while (p[n] && p[n] != ' ' && n < sizeof(name) - 1) {
			name[n] = p[n];
			n++;
		}
		name[n] = '\0';
		p += n;
		if (n) {
			const char *v = env_get(name);

			printf("%s=%s\n", name, v ? v : "");
		}
	}
}

void nixbadge_sb_booted(const char *what)
{
	printf("BOOTED %s\n", what);
	nixbadge_sb_show();
	os_exit(0);
}

static int do_nixbadge_stub_sysboot(struct cmd_tbl *cmdtp, int flag, int argc,
				     char *const argv[])
{
	int i;

	puts("SYSBOOT");
	for (i = 1; i < argc; i++) {
		puts(" ");
		puts(argv[i]);
	}
	puts("\n");
	if (!env_get("sb_files") || argc < 6)
		return CMD_RET_SUCCESS;
	if (!nixbadge_sb_has("sb_files", argv[5])) {
		printf("SYSBOOT-MISSING %s\n", argv[5]);
		return CMD_RET_FAILURE;
	}
	nixbadge_sb_booted(argv[5]);
	return CMD_RET_SUCCESS;	/* not reached */
}

U_BOOT_CMD(sysboot, 8, 0, do_nixbadge_stub_sysboot,
	   "nixbadge uboot-sandbox test stub: records the call, models $sb_files",
	   "");

static int do_nixbadge_stub_sdready(struct cmd_tbl *cmdtp, int flag, int argc,
				     char *const argv[])
{
	puts("SDREADY-CALLED\n");
	return CMD_RET_FAILURE;
}

U_BOOT_CMD(sdready, 1, 0, do_nixbadge_stub_sdready,
	   "nixbadge uboot-sandbox test stub: records the call, always fails",
	   "");

static int do_nixbadge_stub_part(struct cmd_tbl *cmdtp, int flag, int argc,
				  char *const argv[])
{
	char val[32], dev[16], num[16];
	const char *n;
	int r;

	if (argc == 5 && !strcmp(argv[1], "uuid")) {
		n = strchr(argv[3], ':');
		r = n ? nixbadge_sb_part(nixbadge_sb_dev(argv[3], dev, sizeof(dev)),
					 n + 1, NULL, num, sizeof(num)) : 1;
		if (n && (r == 0 || (r < 0 && nixbadge_sb_has("sb_parts", n + 1)))) {
			snprintf(val, sizeof(val), "sbuuid-%s", n + 1);
			env_set(argv[4], val);
			return CMD_RET_SUCCESS;
		}
		printf("** No partition %s **\n", argv[3]);
		return CMD_RET_FAILURE;
	}
	if (argc == 6 && !strcmp(argv[1], "number")) {
		if (!nixbadge_sb_part(argv[3], NULL, argv[4], num, sizeof(num))) {
			snprintf(val, sizeof(val), "0x%lx", simple_strtoul(num, NULL, 10));
			env_set(argv[5], val);
			return CMD_RET_SUCCESS;
		}
		printf("** No partition %s on %s %s **\n", argv[4], argv[2], argv[3]);
		return CMD_RET_FAILURE;
	}
	if (argc == 6 && !strcmp(argv[1], "start") && env_get("sb_ubs")) {
		env_set(argv[5], env_get("sb_ubs"));
		return CMD_RET_SUCCESS;
	}
	printf("** part stub: no answer for %s **\n", argc > 1 ? argv[1] : "");
	return CMD_RET_FAILURE;
}

U_BOOT_CMD(part, 6, 0, do_nixbadge_stub_part,
	   "nixbadge uboot-sandbox test stub: answers uuid/start/number from $sb_parts[<dev>]/$sb_ubs",
	   "");

static int do_nixbadge_stub_load(struct cmd_tbl *cmdtp, int flag, int argc,
				  char *const argv[])
{
	const char *dir;
	char files[24], dirvar[24], dev[16];
	char fname[512];
	void *buf;
	void *dst;
	int size;
	ulong addr;

	if (argc != 5)
		return CMD_RET_USAGE;
	snprintf(files, sizeof(files), "sb_files%s", nixbadge_sb_dev(argv[2], dev, sizeof(dev)));
	if (!env_get(files))
		strcpy(files, "sb_files");
	snprintf(dirvar, sizeof(dirvar), "sb_dir%s", dev);
	dir = env_get(dirvar) ? env_get(dirvar) : env_get("sb_dir");
	if (!dir || !nixbadge_sb_has(files, argv[4]) ||
	    snprintf(fname, sizeof(fname), "%s%s", dir, argv[4]) >= sizeof(fname) ||
	    os_read_file(fname, &buf, &size)) {
		printf("** Unable to read file %s **\n", argv[4]);
		return CMD_RET_FAILURE;
	}
	addr = hextoul(argv[3], NULL);
	dst = map_sysmem(addr, size);
	memcpy(dst, buf, size);
	unmap_sysmem(dst);
	os_free(buf);
	env_set_hex("filesize", size);
	printf("%d bytes read\n", size);
	return CMD_RET_SUCCESS;
}

U_BOOT_CMD(load, 5, 0, do_nixbadge_stub_load,
	   "nixbadge uboot-sandbox test stub: copies $sb_dir[<dev>]<path> to <addr> if <path> is in $sb_files[<dev>]",
	   "<interface> <dev:part> <addr> <path>");

/* The secure walk's end (pkgs/uboot-common/cvi-halt-cmd.c idles forever on
 * the board): report and exit the sandbox, like a boot, instead. */
static int do_nixbadge_stub_halt(struct cmd_tbl *cmdtp, int flag, int argc,
				  char *const argv[])
{
	puts("HALTED\n");
	os_exit(0);
	return CMD_RET_FAILURE;	/* not reached */
}

U_BOOT_CMD(nixbadge_halt, 1, 0, do_nixbadge_stub_halt,
	   "nixbadge uboot-sandbox test stub: prints HALTED and exits the sandbox",
	   "");

/* The board's `reset` (cmd/boot.c calls do_reset; the sysreset one is
 * configured out): print "RESET" and the $sb_show values, like a boot, and
 * exit instead of relaunching the sandbox. */
int do_reset(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
	puts("RESET\n");
	nixbadge_sb_show();
	os_exit(0);
	return CMD_RET_FAILURE;	/* not reached */
}

/* The vendor eFuse API under the real strapsel, trng, devek and nixbadge_fuse
 * (uboot-common/cvi-{strapsel,trng,devek,fuse}-cmd.c, appended to this file by
 * package.nix): a 256-byte array of words, programmed 0 -> 1 like the fuses.
 *   sb_fused=1      starts provisioned as SG1-0003 with the board record
 *   sb_devek=set    starts with a non-zero DEVICE_EK
 *   sb_devek=locked starts with DEVICE_EK's lock bits set in the LOCK word
 *   sb_devek=partial starts with only one DEVICE_EK read-lock bit set
 *   sb_efuse=stuck  programming drops bit 0 of every word's first byte
 *   sb_efuser=fail  CVI_EFUSE_Read (`efuser`) fails, as an unimplemented SMC
 *                   does on arm
 *   sb_lock=fail    CVI_EFUSE_Lock returns -5 without setting the bits
 *   sb_lock=partial CVI_EFUSE_Lock returns 0 but sets only the write-lock
 *                   bits and one read-lock bit
 * CVI_EFUSE_Write prints "EFUSEW <area> <hex>", CVI_EFUSE_Lock "EFUSE-LOCK
 * DEVICE_EK". The TRNG and the core-select latch sit behind a fake MMIO,
 * below. */
#include <cvitek/cvi_efuse.h>

static u8 nixbadge_sb_efuse[0x100];
static const u8 nixbadge_sb_user_record[] = NIXBADGE_BOARD_USER;

static const struct {
	const char *name;
	u32 addr, size;
} nixbadge_sb_area[] = {
	[CVI_EFUSE_AREA_USER] = { "USER", 0x40, 40 },
	[CVI_EFUSE_AREA_DEVICE_ID] = { "DEVICE_ID", 0x8c, 8 },
	[CVI_EFUSE_AREA_DEVICE_EK] = { "DEVICE_EK", 0xe8, 16 },
};

#define NIXBADGE_SB_LOCK_DEVEK ((0x3 << 6) | (0x3 << 14))

static int nixbadge_sb_is(const char *var, const char *val)
{
	const char *v = env_get(var);

	return v && !strcmp(v, val);
}

/* logical byte i of an area -> its byte in the array (USER: stride-8 words) */
static u32 nixbadge_sb_off(enum CVI_EFUSE_AREA_E area, u32 i)
{
	if (area == CVI_EFUSE_AREA_USER)
		return 0x40 + 8 * (i / 4) + i % 4;
	return nixbadge_sb_area[area].addr + i;
}

static void nixbadge_sb_lock_or(u32 bits)
{
	u32 v;

	memcpy(&v, nixbadge_sb_efuse + 0xf8, 4);
	v |= bits;
	memcpy(nixbadge_sb_efuse + 0xf8, &v, 4);
}

static void nixbadge_sb_efuse_init(void)
{
	static int done;
	u32 i;

	if (done)
		return;
	done = 1;
	if (nixbadge_sb_is("sb_fused", "1")) {
		for (i = 0; i < 8; i++)
			nixbadge_sb_efuse[0x8c + i] = "SG1-0003"[i];
		for (i = 0; i < 40; i++)
			nixbadge_sb_efuse[nixbadge_sb_off(CVI_EFUSE_AREA_USER, i)] =
				nixbadge_sb_user_record[i];
	}
	if (nixbadge_sb_is("sb_devek", "set"))
		nixbadge_sb_efuse[0xe8] = 0x5a;
	if (nixbadge_sb_is("sb_devek", "locked"))
		nixbadge_sb_lock_or(NIXBADGE_SB_LOCK_DEVEK);
	if (nixbadge_sb_is("sb_devek", "partial"))
		nixbadge_sb_lock_or(0x1 << 14);
}

static int nixbadge_sb_area_ok(enum CVI_EFUSE_AREA_E area)
{
	return area == CVI_EFUSE_AREA_USER || area == CVI_EFUSE_AREA_DEVICE_ID ||
	       area == CVI_EFUSE_AREA_DEVICE_EK;
}

CVI_S32 CVI_EFUSE_Read(enum CVI_EFUSE_AREA_E area, CVI_U8 *buf, CVI_U32 buf_size)
{
	u32 i;

	nixbadge_sb_efuse_init();
	if (!nixbadge_sb_area_ok(area) || nixbadge_sb_is("sb_efuser", "fail"))
		return CVI_FAILURE;
	for (i = 0; i < buf_size && i < nixbadge_sb_area[area].size; i++)
		buf[i] = nixbadge_sb_efuse[nixbadge_sb_off(area, i)];
	return CVI_SUCCESS;
}

CVI_S32 CVI_EFUSE_Write(enum CVI_EFUSE_AREA_E area, const CVI_U8 *buf, CVI_U32 buf_size)
{
	int stuck = nixbadge_sb_is("sb_efuse", "stuck");
	u32 i;

	nixbadge_sb_efuse_init();
	if (!nixbadge_sb_area_ok(area))
		return CVI_FAILURE;
	printf("EFUSEW %s ", nixbadge_sb_area[area].name);
	for (i = 0; i < buf_size; i++)
		printf("%02x", buf[i]);
	puts("\n");
	for (i = 0; i < buf_size && i < nixbadge_sb_area[area].size; i++)
		nixbadge_sb_efuse[nixbadge_sb_off(area, i)] |=
			(stuck && i % 4 == 0) ? (buf[i] & ~1) : buf[i];
	return CVI_SUCCESS;
}

CVI_U32 CVI_EFUSE_Read_Word(CVI_U32 addr)
{
	u32 v;

	nixbadge_sb_efuse_init();
	memcpy(&v, nixbadge_sb_efuse + (addr & 0xfc), 4);
	return v;
}

CVI_S32 CVI_EFUSE_Lock(enum CVI_EFUSE_LOCK_E lock)
{
	nixbadge_sb_efuse_init();
	if (lock != CVI_EFUSE_LOCK_DEVICE_EK)
		return CVI_FAILURE;
	puts("EFUSE-LOCK DEVICE_EK\n");
	if (nixbadge_sb_is("sb_lock", "fail"))
		return -5;
	if (nixbadge_sb_is("sb_lock", "partial")) {
		nixbadge_sb_lock_or((0x3 << 6) | (0x1 << 14));
		return CVI_SUCCESS;
	}
	nixbadge_sb_lock_or(NIXBADGE_SB_LOCK_DEVEK);
	return CVI_SUCCESS;
}

/* The core this run plays for nixbadge_fuse: $sb_core=arm, else riscv. */
int nixbadge_sb_core_is_riscv(void)
{
	return !nixbadge_sb_is("sb_core", "arm");
}

/* The TRNG's registers (always idle and done, the four output words a
 * counter; $sb_trng=dead never answers, $sb_trng=stuck repeats one word) and the core-select latch on XGPIOB
 * (cvi-strapsel-cmd.c): a rising CP edge prints "LATCH <core>" and, with the
 * board switch on Auto ($sb_switch unset), moves the strap readback;
 * $sb_switch=arm or riscv pins it. */
static u32 nixbadge_sb_gpio_dr;
static int nixbadge_sb_strap = -1;	/* 1 = riscv */

static int nixbadge_sb_strap_now(void)
{
	if (nixbadge_sb_is("sb_switch", "arm"))
		return 0;
	if (nixbadge_sb_is("sb_switch", "riscv"))
		return 1;
	if (nixbadge_sb_strap < 0)
		nixbadge_sb_strap = nixbadge_sb_core_is_riscv();
	return nixbadge_sb_strap;
}

static u32 nixbadge_sb_mmio_read(uintptr_t a)
{
	static u32 n;

	if (a == 0x02070014UL)
		return nixbadge_sb_is("sb_trng", "dead") ? 0 : 0x10;
	if (a >= 0x02070024UL && a < 0x02070034UL)
		return nixbadge_sb_is("sb_trng", "stuck") ? 0x5a5a5a5a : 0x9e3779b9u * ++n;
	if (a == 0x03021000UL)
		return nixbadge_sb_gpio_dr;
	if (a == 0x03021050UL)
		return (u32)nixbadge_sb_strap_now() << 23;
	return 0;
}

static void nixbadge_sb_mmio_write(uintptr_t a, u32 v)
{
	if (a != 0x03021000UL)
		return;
	if (!(nixbadge_sb_gpio_dr & (1u << 11)) && (v & (1u << 11))) {
		int arm = (v >> 12) & 1;

		printf("LATCH %s\n", arm ? "arm" : "riscv");
		nixbadge_sb_strap_now();
		nixbadge_sb_strap = !arm;
	}
	nixbadge_sb_gpio_dr = v;
}
#define mmio_read_32(a) nixbadge_sb_mmio_read((uintptr_t)(a))
#define mmio_write_32(a, v) nixbadge_sb_mmio_write((uintptr_t)(a), (v))
