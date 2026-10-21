/* `trng`: read the CVITEK EIP-76 TRNG at 0x02070000 (SEC_BASE + 0x70000), the
 * on-die entropy source for DEVICE_EK. From cvi_alios cvi/src/trng.c. Appended
 * to cmd/efuse.c on both cores, compiled on riscv only: there the secure
 * subsystem is direct MMIO. The arm U-Boot runs in the non-secure world below
 * bl31, where a secure-subsystem access bus-hangs the SoC. The sandbox builds
 * it against a fake MMIO (pkgs/uboot-sandbox). Every wait gives up after
 * 100 ms, so a TRNG that never answers fails the caller instead of hanging the
 * boot. */
#if defined(__riscv) || defined(CONFIG_SANDBOX)
#define CVI_TRNG_BASE 0x02070000UL
#define CVI_TRNG_TIMEOUT_MS 100

/* wait for (reg & mask) == want */
static int cvi_trng_wait(unsigned long reg, uint32_t mask, uint32_t want)
{
    ulong start = get_timer(0);

    while ((mmio_read_32(reg) & mask) != want)
        if (get_timer(start) > CVI_TRNG_TIMEOUT_MS)
            return -ETIMEDOUT;
    return 0;
}

static int cvi_trng_init(void)
{
    static int inited;    /* seed + create-state ONCE, like cvi_alios; */
    unsigned long b = CVI_TRNG_BASE;    /* re-seeding a running DRBG hangs */
    if (inited)
        return 0;
    if (cvi_trng_wait(b + 0xc, 0x80000000, 0))    /* wait idle */
        return -ETIMEDOUT;
    mmio_write_32(b + 0x00, 0x1);            /* generate seed */
    if (cvi_trng_wait(b + 0x14, 0x10, 0x10))
        return -ETIMEDOUT;
    mmio_write_32(b + 0x14, 0x10);            /* ack done */
    mmio_write_32(b + 0x00, 0x3);            /* create state */
    if (cvi_trng_wait(b + 0x14, 0x10, 0x10))
        return -ETIMEDOUT;
    mmio_write_32(b + 0x14, 0x10);
    inited = 1;
    return 0;
}
static int cvi_trng_read4(uint32_t *out)        /* 4 words per generate */
{
    unsigned long b = CVI_TRNG_BASE;
    int k;
    mmio_write_32(b + 0x00, 0x6);            /* generate random */
    if (cvi_trng_wait(b + 0x14, 0x10, 0x10))
        return -ETIMEDOUT;
    mmio_write_32(b + 0x14, 0x10);
    for (k = 0; k < 4; k++)
        out[k] = mmio_read_32(b + 0x24 + 4 * k);
    return 0;
}
static int do_trng(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    uint32_t n = (argc >= 2) ? simple_strtoul(argv[1], NULL, 0) : 8;
    uint32_t got = 0, w[4];
    if (cvi_trng_init()) {
        printf("trng: not responding\n");
        return CMD_RET_FAILURE;
    }
    while (got < n) {
        int k;
        if (cvi_trng_read4(w)) {
            printf("\ntrng: not responding\n");
            return CMD_RET_FAILURE;
        }
        for (k = 0; k < 4 && got < n; k++, got++)
            printf("%08x ", w[k]);
    }
    printf("\n");
    return 0;
}
U_BOOT_CMD(trng, 2, 1, do_trng,
       "read the CVITEK EIP-76 TRNG at 0x02070000 (riscv/secure)",
       "[num_words]  - print num_words 32-bit random values (default 8)");
#endif
