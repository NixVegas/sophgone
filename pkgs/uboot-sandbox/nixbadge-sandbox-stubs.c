/* nix-badge uboot-sandbox test stand-ins (not part of the vendor tree); see
 * pkgs/uboot-sandbox/package.nix. sysboot echoes its arguments; with $sb_files
 * set it also models a missing conf (return 1) and a successful boot (print,
 * exit 0). load copies a fixture file named by $sb_files from $sb_dir into RAM.
 * sdready echoes a marker and always fails. part answers `uuid` and `start`
 * from $sb_parts / $sb_ubs.
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

/* A boot happened and, like a real one, never returns: print "BOOTED <what>"
 * and one "name=value" line per word of $sb_show, then exit the sandbox 0.
 * Called by the sysboot stand-in and by the bootm hook in
 * arch/sandbox/lib/bootm.c. */
void nixbadge_sb_booted(const char *what)
{
	const char *show, *p;
	char name[64];

	printf("BOOTED %s\n", what);
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
	char val[32];
	const char *n;

	if (argc == 5 && !strcmp(argv[1], "uuid")) {
		n = strchr(argv[3], ':');
		if (n && nixbadge_sb_has("sb_parts", n + 1)) {
			snprintf(val, sizeof(val), "sbuuid-%s", n + 1);
			env_set(argv[4], val);
			return CMD_RET_SUCCESS;
		}
		printf("** No partition %s **\n", argv[3]);
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
	   "nixbadge uboot-sandbox test stub: answers uuid/start from $sb_parts/$sb_ubs",
	   "");

static int do_nixbadge_stub_load(struct cmd_tbl *cmdtp, int flag, int argc,
				  char *const argv[])
{
	const char *dir = env_get("sb_dir");
	char fname[512];
	void *buf;
	void *dst;
	int size;
	ulong addr;

	if (argc != 5)
		return CMD_RET_USAGE;
	if (!dir || !nixbadge_sb_has("sb_files", argv[4]) ||
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
	   "nixbadge uboot-sandbox test stub: copies $sb_dir<path> to <addr> if <path> is in $sb_files",
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
