/* `efuseraw <byte_addr>` / `efusedumpraw`: physical eFuse array read
 * (EFUSE_AREAD/EFUSE_MREAD), bypassing the secure shadow at 0x020C0100, which
 * omits the secure region and is never reloaded. Each word is two physical rows
 * OR'd together. Appended to cmd/efuse.c after the driver (static helpers). */
/* TRUE physical fuse word read: OR the two physical rows, array read. */
static uint32_t cvi_efuse_phys_word(uint32_t byte_addr, enum EFUSE_READ_TYPE type)
{
    uint32_t row = byte_addr / 4;
    uint32_t v0 = cvi_efuse_read_from_phy((row << 1) | 0, type);
    uint32_t v1 = cvi_efuse_read_from_phy((row << 1) | 1, type);
    return v0 | v1;
}
static int do_efuseraw(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    uint32_t addr, a, m;

    if (argc != 2)
        return CMD_RET_USAGE;
    addr = simple_strtoul(argv[1], NULL, 0);
    if (addr % 4 != 0 || addr >= EFUSE_SIZE) {
        printf("efuseraw: addr must be 4-aligned and < 0x%x\n", EFUSE_SIZE);
        return CMD_RET_USAGE;
    }
    /* power + refresh the macro so the array read reflects current fuses */
    cvi_efuse_init();
    cvi_efuse_wait_for_ready();
    a = cvi_efuse_phys_word(addr, EFUSE_AREAD);
    m = cvi_efuse_phys_word(addr, EFUSE_MREAD);
    printf("efuseraw 0x%02x: AREAD=0x%08x MREAD=0x%08x%s\n",
           addr, a, m, (a != m) ? "  (MARGINAL: rows differ)" : "");
    return 0;
}
static int do_efusedumpraw(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[])
{
    uint32_t addr;

    cvi_efuse_init();
    cvi_efuse_wait_for_ready();
    for (addr = 0; addr < EFUSE_SIZE; addr += 4) {
        uint32_t a = cvi_efuse_phys_word(addr, EFUSE_AREAD);
        printf("  0x%02x: 0x%08x\n", addr, a);
    }
    return 0;
}
U_BOOT_CMD(efuseraw, 2, 1, do_efuseraw,
       "read TRUE physical fuse word (array+margin), bypassing the shadow",
       "<byte_addr>  - 4-aligned efuse byte address (e.g. 0xA0 SECURE_CONF, 0xF8 LOCK)");
U_BOOT_CMD(efusedumpraw, 1, 1, do_efusedumpraw,
       "dump ALL efuse words via TRUE physical array read (incl. secure area)",
       "  - print words 0x00..0xFC (physical AREAD, not the shadow)");
