/* Filesystem and request stand-ins for the core-transfer HUSH tests. */
#include <fs.h>

int nixbadge_sb_file_exists(const char *interface, const char *dev,
			   const char *name, int type)
{
	if (strcmp(interface, "mmc") || strcmp(dev, "0:1"))
		return file_exists(interface, dev, name, type);
	if (!strcmp(name, "/coreswap.pending"))
		return env_get("sb_pending") != NULL;
	return nixbadge_sb_has("sb_files", name);
}

static int do_sb_coreswap_write(struct cmd_tbl *cmdtp, int flag, int argc,
			       char * const argv[])
{
	ulong size, address;
	void *data;

	if (argc != 6 || strcmp(argv[1], "mmc") || strcmp(argv[2], "0:1"))
		return CMD_RET_USAGE;
	printf("CORESWAP-WRITE %s %s\n", argv[4], argv[5]);
	if (env_get("sb_write_failure"))
		return CMD_RET_FAILURE;
	size = hextoul(argv[5], NULL);
	address = hextoul(argv[3], NULL);
	data = map_sysmem(address, size);
	if (!strcmp(argv[4], "/coreswap.pending")) {
		if (size != 6 || memcmp(data, "riscv\n", 6))
			return CMD_RET_FAILURE;
		env_set("sb_pending", "1");
	} else {
		return CMD_RET_FAILURE;
	}
	unmap_sysmem(data);
	return CMD_RET_SUCCESS;
}

U_BOOT_CMD(fatwrite, 7, 0, do_sb_coreswap_write,
	   "core-transfer test filesystem write", "");

static int do_sb_coreswap(struct cmd_tbl *cmdtp, int flag, int argc,
			 char * const argv[])
{
	if (argc != 2 || strcmp(argv[1], "request"))
		return CMD_RET_USAGE;
	puts("CORESWAP-REQUEST\n");
	return (!env_get("sb_pending") || env_get("sb_request_failure")) ?
		CMD_RET_FAILURE : CMD_RET_SUCCESS;
}

U_BOOT_CMD(coreswap, 2, 0, do_sb_coreswap,
	   "core-transfer test request", "");
