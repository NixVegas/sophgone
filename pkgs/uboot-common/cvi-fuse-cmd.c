/*
 * `nixbadge_fuse <SERIAL>` -- make sure the board identity and the device key
 * are in eFuse, writing what is missing, never anything twice.
 *
 *   DEVICE_ID (0x8C, 8 B)  SERIAL as NUL-padded ASCII, SG1-0001 .. SG1-9999
 *   USER (40 B)            NIXBADGE_BOARD_USER, the fabricated-PCB record
 *                          (badgeos pkgs/badge/board-id/board_id.py), in the
 *                          ten stride-8 words 0x40, 0x48, ..., 0x88
 *   DEVICE_EK (0xE8, 16 B) a key from the on-die TRNG, read-locked after:
 *                          cvi_devek_burn(), the `devek burn` path
 *
 * Identity: written through CVI_EFUSE_Write(), the path of `efusew DEVICE_ID`
 * and `efusew USER`, only if all twelve words read zero (bits only go 0 -> 1);
 * otherwise the badge is provisioned and the stored serial is printed. The
 * words are read through CVI_EFUSE_Read() (`efuser`: the secure shadow on
 * riscv, an SMC on arm, which may be unimplemented there) and as the physical
 * array holds them (CVI_EFUSE_Read_Word(), both rows OR'd, as `efuser_word`
 * reads); either one non-zero counts. Success is judged on the physical
 * read-back, here and for the device key, because the margin check inside
 * the vendor write can false-negative (uboot-efuse-lock-verify.patch) and the
 * efuser path differs per core (secure shadow on riscv, SMC on arm).
 *
 * Device key: only the riscv core can reach the TRNG (cvi-trng-cmd.c). On
 * riscv, cvi_devek_burn() burns and locks a blank key once; a key that is
 * locked is done, one that is set but unlocked, or a burn that went wrong, is
 * reported loudly and never retried. The arm U-Boot never reads or writes
 * anything at or above 0xA0. Instead, if the board switch is on Auto (the
 * core-select latch moves the strap, cvi-strapsel-cmd.c), it writes nothing,
 * sets $nixbadge_fuse_return=arm, latches riscv and asks for a reset; the
 * riscv run then does both steps and latches arm again. With the switch
 * forced to ARM it writes the identity and reports the key as pending.
 *
 * The result is left in env flags for nixbadge_fuseonce (nixbadge.env):
 * $nb_done (nothing more to do: delete $nixbadge_fuse_serial and
 * $nixbadge_fuse_return) and $nb_reset (something was written or the core
 * changes: save the env and reset). A riscv run is always final, so a key
 * step that cannot even start cannot send the badge back and forth.
 *
 * Appended to cmd/efuse.c after the driver and cvi-strapsel-cmd.c,
 * cvi-trng-cmd.c and cvi-devek-cmd.c, with NIXBADGE_BOARD_USER #defined just
 * before it (uboot-common/package.nix).
 */
#include <command.h>
#include <env.h>
#include <linux/string.h>
#include <cvitek/cvi_efuse.h>

#define NB_FUSE_USER_WORDS 10
#define NB_FUSE_DID_ADDR 0x8c
#define NB_FUSE_DID_LEN 8
#define NB_FUSE_USER_LEN (4 * NB_FUSE_USER_WORDS)

static const u8 nb_fuse_user_record[] = NIXBADGE_BOARD_USER;
_Static_assert(sizeof(nb_fuse_user_record) == NB_FUSE_USER_LEN,
	       "NIXBADGE_BOARD_USER must be 40 bytes");
/* the last word read or written, DEVICE_ID's second, ends below SECURE_CONF */
_Static_assert(NB_FUSE_DID_ADDR + NB_FUSE_DID_LEN <= 0xa0,
	       "board identity words must stay below 0xA0");

/* SG1-%04d, 0001..9999, nothing else */
static int nb_fuse_serial_ok(const char *s)
{
	int i, n = 0;

	if (strlen(s) != NB_FUSE_DID_LEN || strncmp(s, "SG1-", 4))
		return 0;
	for (i = 4; i < NB_FUSE_DID_LEN; i++) {
		if (s[i] < '0' || s[i] > '9')
			return 0;
		n = n * 10 + (s[i] - '0');
	}
	return n >= 1;
}

/* USER word i of the gathered 40-byte record lives at 0x40 + 8 * i */
static u32 nb_fuse_user_addr(int i)
{
	return 0x40 + 8 * i;
}

/* the physical array, gathered: user[40] and did[8], little-endian per word
 * like CVI_EFUSE_Write's memcpy of each 4-byte chunk */
static void nb_fuse_read_phys(u8 *user, u8 *did)
{
	u32 v;
	int i;

	for (i = 0; i < NB_FUSE_USER_WORDS; i++) {
		v = CVI_EFUSE_Read_Word(nb_fuse_user_addr(i));
		memcpy(user + 4 * i, &v, 4);
	}
	for (i = 0; i < NB_FUSE_DID_LEN / 4; i++) {
		v = CVI_EFUSE_Read_Word(NB_FUSE_DID_ADDR + 4 * i);
		memcpy(did + 4 * i, &v, 4);
	}
}

static int nb_fuse_zero(const u8 *p, int n)
{
	while (n--)
		if (*p++)
			return 0;
	return 1;
}

/* print DEVICE_ID as the serial if it is one, else as hex */
static void nb_fuse_print_did(const u8 *did)
{
	int i, n = NB_FUSE_DID_LEN;

	while (n > 0 && !did[n - 1])
		n--;
	for (i = 0; i < n; i++)
		if (did[i] < 0x20 || did[i] > 0x7e)
			break;
	if (n && i == n) {
		printf("%.*s", n, (const char *)did);
		return;
	}
	if (!n) {
		puts("(no serial, USER written)");
		return;
	}
	puts("(DEVICE_ID ");
	for (i = 0; i < NB_FUSE_DID_LEN; i++)
		printf("%02x", did[i]);
	puts(")");
}

/* compare one area's physical read-back with what was written; print every
 * differing word */
static int nb_fuse_verify(const char *area, const u8 *got, const u8 *want,
			  int words, u32 (*addr)(int))
{
	int i, bad = 0;
	u32 g, w;

	for (i = 0; i < words; i++) {
		memcpy(&g, got + 4 * i, 4);
		memcpy(&w, want + 4 * i, 4);
		if (g != w) {
			printf("nixbadge_fuse: %s word 0x%02x reads 0x%08x, want 0x%08x\n",
			       area, addr(i), g, w);
			bad = 1;
		}
	}
	return bad;
}

static u32 nb_fuse_did_addr(int i)
{
	return NB_FUSE_DID_ADDR + 4 * i;
}

#if defined(CONFIG_SANDBOX)
/* the sandbox plays either core ($sb_core, pkgs/uboot-sandbox) */
int nixbadge_sb_core_is_riscv(void);
#define NB_FUSE_RISCV() nixbadge_sb_core_is_riscv()
#elif defined(__riscv)
#define NB_FUSE_RISCV() 1
#else
#define NB_FUSE_RISCV() 0
#endif

/* Make sure the identity is written. 0: it is (now or before), else failed.
 * Sets $nb_reset when it wrote something. */
static int nb_fuse_identity(const char *serial)
{
	u8 user[NB_FUSE_USER_LEN] __aligned(4), did[NB_FUSE_DID_LEN] __aligned(4);
	u8 suser[NB_FUSE_USER_LEN] __aligned(4), sdid[NB_FUSE_DID_LEN] __aligned(4);
	u8 want_did[NB_FUSE_DID_LEN] __aligned(4) = { 0 };
	int shadow, ret;

	memcpy(want_did, serial, NB_FUSE_DID_LEN);
	nb_fuse_read_phys(user, did);
	shadow = CVI_EFUSE_Read(CVI_EFUSE_AREA_DEVICE_ID, sdid, sizeof(sdid)) >= 0 &&
		 CVI_EFUSE_Read(CVI_EFUSE_AREA_USER, suser, sizeof(suser)) >= 0;
	if (!shadow)
		puts("nixbadge_fuse: efuser read unavailable, deciding on the physical read\n");
	if (!nb_fuse_zero(user, sizeof(user)) || !nb_fuse_zero(did, sizeof(did)) ||
	    (shadow && (!nb_fuse_zero(suser, sizeof(suser)) ||
			!nb_fuse_zero(sdid, sizeof(sdid))))) {
		puts("nixbadge_fuse: already provisioned ");
		nb_fuse_print_did(nb_fuse_zero(did, sizeof(did)) && shadow ? sdid : did);
		puts("\n");
		return 0;
	}

	printf("nixbadge_fuse: programming DEVICE_ID %s\n", serial);
	env_set("nb_reset", "1");
	ret = CVI_EFUSE_Write(CVI_EFUSE_AREA_DEVICE_ID, want_did, sizeof(want_did));
	nb_fuse_read_phys(user, did);
	if (nb_fuse_verify("DEVICE_ID", did, want_did, NB_FUSE_DID_LEN / 4,
			   nb_fuse_did_addr)) {
		printf("nixbadge_fuse: DEVICE_ID did not program (write returned %d), USER left blank\n",
		       ret);
		return -1;
	}

	puts("nixbadge_fuse: programming USER\n");
	ret = CVI_EFUSE_Write(CVI_EFUSE_AREA_USER, nb_fuse_user_record,
			      sizeof(nb_fuse_user_record));
	nb_fuse_read_phys(user, did);
	if (nb_fuse_verify("USER", user, nb_fuse_user_record, NB_FUSE_USER_WORDS,
			   nb_fuse_user_addr)) {
		printf("nixbadge_fuse: USER did not program (write returned %d)\n", ret);
		return -1;
	}

	printf("nixbadge_fuse: fused %s\n", serial);
	return 0;
}

#if defined(__riscv) || defined(CONFIG_SANDBOX)
/* Make sure the device key is burned and locked, at most one attempt.
 * 0: done, else done with a failure to report. Sets $nb_reset when it wrote
 * something. */
static int nb_fuse_key(void)
{
	switch (cvi_devek_burn()) {
	case CVI_DEVEK_OK:
		env_set("nb_reset", "1");
		return 0;
	case CVI_DEVEK_LOCKED:
		puts("nixbadge_fuse: device key already burned and locked\n");
		return 0;
	case CVI_DEVEK_SET:
		puts("nixbadge_fuse: devek: key set but NOT locked; not touching it\n");
		return -1;
	case CVI_DEVEK_REFUSED:
		printf("nixbadge_fuse: device key NOT burned (%s); re-run nix-badge-install to retry\n",
		       cvi_devek_why);
		return -1;
	case CVI_DEVEK_PARTIAL:
		puts("nixbadge_fuse: devek: key burned but NOT locked\n");
		return -1;
	case CVI_DEVEK_NOT_LOCKED:
		env_set("nb_reset", "1");
		puts("nixbadge_fuse: devek: key burned but NOT locked\n");
		return -1;
	default:
		env_set("nb_reset", "1");
		puts("nixbadge_fuse: device key step failed, the key may be partly burned and is not locked\n");
		return -1;
	}
}
#endif

static int do_nixbadge_fuse(struct cmd_tbl *cmdtp, int flag, int argc,
			    char *const argv[])
{
	const char *ret_core = env_get("nixbadge_fuse_return");
	int ok;

	if (argc != 2)
		return CMD_RET_USAGE;
	if (!nb_fuse_serial_ok(argv[1])) {
		puts("nixbadge_fuse: the serial must be SG1-0001 .. SG1-9999\n");
		env_set("nb_done", "1");
		return CMD_RET_FAILURE;
	}

	if (!NB_FUSE_RISCV()) {
		/* Hop to riscv once, if the switch is on Auto: the latch moves the
		 * strap. A return already recorded means a hop happened and the
		 * riscv run did not finish; do not try again. */
		if (!ret_core) {
			strapsel_latch(0);
			if (strapsel_readback()) {
				puts("nixbadge_fuse: switching to the riscv core to fuse; it switches back\n");
				env_set("nixbadge_fuse_return", "arm");
				env_set("nb_reset", "1");
				return CMD_RET_SUCCESS;
			}
			strapsel_latch(1);
		}
		ok = !nb_fuse_identity(argv[1]);
		if (!ok) {
			/* never retried: the words are no longer blank */
			env_set("nb_done", "1");
			return CMD_RET_FAILURE;
		}
		puts("nixbadge_fuse: device key pending, boot the riscv core once\n");
		return CMD_RET_SUCCESS;
	}

#if defined(__riscv) || defined(CONFIG_SANDBOX)
	/* riscv: both steps, once; the run is final either way */
	env_set("nb_done", "1");
	ok = !nb_fuse_identity(argv[1]);
	if (ok)
		ok = !nb_fuse_key();
	if (ret_core && !strcmp(ret_core, "arm")) {
		puts("nixbadge_fuse: switching back to the arm core\n");
		strapsel_latch(1);
		env_set("nb_reset", "1");
	}
	return ok ? CMD_RET_SUCCESS : CMD_RET_FAILURE;
#else
	return CMD_RET_FAILURE;	/* not reached: NB_FUSE_RISCV() is 0 */
#endif
}

U_BOOT_CMD(nixbadge_fuse, 2, 0, do_nixbadge_fuse,
	   "make sure the board identity and device key eFuses are written",
	   "SG1-NNNN\n"
	   "    - write DEVICE_ID (the serial) and USER (the board record) if they\n"
	   "      read zero, and on riscv burn and read-lock DEVICE_EK if blank; an\n"
	   "      arm run hops to riscv when the switch is on Auto. Leaves $nb_done\n"
	   "      and $nb_reset for nixbadge_fuseonce.");
