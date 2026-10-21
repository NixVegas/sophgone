/* `devek burn`: generate a device key on-die from the TRNG, condition it with
 * SHA-256, burn efuse DEVICE_EK (0xE8), verify the read-back, then read-lock it.
 * Appended after cvi-trng-cmd.c (uses cvi_trng_read4); needs CONFIG_SHA256.
 * riscv only, like the TRNG it needs (see cvi-trng-cmd.c); nixbadge_fuse runs
 * cvi_devek_burn() too.
 *
 * The read-lock goes through CVI_EFUSE_Lock(), which writes the LOCK word
 * (0xF8). On riscv that write is known to return -5 (-EIO) from the margin
 * check; uboot-efuse-lock-verify.patch re-reads the physical array and only
 * reports success if the lock bits are there, so CVI_DEVEK_NOT_LOCKED means the
 * physical read did not show them either. */
#if defined(__riscv) || defined(CONFIG_SANDBOX)
#include <u-boot/sha256.h>

/* DEVICE_EK write-lock (bits 7:6) and read-lock (bits 15:14) in the LOCK word;
 * the key counts as locked only with both read-lock bits */
#define CVI_DEVEK_LOCK_ADDR 0xf8
#define CVI_DEVEK_RLOCK_BITS (0x3 << 14)
#define CVI_DEVEK_LOCK_BITS ((0x3 << 6) | CVI_DEVEK_RLOCK_BITS)
#define CVI_DEVEK_ADDR 0xe8

/* why the last cvi_devek_burn() refused, for its callers' messages */
static const char *cvi_devek_why = "";

static int cvi_devek_rlocked(void)
{
    return (CVI_EFUSE_Read_Word(CVI_DEVEK_LOCK_ADDR) & CVI_DEVEK_RLOCK_BITS) ==
           CVI_DEVEK_RLOCK_BITS;
}

/* 1 if the 16-byte TRNG blocks of raw[n] are all non-zero and distinct */
static int cvi_devek_entropy_ok(const uint8_t *raw, int n)
{
    static const uint8_t zero[16];
    int i, j;

    for (i = 0; i < n; i += 16) {
        if (!memcmp(raw + i, zero, 16))
            return 0;
        for (j = i + 16; j < n; j += 16)
            if (!memcmp(raw + i, raw + j, 16))
                return 0;
    }
    return 1;
}

enum cvi_devek_result {
	CVI_DEVEK_OK,		/* burned, verified, read-locked */
	CVI_DEVEK_LOCKED,	/* nothing written: both read-lock bits already set */
	CVI_DEVEK_SET,		/* nothing written: DEVICE_EK is set but not locked */
	CVI_DEVEK_PARTIAL,	/* nothing written: a lock bit short of the full read-lock */
	CVI_DEVEK_REFUSED,	/* nothing written: DEVICE_EK unreadable or no TRNG */
	CVI_DEVEK_FAILED,	/* write or verify failed: possibly partly burned, not locked */
	CVI_DEVEK_NOT_LOCKED,	/* burned, but the read-lock is missing or partial */
};

static enum cvi_devek_result cvi_devek_burn(void)
{
    uint8_t raw[128], dig[SHA256_SUM_LEN], back[16] __aligned(4);
    uint32_t w[4];
    enum cvi_devek_result ret = CVI_DEVEK_FAILED;
    int i;

    /* refuse if DEVICE_EK is locked or already provisioned: the LOCK word and
     * DEVICE_EK as the physical array holds them, and DEVICE_EK as efuser reads
     * it (any non-zero byte at 0xE8). Any lock bit short of both read-lock
     * bits is a half-done lock: never touched again. */
    if (cvi_devek_rlocked()) {
        printf("devek: DEVICE_EK is locked; refusing\n");
        return CVI_DEVEK_LOCKED;
    }
    if (CVI_EFUSE_Read_Word(CVI_DEVEK_LOCK_ADDR) & CVI_DEVEK_LOCK_BITS) {
        printf("devek: DEVICE_EK lock is partial (0x%08x); refusing\n",
               CVI_EFUSE_Read_Word(CVI_DEVEK_LOCK_ADDR));
        return CVI_DEVEK_PARTIAL;
    }
    for (i = 0; i < 16; i += 4)
        if (CVI_EFUSE_Read_Word(CVI_DEVEK_ADDR + i)) {
            printf("devek: DEVICE_EK already set; refusing\n");
            return CVI_DEVEK_SET;
        }
    if (CVI_EFUSE_Read(CVI_EFUSE_AREA_DEVICE_EK, back, sizeof(back)) < 0) {
        printf("devek: DEVICE_EK read failed\n");
        cvi_devek_why = "DEVICE_EK read failed";
        return CVI_DEVEK_REFUSED;
    }
    for (i = 0; i < (int)sizeof(back); i++)
        if (back[i]) {
            printf("devek: DEVICE_EK already set; refusing\n");
            return CVI_DEVEK_SET;
        }
    /* 1024 bits of raw TRNG (8 generates) -> SHA-256 -> 128-bit key. Generated
     * on-die; the factory never sees it; read-locked below. */
    if (cvi_trng_init()) {
        printf("devek: TRNG not responding; nothing burned\n");
        cvi_devek_why = "TRNG not responding";
        return CVI_DEVEK_REFUSED;
    }
    for (i = 0; i < (int)sizeof(raw); i += 16) {
        if (cvi_trng_read4(w)) {
            printf("devek: TRNG not responding; nothing burned\n");
            cvi_devek_why = "TRNG not responding";
            ret = CVI_DEVEK_REFUSED;
            goto wipe;
        }
        memcpy(raw + i, w, 16);
    }
    if (!cvi_devek_entropy_ok(raw, sizeof(raw))) {
        printf("devek: TRNG output has a zero or repeated block; nothing burned\n");
        cvi_devek_why = "TRNG output failed the sanity check";
        ret = CVI_DEVEK_REFUSED;
        goto wipe;
    }
    /* a real chunk size: with CONFIG_WATCHDOG a 0 here never finishes */
    sha256_csum_wd(raw, sizeof(raw), dig, CHUNKSZ_SHA256);
    if (CVI_EFUSE_Write(CVI_EFUSE_AREA_DEVICE_EK, dig, 16) < 0) {
        printf("devek: efuse write failed\n");
        goto wipe;
    }
    /* verify BEFORE the read-lock (unreadable afterwards), on the physical
     * array, like the identity words */
    for (i = 0; i < 16; i += 4) {
        uint32_t v = CVI_EFUSE_Read_Word(CVI_DEVEK_ADDR + i);

        memcpy(back + i, &v, 4);
    }
    if (memcmp(dig, back, 16) != 0) {
        printf("devek: verify FAILED -- not locking\n");
        goto wipe;
    }
    if (CVI_EFUSE_Lock(CVI_EFUSE_LOCK_DEVICE_EK) < 0 || !cvi_devek_rlocked()) {
        printf("devek: read-lock failed (LOCK word 0x%08x)\n",
               CVI_EFUSE_Read_Word(CVI_DEVEK_LOCK_ADDR));
        ret = CVI_DEVEK_NOT_LOCKED;
        goto wipe;
    }
    printf("devek: DEVICE_EK provisioned + read-locked (0xE8)\n");
    ret = CVI_DEVEK_OK;
wipe:
    memset(raw, 0, sizeof(raw));
    memset(dig, 0, sizeof(dig));
    memset(w, 0, sizeof(w));
    memset(back, 0, sizeof(back));
    /* barrier: stop the compiler eliding the zeroing (dead-store elimination) */
    __asm__ __volatile__("" : : "r"(raw), "r"(dig), "r"(w), "r"(back) : "memory");
    return ret;
}

static int do_devek(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    if (argc < 2 || strcmp(argv[1], "burn") != 0) {
        printf("devek: PERMANENTLY burns DEVICE_EK. run 'devek burn' to confirm.\n");
        return CMD_RET_USAGE;
    }
    switch (cvi_devek_burn()) {
    case CVI_DEVEK_OK:
        return CMD_RET_SUCCESS;
    case CVI_DEVEK_NOT_LOCKED:
    case CVI_DEVEK_PARTIAL:
        printf("devek: key burned but NOT locked\n");
        return CMD_RET_FAILURE;
    default:
        return CMD_RET_FAILURE;
    }
}
U_BOOT_CMD(devek, 2, 0, do_devek,
       "provision DEVICE_EK from on-die TRNG (SHA-256) -> burn+verify+read-lock 0xE8",
       "burn  - generate on-die, condition, burn efuse 0xE8, verify, read-lock");
#endif
