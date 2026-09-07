# BL2 (FSBL) + chip_conf.bin for Sophgo SG2000 / Milk-V Duo S.
# Builds plat/cv181x BL2 from sophgo/fsbl rev 29edcfa0b5f999c8ea8f0759b0dd0038421e6c25.
# Does not build the full fip (no u-boot, no fiptool). Outputs:
#   $out/bl2.bin      - BL2 image (arm: TOC 0xAA640001, riscv: TOC 0xC906B001)
#   $out/chip_conf.bin - chip configuration table (pure-python, no extra deps)
#
# core = "arm"   (default): BOOT_CPU=aarch64, aarch64-embedded toolchain.
# core = "riscv": BOOT_CPU=riscv, riscv64-embedded toolchain, TOC 0xC906B001.
# callPackage ./package.nix { } uses the arm path.
{
  stdenv,
  lib,
  pkgsCross,
  fetchFromGitHub,
  writeText,
  gnumake,
  python3,
  dtc,
  libfaketime,
  core ? "arm",
  dumpRom ? false,
  slot ? "primary",
  secureBoot ? false,
}:
let
  # Per-core toolchain and build parameters.
  coreAttrs =
    if core == "arm" then
      {
        cc = pkgsCross.aarch64-embedded.stdenv.cc;
        bootCpu = "aarch64";
        arch = "aarch64";
        ldFlags = "TF_LDFLAGS_aarch64=--no-warn-rwx-segments";
        # aarch64 has native rev/rbit, so libtomcrypt's sha256 (pulled in by the
        # real dec_verify_image under secureBoot) needs no libgcc byteswap helpers.
        needsLibgcc = false;
      }
    else if core == "riscv" then
      {
        cc = pkgsCross.riscv64-embedded.stdenv.cc;
        bootCpu = "riscv";
        arch = "riscv";
        ldFlags = "TF_LDFLAGS_aarch64=--no-warn-rwx-segments";
        # riscv64 has no byteswap instruction, so libtomcrypt's sha256 (linked by
        # the real dec_verify_image under secureBoot) emits __bswapsi2/__bswapdi2.
        # The FSBL links with bare `ld` (no libgcc on the default path), so those
        # are undefined at link time -- inject libgcc.a via LDLIBS (secureBoot only).
        needsLibgcc = true;
      }
    else
      throw "fsbl: unknown core=${core}, expected arm or riscv";

  cc = coreAttrs.cc;
  crossPrefix = cc.targetPrefix;

  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  memmap = ./duos-arm-memmap.h;

  # One-shot mask-ROM dumper (dumpRom = true). The 96 KiB boot ROM (0x18000) is
  # readable only from inside BL2; afterwards the mirror at 0x40000000 reads zero
  # and the real base is firewalled. BL2 reads it as 32-bit words (word-only ROM)
  # and emits each byte as hex via console_putc, petting the DW watchdog (WDT_CRR
  # 0x0301000C) every word so the long dump cannot trip a reset. ROM base per
  # core: ARM mirror 0x40000000 (live during BL2), C906 0x04418000.
  romBase = if core == "arm" then "0x40000000" else "0x04418000";
  dumpInc = writeText "romdump.inc.c" ''
    { /* BadgeOS one-shot mask-ROM dumper */
      extern int console_putc(int c);
      static const char romhx[16] = "0123456789abcdef";
      volatile unsigned int *romw = (volatile unsigned int *)(${romBase}UL);
      unsigned int romnw = 0x18000U / 4, romi, romk;
      const char *romp, *rb = "\nROMDUMP_BEGIN\n", *re = "\nROMDUMP_END\n";
      NOTICE("ROMDUMP base=0x%x first=0x%x 0x%x 0x%x 0x%x\n",
        (unsigned int)(${romBase}UL), romw[0], romw[1], romw[2], romw[3]);
      for (romp = rb; *romp; romp++) console_putc(*romp);
      for (romi = 0; romi < romnw; romi++) {
        unsigned int w = romw[romi];
        for (romk = 0; romk < 4; romk++) {
          unsigned int b = (w >> (romk * 8)) & 0xff;
          console_putc(romhx[(b >> 4) & 0xf]);
          console_putc(romhx[b & 0xf]);
        }
        if ((romi & 0xf) == 0xf) console_putc('\n');
        mmio_write_32(0x0301000C, 0x76);
      }
      for (romp = re; *romp; romp++) console_putc(*romp);
    }
  '';
in
stdenv.mkDerivation {
  pname = "sg2000-fsbl-${core}";
  version = "29edcfa";

  inherit src;

  # The riscv64-none-elf bare-metal linker does not support -z relro / -z now
  # (Linux hardening flags). Disable them for the riscv path. The arm path is
  # unaffected, because the aarch64-none-elf linker ignores unknown -z flags.
  hardeningDisable =
    if core == "riscv" then
      [
        "relro"
        "bindnow"
      ]
    else
      [ ];

  nativeBuildInputs = [
    cc
    gnumake
    python3
    dtc
    libfaketime
  ];

  # Place the memmap header where the build expects it: mmap.h does
  # #include "cvi_board_memmap.h" and the Makefile adds -Ibuild to INCLUDES.
  # Run addresses are board/DDR-driven and identical for arm and riscv.
  postPatch = ''
    mkdir -p build
    cp ${memmap} build/cvi_board_memmap.h
  ''
  + (
    if core == "riscv" then
      ''
            # GCC 15 (riscv64-none-elf) uses the new xtheadXXX extension form, not the
            # old vendor-blob "vxthead". Replace it in cpu.mk. Add xtheadsync, which
            # th.sync.i in cpu_helper.c requires.
            substituteInPlace lib/cpu/riscv/cpu.mk \
              --replace-fail 'rv64imafdcvxthead' 'rv64imafdc_xtheadcmo_xtheadsync'

            # GCC 15 + binutils 2.46 require the "th." prefix on T-Head instructions.
            substituteInPlace lib/cpu/riscv/cpu_helper.c \
              --replace-fail '"icache.iall\n"' '"th.icache.iall\n"' \
              --replace-fail '"sync.i\n"'      '"th.sync.i\n"'

            # T-Head custom CSRs: replace named CSRs with their numeric addresses.
            # mxstatus=0x7C0  mhcr=0x7C1  mcor=0x7C2 (T-Head C906 ISA manual).
            # bl2_entrypoint.S and bl1_entrypoint.S use mxstatus/mcor/mhcr.
            # cache.c uses mhcr in inline asm strings.
            substituteInPlace lib/cpu/riscv/bl2_entrypoint.S \
              --replace-fail 'mxstatus' '0x7C0' \
              --replace-fail 'mcor'     '0x7C2' \
              --replace-fail 'mhcr'     '0x7C1'
            substituteInPlace lib/cpu/riscv/bl1_entrypoint.S \
              --replace-fail 'mxstatus' '0x7C0' \
              --replace-fail 'mcor'     '0x7C2' \
              --replace-fail 'mhcr'     '0x7C1'
            substituteInPlace lib/cpu/riscv/cache.c \
              --replace-fail 'mhcr' '0x7C1'

            # Tell the compiler what the cache-op asm touches. The T-Head ops are raw
            # .long encodings that read a0, but the vendor asm declares no inputs and no
            # memory clobber, so a modern optimiser can sink or drop the flush. That
            # breaks the CryptoDMA in plat/cv181x/security/security.c, which hands the
            # engine a descriptor by physical address and relies on flush_dcache_range();
            # a no-op flush surfaces as "E:Decryption timeout" then "E:verify monitor
            # (-14)" on riscv SCS=02 (ARM uses hand-written asm and is unaffected). Add
            # the input operand + memory clobber. See task #60.
            substituteInPlace lib/cpu/riscv/cache.c \
              --replace-fail '__asm__ __volatile__(OP); \' \
                             '__asm__ __volatile__(OP :: "r"(i) : "memory"); \'
            substituteInPlace lib/cpu/riscv/cache.c \
              --replace-fail '__asm__ __volatile__(SYNC_S)' \
                             '__asm__ __volatile__(SYNC_S ::: "memory")'

            # Invalidate the destination after the CryptoDMA finishes. The vendor
            # flushes before triggering but never invalidates `plain`, so the C906 can
            # speculatively refill those lines with ciphertext while the transfer is in
            # flight. This is the second half of the standard DMA-from-device sequence
            # (cf. Linux dma_unmap_single(DMA_FROM_DEVICE)); inv_dcache_range() is
            # declared for both arches.
            # Caveat: CACHE_OP_RANGE rounds outward to 64-byte lines and discards without
            # writeback. For LOADER_2ND (plain = image_buf + 32) the rounded range covers
            # the header and can reach past the image, but both are clean at that point
            # (DMA-loaded, CPU-read only), so discarding is harmless.
            substituteInPlace plat/cv181x/security/security.c \
              --replace-fail '	} while (status == 0);

        	return 0;
        }' '	} while (status == 0);

        	/* The engine wrote `plain` via DMA; drop any stale lines the CPU holds. */
        	inv_dcache_range((uintptr_t)plain, len);

        	return 0;
        }'
      ''
    else
      ""
  )
  + (
    if dumpRom then
      ''
        # Inject the one-shot mask-ROM dumper after the FSBL banner NOTICE.
        # An #include inside bl2_main() inserts the { ... } block as a statement,
        # before load_ddr(). The dump needs only the UART and the stack.
        cp ${dumpInc} plat/cv181x/bl2/romdump.inc.c
        sed -i '/FSBL %s:%s/a #include "romdump.inc.c"' plat/cv181x/bl2/bl2_main.c
      ''
    else
      ""
  )
  + (
    if slot == "secondary" then
      ''
        # Polyglot fip: the secondary core's FSBL loads MONITOR from BLCP_2ND
        # and u-boot from LOADER_2ND_B (primary uses the normal slots). The patch
        # redirects load_monitor + load_loader_2nd, neuters load_blcp_2nd (which would
        # treat the BLCP_2ND monitor as a C906L RTOS), and add_defines
        # POLYGLOT_SECONDARY. See docs/superpowers/plans/2026-09-01-sg2000-polyglot-fip.md.
        patch -p1 < ${./fsbl-secondary-slots.patch}
      ''
    else
      ""
  );

  buildPhase = ''
    # Fixed BUILD_STRING so the Makefile does not call git rev-parse (keeps git
    # out of nativeBuildInputs).
    export HOME=$TMPDIR
    export CROSS_COMPILE=${crossPrefix}
    export PATH=${cc}/bin:${cc.bintools.bintools}/bin:$PATH

    # Reproducible builds: SOURCE_DATE_EPOCH=1 fixes __DATE__/__TIME__;
    # BUILD_MESSAGE_TIMESTAMP overrides the $(shell date -Is) embedded in bl2.bin's
    # FSBL banner; faketime catches any remaining date(1) calls.
    #
    # OD_CLK_SEL=y (#44): CLK_OD in sys_pll_od(), gated #ifdef __riscv, so the value
    # depends on BOOT_CPU: arm A53 1000MHz (default 800), riscv C906 1050MHz
    # (default 850). Verified on the arm badge (clk_a53=1000MHz). Soak-test thermals
    # (no active cooling).
    export SOURCE_DATE_EPOCH=1

    # secureBoot=true links the real dec_verify_image() (security.c); the default
    # (0) compiles a stub that returns 0, so the FSBL never decrypts or verifies the
    # second stage (at SCS=02 it feeds still-encrypted LOADER_2ND to LZMA). =1 runs
    # cryptodma_aes_decrypt + verify_rsa, gated at runtime by the efuse (no-op at
    # SCS=0, verify at 01, decrypt+verify at 02). SECURE_ARGS stays empty when false,
    # so the default stub FSBL (the one the exploit/sophg.1 ride) builds with
    # byte-identical args. On riscv the real path pulls libtomcrypt sha256, whose
    # __bswap* are undefined on the bare `ld` link, so inject libgcc.a via LDLIBS.
    SECURE_ARGS=""
    ${lib.optionalString secureBoot ''
      SECURE_ARGS="FSBL_SECURE_BOOT_SUPPORT=1"
      ${lib.optionalString coreAttrs.needsLibgcc ''
        LIBGCC=$(${crossPrefix}gcc -march=rv64imafdc_xtheadcmo_xtheadsync -mabi=lp64d -mcmodel=medany -print-libgcc-file-name)
        echo "using libgcc: $LIBGCC"
        SECURE_ARGS="$SECURE_ARGS LDLIBS=$LIBGCC"
      ''}
    ''}

    faketime -f "1970-01-01 00:00:01" \
    make -j$NIX_BUILD_CORES \
      CHIP_ARCH=cv181x \
      BOOT_CPU=${coreAttrs.bootCpu} \
      DDR_CFG=ddr3_1866_x16 \
      SWITCH_32K_XTAL=y \
      OD_CLK_SEL=y \
      $SECURE_ARGS \
      CROSS_COMPILE=${crossPrefix} \
      BUILD_STRING=nix \
      BUILD_MESSAGE_TIMESTAMP='"1970-01-01T00:00:01+00:00"' \
      ${coreAttrs.ldFlags} \
      V=1 \
      bl2

    # chip_conf.py uses #!/usr/bin/env python3, which is not available in the
    # Nix sandbox. Invoke it directly with the python3 binary instead.
    python3 ./plat/cv181x/chip_conf.py ./build/cv181x/chip_conf.bin
  '';

  installPhase = ''
    mkdir -p $out
    cp build/cv181x/bl2.bin $out/bl2.bin
    cp build/cv181x/chip_conf.bin $out/chip_conf.bin
  '';

  meta = {
    description = "Sophgo SG2000 FSBL BL2 and chip_conf for Milk-V Duo S (${core})";
    license = lib.licenses.bsd3;
  };
}
