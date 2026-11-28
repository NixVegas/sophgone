/*
 * coreswap-entry-riscv.S: reset entry of the main C906 for the core transfer.
 *
 * The ARM FSBL (coreswap-transfer.inc.c) has loaded the RISC-V monitor and
 * U-Boot, copies this stub to CORESWAP_ENTRY_ADDR and releases the C906 at it.
 * The stub reports in the mailbox (hart id, the address it runs at, then
 * CORESWAP_RUN), sets the machine up as the vendor FSBL's reset entry does and
 * enters the monitor with a0 = hart id, a1 = FDT and a2 = the dynamic info ARM
 * filled in. A trap on the way leaves mcause, mepc and mtval in the mailbox,
 * then CORESWAP_TRAPPED, and parks.
 *
 * package.nix passes coreswap-memmap.h (CORESWAP_*) and the FSBL's
 * duos-arm-memmap.h (CVIMMAP_*) with -include.
 */

/* T-Head C906 machine CSRs, by number as package.nix writes the vendor's. */
#define CSR_MXSTATUS	0x7c0
#define CSR_MHCR	0x7c1
#define CSR_MCOR	0x7c2
#define CSR_MHINT	0x7c5

/* What the vendor FSBL (lib/cpu/riscv/bl1_entrypoint.S) sets at reset. */
#define MXSTATUS_INIT	0xc0638000
#define PLIC_CTRL	0x701ffffc	/* PLIC base + 0x1ffffc, set to 1 */
#define MCOR_INVALIDATE	0x30013		/* caches, BTB and BHT */
#define MHCR_ENABLE	0x7f		/* caches, BHT, BTB, RAS, write allocate */
#define MHINT_INIT	0x610c		/* data cache prefetch, AMR */
#define MSTATUS_MIE	0x8
#define MSTATUS_FS_INIT	0x2000		/* floating point on */

	.option norvc
	.option norelax
	.section .text,"ax",@progbits
	.globl _start
_start:
	csrw	mie, zero
	csrci	mstatus, MSTATUS_MIE
	csrw	mscratch, zero
	lla	t0, trapped
	csrw	mtvec, t0
	li	t0, CORESWAP_MAILBOX_ADDR
	csrr	t1, mhartid
	sd	t1, CORESWAP_MAILBOX_HARTID(t0)
	lla	t1, _start
	sd	t1, CORESWAP_MAILBOX_ENTRY(t0)
	li	t1, CORESWAP_RUN
	fence	rw, rw
	sw	t1, CORESWAP_MAILBOX_STATUS(t0)
	fence	rw, rw
	/* Match the vendor FSBL's reset-time C906 machine configuration. */
	li	t0, MXSTATUS_INIT
	csrw	CSR_MXSTATUS, t0
	li	t0, PLIC_CTRL
	li	t1, 1
	sw	t1, 0(t0)
	/* Match the C906 ROM: invalidate caches and predictors before enabling. */
	li	t0, MCOR_INVALIDATE
	csrs	CSR_MCOR, t0
	li	t0, MHCR_ENABLE
	csrs	CSR_MHCR, t0
	li	t0, MHINT_INIT
	csrs	CSR_MHINT, t0
	li	t0, MSTATUS_FS_INIT
	csrs	mstatus, t0
	csrr	a0, mhartid
	li	a1, CVIMMAP_OPENSBI_FDT_ADDR
	li	a2, CORESWAP_DYNAMIC_ADDR
	li	t0, CVIMMAP_MONITOR_ADDR
	fence	iorw, iorw
	fence.i
	jr	t0
park:
	wfi
	j	park
	.balign 4
trapped:
	li	t0, CORESWAP_MAILBOX_ADDR
	csrr	t1, mcause
	sd	t1, CORESWAP_MAILBOX_MCAUSE(t0)
	csrr	t1, mepc
	sd	t1, CORESWAP_MAILBOX_MEPC(t0)
	csrr	t1, mtval
	sd	t1, CORESWAP_MAILBOX_MTVAL(t0)
	li	t1, CORESWAP_TRAPPED
	fence	rw, rw
	sw	t1, CORESWAP_MAILBOX_STATUS(t0)
	fence	rw, rw
	j	park
