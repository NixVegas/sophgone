/*
 * RAM used by the core transfer (coreTransfer = true): what the ARM FSBL
 * (coreswap-transfer.inc.c) and the stub it starts the main C906 at
 * (coreswap-entry-riscv.S) share, in DRAM above the FSBL decompression buffer.
 * The mailbox is left for whatever boots on the C906 to read back.
 *
 * No UL suffixes: the stub's link command reads CORESWAP_ENTRY_ADDR as well.
 */

#ifndef __CORESWAP_MEMMAP_H__
#define __CORESWAP_MEMMAP_H__

/* Mailbox: zeroed by ARM, then written by the entry stub */
#define CORESWAP_MAILBOX_ADDR       0x84000000
#define CORESWAP_MAILBOX_SIZE       0x40

/* Mailbox words, 64-bit except the status */
#define CORESWAP_MAILBOX_STATUS     0x00  /* 32-bit, CORESWAP_RUN or CORESWAP_TRAPPED */
#define CORESWAP_MAILBOX_HARTID     0x08
#define CORESWAP_MAILBOX_ENTRY      0x10  /* address the stub runs at */
#define CORESWAP_MAILBOX_MCAUSE     0x18  /* this and the next two only after a trap */
#define CORESWAP_MAILBOX_MEPC       0x20
#define CORESWAP_MAILBOX_MTVAL      0x28

/* Mailbox status. CORESWAP_RUN is also the request the FSBL looks for. */
#define CORESWAP_RUN                0x43535731  /* "CSW1" */
#define CORESWAP_TRAPPED            0x43534531  /* "CSE1" */

/* Entry stub (under 1 KiB, see package.nix), the main C906's reset vector */
#define CORESWAP_ENTRY_ADDR         0x84001000

/* struct fw_dynamic_info passed to OpenSBI in a2 */
#define CORESWAP_DYNAMIC_ADDR       0x84002000
#define CORESWAP_DYNAMIC_SIZE       0x30

#endif /* __CORESWAP_MEMMAP_H__ */
