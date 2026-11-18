/*
 * coreswap_transfer_request() -- hand an SD boot of the ARM FSBL over to the
 * main C906 when a request for that was left before the reset.
 *
 * A request is CORESWAP_RUN in RTC_INFO0 and its inverse in RTC_INFO1, two RTC
 * information words that keep their value over a reset. bl2_main() calls this
 * before load_rest(). The request is consumed (the words go back to their
 * defaults) before anything that can fail, so it is tried once. Then the
 * RISC-V monitor and U-Boot are loaded from the secondary core's slots of the
 * fip, the entry stub (coreswap-entry-riscv.S) is copied to
 * CORESWAP_ENTRY_ADDR, and the C906 is clocked from the MPLL and released from
 * reset at the stub with the watchdog running. When the stub reports
 * CORESWAP_RUN in the mailbox, ARM idles for good. On any failure the
 * registers are put back and the ARM boot goes on.
 *
 * RAM addresses and the mailbox layout are in coreswap-memmap.h. The RTC
 * registers carry their names from plat/cv181x/include/rtc.h. Bits used:
 *
 *   CORESWAP_RESET         bit 5 releases the main C906 (bit 6 the C906L, see
 *                          reset_c906l())
 *   CORESWAP_CTRL          bit 12 is set with the main C906's reset vector
 *                          (reset_c906l() sets bit 13 with the C906L's)
 *   CORESWAP_CLOCK_SELECT  bit 23 = clk_c906_0 from its divider
 */
#include "coreswap-memmap.h"
#include "coreswap-entry-payload.h"

#define CORESWAP_RTC_BASE		0x05026000UL
#define CORESWAP_INFO0			(CORESWAP_RTC_BASE + 0x1c)
#define CORESWAP_INFO1			(CORESWAP_RTC_BASE + 0x20)
#define CORESWAP_RTC_EN_PWR_CYC_REQ	(CORESWAP_RTC_BASE + 0xc8)
#define CORESWAP_RTC_EN_WDT_RST_REQ	(CORESWAP_RTC_BASE + 0xe0)
#define CORESWAP_INFO0_DEFAULT		0xabcd1234
#define CORESWAP_INFO1_DEFAULT		0xdeadbeef

#define CORESWAP_RTC_CTRL_BASE		0x05025000UL
#define CORESWAP_RTC_CTRL0_UNLOCKKEY	(CORESWAP_RTC_CTRL_BASE + 0x04)
#define CORESWAP_RTC_CTRL0		(CORESWAP_RTC_CTRL_BASE + 0x08)
#define CORESWAP_RTC_POR_RST_CTRL	(CORESWAP_RTC_CTRL_BASE + 0xac)
#define CORESWAP_RTC_UNLOCK_KEY		0xab18
#define CORESWAP_RTC_CTRL0_WDT_RST	0x00400040
#define CORESWAP_RTC_SETTLE_US		100

#define CORESWAP_WDT_BASE		0x03010000UL
#define CORESWAP_WDT_CONTROL		(CORESWAP_WDT_BASE + 0x00)
#define CORESWAP_WDT_TIMEOUT		(CORESWAP_WDT_BASE + 0x04)
#define CORESWAP_WDT_RESTART		(CORESWAP_WDT_BASE + 0x0c)
#define CORESWAP_WDT_TOC		(CORESWAP_WDT_BASE + 0x1c)
#define CORESWAP_WDT_CONTROL_START	0x11
#define CORESWAP_WDT_EN_BIT		0
#define CORESWAP_WDT_TIMEOUT_MAX	0xff
#define CORESWAP_WDT_RESTART_KEY	0x76
#define CORESWAP_WDT_TOC_COUNT		0x20

#define CORESWAP_RST_BASE		0x03003000UL
#define CORESWAP_RESET			(CORESWAP_RST_BASE + 0x24)
#define CORESWAP_RESET_C906_HELD	0x11	/* neither C906 core released */
#define CORESWAP_RESET_C906_BIT		5

#define CORESWAP_SEC_SYS_BASE		0x020b0000UL
#define CORESWAP_CTRL			(CORESWAP_SEC_SYS_BASE + 0x04)
#define CORESWAP_VECTOR_LO		(CORESWAP_SEC_SYS_BASE + 0x18)
#define CORESWAP_VECTOR_HI		(CORESWAP_SEC_SYS_BASE + 0x1c)
#define CORESWAP_CTRL_C906_BIT		12

#define CORESWAP_CLKGEN_BASE		0x03002000UL
#define CORESWAP_CLOCK_SELECT		(CORESWAP_CLKGEN_BASE + 0x020)
#define CORESWAP_C906_DIVIDER		(CORESWAP_CLKGEN_BASE + 0x130)
#define CORESWAP_CLOCK_SELECT_C906_BIT	23
/* [20:16] divide by 1, [9:8] source 3 = MPLL, as the vendor's RISC-V FSBL. */
#define CORESWAP_C906_DIVIDER_MPLL	0x00010309

#define CORESWAP_XGPIOB_BASE		0x03021000UL
#define CORESWAP_GPIO_STRAP		(CORESWAP_XGPIOB_BASE + 0x50)

/* U-Boot's entry from load_loader_2nd(): text base 0x80200000 plus its 32-byte header. */
#define CORESWAP_LOADER_ADDR		0x80200020UL
#define CORESWAP_LOAD_TRIES		3

/* OpenSBI's struct fw_dynamic_info (lib/cpu/riscv/bl2_helper.c has the layout). */
#define CORESWAP_DYNAMIC_MAGIC		0x4942534f	/* "OSBI" */
#define CORESWAP_DYNAMIC_VERSION	2
#define CORESWAP_DYNAMIC_NEXT_MODE_S	1

/* How long to wait for the stub's status: timer ticks, and polls at most. */
#define CORESWAP_STATUS_TICKS		100000
#define CORESWAP_STATUS_POLLS		200000

static int coreswap_arm_watchdog(void)
{
	/* Same reset routing as __system_reset, longest watchdog interval. */
	mmio_write_32(CORESWAP_RTC_EN_WDT_RST_REQ, 1);
	mmio_write_32(CORESWAP_RTC_EN_PWR_CYC_REQ, 1);
	udelay(CORESWAP_RTC_SETTLE_US);
	mmio_write_32(CORESWAP_RTC_POR_RST_CTRL, 0);
	mmio_write_32(CORESWAP_RTC_CTRL0_UNLOCKKEY, CORESWAP_RTC_UNLOCK_KEY);
	mmio_write_32(CORESWAP_RTC_CTRL0, CORESWAP_RTC_CTRL0_WDT_RST);
	mmio_write_32(CORESWAP_WDT_TIMEOUT, CORESWAP_WDT_TIMEOUT_MAX);
	mmio_write_32(CORESWAP_WDT_TOC, CORESWAP_WDT_TOC_COUNT);
	mmio_write_32(CORESWAP_WDT_RESTART, CORESWAP_WDT_RESTART_KEY);
	mmio_write_32(CORESWAP_WDT_CONTROL, CORESWAP_WDT_CONTROL_START);
	__asm__ volatile ("dsb sy" ::: "memory");
	return (mmio_read_32(CORESWAP_WDT_CONTROL) & (1U << CORESWAP_WDT_EN_BIT)) &&
	       (mmio_read_32(CORESWAP_WDT_TIMEOUT) & CORESWAP_WDT_TIMEOUT_MAX) == CORESWAP_WDT_TIMEOUT_MAX;
}

void coreswap_transfer_request(void)
{
	uint32_t request = mmio_read_32(CORESWAP_INFO0);
	uint32_t inverse = mmio_read_32(CORESWAP_INFO1);
	uint32_t saved_monitor[4], saved_loader;
	uint64_t monitor = 0, loader = 0;
	uint64_t *dynamic = (uint64_t *)CORESWAP_DYNAMIC_ADDR;
	uint32_t reset, control, lo, hi, div, mux, start, status = 0;
	unsigned int tries;

	NOTICE("CORETRANSFER request=%08x inverse=%08x\n", request, inverse);
	if (request != CORESWAP_RUN || inverse != ~request)
		return;
	/* These documented defaults were checked before the request was written. */
	mmio_write_32(CORESWAP_INFO0, CORESWAP_INFO0_DEFAULT);
	mmio_write_32(CORESWAP_INFO1, CORESWAP_INFO1_DEFAULT);
	__asm__ volatile ("dsb sy" ::: "memory");
	if (mmio_read_32(CORESWAP_INFO0) != CORESWAP_INFO0_DEFAULT ||
	    mmio_read_32(CORESWAP_INFO1) != CORESWAP_INFO1_DEFAULT) {
		NOTICE("CORETRANSFER consume failed; retaining ARM\n");
		return;
	}
	NOTICE("CORETRANSFER consumed=%08x\n", request);
	reset = mmio_read_32(CORESWAP_RESET);
	if (reset != CORESWAP_RESET_C906_HELD || p_rom_api_get_boot_src() != BOOT_SRC_SD) {
		NOTICE("CORETRANSFER rejected reset=%08x source=%x\n", reset, p_rom_api_get_boot_src());
		return;
	}
	control = mmio_read_32(CORESWAP_CTRL);
	lo = mmio_read_32(CORESWAP_VECTOR_LO);
	hi = mmio_read_32(CORESWAP_VECTOR_HI);
	memcpy(saved_monitor, &fip_param2.monitor_cksum, sizeof(saved_monitor));
	saved_loader = fip_param2.loader_2nd_loadaddr;
	sys_pll_init();
	fip_param2.monitor_loadaddr = fip_param2.blcp_2nd_loadaddr;
	fip_param2.monitor_runaddr = fip_param2.blcp_2nd_runaddr;
	fip_param2.monitor_size = fip_param2.blcp_2nd_size;
	fip_param2.monitor_cksum = fip_param2.blcp_2nd_cksum;
	fip_param2.loader_2nd_loadaddr = fip_param2.loader_2nd_b_loadaddr;
	for (tries = 0; tries < CORESWAP_LOAD_TRIES; tries++)
		if (load_monitor(tries, &monitor) == 0 && load_loader_2nd(tries, &loader) == 0)
			break;
	memcpy(&fip_param2.monitor_cksum, saved_monitor, sizeof(saved_monitor));
	fip_param2.loader_2nd_loadaddr = saved_loader;
	if (tries == CORESWAP_LOAD_TRIES || monitor != CVIMMAP_MONITOR_ADDR || loader != CORESWAP_LOADER_ADDR) {
		NOTICE("CORETRANSFER load failed monitor=%lx loader=%lx; retaining ARM\n", monitor, loader);
		return;
	}
	memcpy((void *)CORESWAP_ENTRY_ADDR, coreswap_entry_payload, sizeof(coreswap_entry_payload));
	memset((void *)CORESWAP_MAILBOX_ADDR, 0, CORESWAP_MAILBOX_SIZE);
	dynamic[0] = CORESWAP_DYNAMIC_MAGIC;
	dynamic[1] = CORESWAP_DYNAMIC_VERSION;
	dynamic[2] = loader;
	dynamic[3] = CORESWAP_DYNAMIC_NEXT_MODE_S;
	dynamic[4] = 0;
	dynamic[5] = 0;
	flush_dcache_range(CORESWAP_ENTRY_ADDR, sizeof(coreswap_entry_payload));
	flush_dcache_range(CORESWAP_MAILBOX_ADDR, CORESWAP_MAILBOX_SIZE);
	flush_dcache_range(CORESWAP_DYNAMIC_ADDR, CORESWAP_DYNAMIC_SIZE);
	div = mmio_read_32(CORESWAP_C906_DIVIDER);
	mux = mmio_read_32(CORESWAP_CLOCK_SELECT);
	/* Select the already initialized MPLL, leaving ARM's source unchanged. */
	mmio_write_32(CORESWAP_C906_DIVIDER, CORESWAP_C906_DIVIDER_MPLL);
	mmio_write_32(CORESWAP_CLOCK_SELECT, mux | (1U << CORESWAP_CLOCK_SELECT_C906_BIT));
	mmio_write_32(CORESWAP_VECTOR_LO, CORESWAP_ENTRY_ADDR);
	mmio_write_32(CORESWAP_VECTOR_HI, 0);
	mmio_write_32(CORESWAP_CTRL, control | (1U << CORESWAP_CTRL_C906_BIT));
	__asm__ volatile ("dsb sy" ::: "memory");
	if (mmio_read_32(CORESWAP_VECTOR_LO) != CORESWAP_ENTRY_ADDR || mmio_read_32(CORESWAP_VECTOR_HI) != 0 ||
	    mmio_read_32(CORESWAP_CTRL) != (control | (1U << CORESWAP_CTRL_C906_BIT))) {
		NOTICE("CORETRANSFER vector setup failed\n");
		goto restore;
	}
	NOTICE("CORETRANSFER release monitor=%lx loader=%lx strap=%08x\n",
	       monitor, loader, mmio_read_32(CORESWAP_GPIO_STRAP));
	console_flush();
	if (!coreswap_arm_watchdog()) {
		NOTICE("CORETRANSFER watchdog setup failed; retaining ARM\n");
		goto restore;
	}
	mmio_write_32(CORESWAP_RESET, reset | (1U << CORESWAP_RESET_C906_BIT));
	__asm__ volatile ("dsb sy" ::: "memory");
	start = read_count_tick();
	for (tries = 0; tries < CORESWAP_STATUS_POLLS; tries++) {
		inv_dcache_range(CORESWAP_MAILBOX_ADDR, CORESWAP_MAILBOX_SIZE);
		status = mmio_read_32(CORESWAP_MAILBOX_ADDR);
		if (status == CORESWAP_RUN) {
			__asm__ volatile ("msr daifset, #15\n\tdsb sy\n\tisb" ::: "memory");
			while (1) __asm__ volatile ("wfi");
		}
		if (status == CORESWAP_TRAPPED || (uint32_t)(read_count_tick() - start) >= CORESWAP_STATUS_TICKS)
			break;
	}
	NOTICE("CORETRANSFER no entry heartbeat status=%08x; retaining ARM\n", status);
restore:
	mmio_write_32(CORESWAP_RESET, reset);
	__asm__ volatile ("dsb sy" ::: "memory");
	mmio_write_32(CORESWAP_VECTOR_LO, lo);
	mmio_write_32(CORESWAP_VECTOR_HI, hi);
	mmio_write_32(CORESWAP_CTRL, control);
	mmio_write_32(CORESWAP_C906_DIVIDER, div);
	mmio_write_32(CORESWAP_CLOCK_SELECT, mux);
	__asm__ volatile ("dsb sy" ::: "memory");
}
