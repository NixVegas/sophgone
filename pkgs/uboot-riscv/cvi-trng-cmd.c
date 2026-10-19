/* `trng`: read the CVITEK EIP-76 TRNG at 0x02070000 (SEC_BASE + 0x70000), the
 * on-die entropy source for DEVICE_EK. From cvi_alios cvi/src/trng.c. riscv only:
 * the secure subsystem is direct MMIO here. Appended to cmd/efuse.c. */
#define CVI_TRNG_BASE 0x02070000UL
static void cvi_trng_init(void)
{
    static int inited;    /* seed + create-state ONCE, like cvi_alios; */
    unsigned long b = CVI_TRNG_BASE;    /* re-seeding a running DRBG hangs */
    if (inited)
        return;
    inited = 1;
    while (mmio_read_32(b + 0xc) & 0x80000000)    /* wait idle */
        ;
    mmio_write_32(b + 0x00, 0x1);            /* generate seed */
    while (!(mmio_read_32(b + 0x14) & 0x10))
        ;
    mmio_write_32(b + 0x14, 0x10);            /* ack done */
    mmio_write_32(b + 0x00, 0x3);            /* create state */
    while (!(mmio_read_32(b + 0x14) & 0x10))
        ;
    mmio_write_32(b + 0x14, 0x10);
}
static void cvi_trng_read4(uint32_t *out)        /* 4 words per generate */
{
    unsigned long b = CVI_TRNG_BASE;
    int k;
    mmio_write_32(b + 0x00, 0x6);            /* generate random */
    while (!(mmio_read_32(b + 0x14) & 0x10))
        ;
    mmio_write_32(b + 0x14, 0x10);
    for (k = 0; k < 4; k++)
        out[k] = mmio_read_32(b + 0x24 + 4 * k);
}
static int do_trng(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    uint32_t n = (argc >= 2) ? simple_strtoul(argv[1], NULL, 0) : 8;
    uint32_t got = 0, w[4];
    cvi_trng_init();
    while (got < n) {
        int k;
        cvi_trng_read4(w);
        for (k = 0; k < 4 && got < n; k++, got++)
            printf("%08x ", w[k]);
    }
    printf("\n");
    return 0;
}
U_BOOT_CMD(trng, 2, 1, do_trng,
       "read the CVITEK EIP-76 TRNG at 0x02070000 (riscv/secure)",
       "[num_words]  - print num_words 32-bit random values (default 8)");
