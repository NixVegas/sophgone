/* `devek burn`: generate a device key on-die from the TRNG, condition it with
 * SHA-256, burn efuse DEVICE_EK (0xE8), verify the read-back, then read-lock it.
 * Appended after cvi-trng-cmd.c (uses cvi_trng_read4); needs CONFIG_SHA256. */
#include <u-boot/sha256.h>
static int do_devek(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    uint8_t raw[128], dig[SHA256_SUM_LEN], back[16];
    uint32_t w[4];
    int i, ret = CMD_RET_FAILURE;

    if (argc < 2 || strcmp(argv[1], "burn") != 0) {
        printf("devek: PERMANENTLY burns DEVICE_EK. run 'devek burn' to confirm.\n");
        return CMD_RET_USAGE;
    }
    /* refuse if DEVICE_EK is already provisioned (any non-zero byte at 0xE8) */
    if (CVI_EFUSE_Read(CVI_EFUSE_AREA_DEVICE_EK, back, sizeof(back)) < 0) {
        printf("devek: DEVICE_EK read failed\n");
        return CMD_RET_FAILURE;
    }
    for (i = 0; i < (int)sizeof(back); i++)
        if (back[i]) {
            printf("devek: DEVICE_EK already set; refusing\n");
            return CMD_RET_FAILURE;
        }
    /* 1024 bits of raw TRNG (8 generates) -> SHA-256 -> 128-bit key. Generated
     * on-die; the factory never sees it; read-locked below. */
    cvi_trng_init();
    for (i = 0; i < (int)sizeof(raw); i += 16) {
        cvi_trng_read4(w);
        memcpy(raw + i, w, 16);
    }
    sha256_csum_wd(raw, sizeof(raw), dig, 0);
    if (CVI_EFUSE_Write(CVI_EFUSE_AREA_DEVICE_EK, dig, 16) < 0) {
        printf("devek: efuse write failed\n");
        goto wipe;
    }
    /* verify read-back BEFORE the read-lock (unreadable afterwards) */
    if (CVI_EFUSE_Read(CVI_EFUSE_AREA_DEVICE_EK, back, 16) < 0 ||
        memcmp(dig, back, 16) != 0) {
        printf("devek: verify FAILED -- not locking\n");
        goto wipe;
    }
    if (CVI_EFUSE_Lock(CVI_EFUSE_LOCK_DEVICE_EK) < 0) {
        printf("devek: read-lock failed\n");
        goto wipe;
    }
    printf("devek: DEVICE_EK provisioned + read-locked (0xE8)\n");
    ret = CMD_RET_SUCCESS;
wipe:
    memset(raw, 0, sizeof(raw));
    memset(dig, 0, sizeof(dig));
    memset(w, 0, sizeof(w));
    memset(back, 0, sizeof(back));
    /* barrier: stop the compiler eliding the zeroing (dead-store elimination) */
    __asm__ __volatile__("" : : "r"(raw), "r"(dig), "r"(w), "r"(back) : "memory");
    return ret;
}
U_BOOT_CMD(devek, 2, 0, do_devek,
       "provision DEVICE_EK from on-die TRNG (SHA-256) -> burn+verify+read-lock 0xE8",
       "burn  - generate on-die, condition, burn efuse 0xE8, verify, read-lock");
