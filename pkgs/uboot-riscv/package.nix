# U-Boot for the Milk-V Duo S (Sophgo SG2000, riscv64 S-mode).
# Builds sophgo/u-boot-2021.10 (sg200x-dev, commit a955e4df4d034b214416e3913e68b2d90ebce714).
# Produces $out/u-boot-raw.bin (the LOADER_2ND blob for riscv fip packing).
#
# Board glue is authored here, not taken from the SDK build/ tree:
#   configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig  (via postPatch)
#   board/cvitek/cvi_board_init.c                                (riscv: no prior_stage_fdt_address)
#   include/cvi_board_memmap.h                                   (Duo S 512 MB memory map)
#   include/cvipart.h                                            (minimal SD partition defs)
#
# Uses CONFIG_OF_EMBED, not OF_PRIOR_STAGE: a clean Nix build writes no valid DTB at
# 0x80080000, so prior_stage_fdt_address would be invalid and dram_init()'s
# fdtdec_setup_mem_size_base() hangs. Instead a minimal self-contained control DTS
# (postPatch, cv181x_cv181xasic.dts) is compiled in as __dtb_dt_begin: /memory at
# 0x80000000/512MB, C906 + PLIC + CLINT, uart0 (0x04140000), cv-sd@4310000. Removing
# OF_PRIOR_STAGE drops prior_stage_fdt_address, so both cores share one
# cvi_board_init.c (SoC-pad pinmux: ethernet, WiFi/BT, JTAG, RTC power).
#
# Patches: 1) add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig (else CONFIG_SYS_TEXT_BASE
# is undeclared; riscv boot0.h uses it in asm). 2) append _zicsr_zifencei to ARCH_FLAGS in
# arch/riscv/Makefile (binutils >= 2.38 needs zicsr/zifencei listed explicitly for
# csrr/fence.i; the vendor tree targeted GCC 12 / binutils 2.35).
#
{
  stdenv,
  lib,
  callPackage,
  pkgsCross,
  writeText,
  gnumake,
  bison,
  flex,
  bc,
  dtc,
  openssl,
  python3,
  swig,
  ncurses,
  perl,
}:
let
  # Core-agnostic U-Boot pieces shared with the arm build: upstream src +
  # version, the strapsel/btnsel commands, the SYS_TEXT_BASE Kconfig and the
  # boot-env override (specialised to this core's /riscv path). See
  # uboot-duos-common.nix.
  common = callPackage ../uboot-common/package.nix { };
  inherit (common) ubootSrc kconfigSysTextBase;
  bootenvPatch = common.bootenvPatch "riscv";
  wireCommands = common.wireCommands "riscv";

  cc = pkgsCross.riscv64.stdenv.cc;
  crossPrefix = cc.targetPrefix;

  defconfig = ./cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig;
  boardInit = ../uboot-common/cvi_board_init.c;
  memmap = ./duos-riscv-uboot-memmap.h;
  cvipart = ../uboot-common/cvipart.h;

  # A `trng` U-Boot command: bring up + read the CVITEK EIP-76 TRNG at 0x02070000
  # (SEC_BASE + 0x70000), ported from cvi_alios_open cvi/src/trng.c. This is the
  # on-die entropy source for device-key (DEVICE_EK) provisioning. riscv only:
  # the secure subsystem is direct-MMIO here; ARM would go through OP-TEE.
  # Appended to cmd/efuse.c (already includes <mmio.h> + built obj-y).
  trngCmd = writeText "cvi-trng-cmd.c" ''

    /* ---- CVITEK EIP-76 TRNG (0x02070000), from cvi_alios cvi/src/trng.c ---- */
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
  '';

  # `devek burn`: generate a device-unique key on-die from the TRNG, condition it
  # with SHA-256, burn efuse DEVICE_EK (0xE8), verify the read-back, then set the
  # write+read lock: a factory-oblivious HUK the crypto engine reaches via the
  # secure-key path (SECURE-BOOT-FUSES.md sect 9). riscv only (secure efuse is
  # direct-MMIO here). Append after trngCmd (needs cvi_trng_read4); needs CONFIG_SHA256=y.
  devekCmd = writeText "cvi-devek-cmd.c" ''
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
  '';

  # `efuseraw` / `efusedumpraw`: true physical fuse read, bypassing every shadow.
  #
  # On riscv the whole read side of cmd/efuse.c goes through the secure efuse shadow
  # at SEC_EFUSE_SHADOW_REG (0x020C0100), which does not reflect the secure region and
  # is never reloaded, so `efuser SECUREBOOT` can report DISABLED while the fuse is
  # physically 0x024000cc and the ROM enforces SCS=3/3. The trustworthy path is the
  # eFuse macro's physical array read (cvi_efuse_read_from_phy + EFUSE_AREAD/EFUSE_MREAD
  # at EFUSE_BASE 0x03050000, the same sense path the write-verify uses; AREAD is the
  # normal read, MREAD the tighter margin read). Each 4-byte word is two physical rows
  # (word<<1 | {0,1}); the true word is row0 | row1.
  #
  # `efuseraw <byte_addr>` reads one 4-aligned word (0..0xFC); `efusedumpraw` dumps all
  # 64. e.g. 0xA0 SECURE_CONF (expect 0x024000cc), 0xF8 LOCK (0x3030 LOADER_EK w+r,
  # 0xC0C0 if DEVICE_EK too). Appended to cmd/efuse.c (obj-y).

  efuserawCmd = writeText "cvi-efuseraw-cmd.c" ''
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
  '';
  # Fix: on riscv the LOCK-word (0xF8) write returns -5 (-EIO). The margin-read
  # verify in cvi_efuse_write_word false-negatives on that protected row even
  # when the fuse blew, and the secure shadow efuser reads is unreliable too;
  # the patch re-verifies against a true physical array read (EFUSE_AREAD). It
  # edits the existing CVI_EFUSE_Lock, so it applies after the efuse.c appends.
  lockFixPatch = ../uboot-common/uboot-efuse-lock-verify.patch;
  controlDts = writeText "cv181x_cv181xasic.dts" ''
    /dts-v1/;

    / {
        model = "SOPHGO SG2000 Milk-V Duo S (riscv64)";
        compatible = "milkv,duos", "sophgo,sg2000", "cvitek,cv181x";

        #address-cells = <2>;
        #size-cells = <2>;

        memory@80000000 {
            device_type = "memory";
            /* 512 MB DDR at 0x80000000; the first 2 MB is reserved for OpenSBI */
            reg = <0x00 0x80000000 0x00 0x20000000>;
        };

        chosen {
            stdout-path = "serial0:115200n8";
        };

        aliases {
            serial0 = &uart0;
            mmc0    = &sd;
        };

        cpus {
            #address-cells = <1>;
            #size-cells = <0>;
            timebase-frequency = <25000000>;

            cpu-map {
                cluster0 {
                    core0 {
                        cpu = <&cpu0>;
                    };
                };
            };

            cpu0: cpu@0 {
                device_type = "cpu";
                reg = <0>;
                status = "okay";
                compatible = "riscv";
                riscv,isa = "rv64imafdc";
                mmu-type = "riscv,sv39";
                clock-frequency = <25000000>;

                cpu0_intc: interrupt-controller {
                    #interrupt-cells = <1>;
                    interrupt-controller;
                    compatible = "riscv,cpu-intc";
                };
            };
        };

        soc {
            #address-cells = <2>;
            #size-cells = <2>;
            compatible = "simple-bus";
            ranges;

            plic0: interrupt-controller@70000000 {
                riscv,ndev = <101>;
                riscv,max-priority = <7>;
                reg-names = "control";
                reg = <0x00 0x70000000 0x00 0x4000000>;
                interrupts-extended = <&cpu0_intc 0xffffffff &cpu0_intc 9>;
                interrupt-controller;
                compatible = "riscv,plic0";
                #interrupt-cells = <2>;
                #address-cells = <0>;
            };

            clint@74000000 {
                interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>;
                reg = <0x00 0x74000000 0x00 0x10000>;
                compatible = "riscv,clint0";
                clint,has-no-64bit-mmio;
            };
        };

        uart0: serial@4140000 {
            compatible = "snps,dw-apb-uart";
            reg = <0x00 0x04140000 0x00 0x1000>;
            clock-frequency = <25000000>;
            reg-shift = <2>;
            reg-io-width = <4>;
            interrupts = <44 4>;
            interrupt-parent = <&plic0>;
            status = "okay";
        };

        sd: cv-sd@4310000 {
            compatible = "cvitek,cv181x-sd";
            reg = <0x00 0x04310000 0x00 0x1000>;
            reg-names = "core_mem";
            bus-width = <4>;
            cap-sd-highspeed;
            cap-mmc-highspeed;
            sd-uhs-sdr12;
            sd-uhs-sdr25;
            sd-uhs-sdr50;
            sd-uhs-sdr104;
            no-sdio;
            no-mmc;
            src-frequency = <375000000>;
            min-frequency = <400000>;
            max-frequency = <200000000>;
            64_addressing;
            reset_tx_rx_phy;
            reset-names = "sdhci";
            pll_index = <6>;
            pll_reg = <0x3002070>;
            status = "okay";
        };
    };
  '';
in
stdenv.mkDerivation {
  pname = "uboot-duos-riscv";
  version = common.version;

  src = ubootSrc;

  # Shared hang()->reset + autoboot STAT-LED blink, plus the riscv boot-env
  # override. The efuse lock-verify fix stays in postPatch: it must run after the
  # efuse-command appends it edits alongside.
  patches = common.commonPatches ++ [ bootenvPatch ];

  nativeBuildInputs = [
    cc
    gnumake
    bison
    flex
    bc
    dtc
    openssl
    python3
    swig
    ncurses
    perl
  ];

  postPatch = ''
    # Place the authored defconfig.
    cp ${defconfig} configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig

    # Place the riscv board init. The vendor tree gitignores it. The riscv variant
    # omits prior_stage_fdt_address because arch/riscv/cpu/cpu.c already defines it.
    cp ${boardInit} board/cvitek/cvi_board_init.c

    # Place the memory map header (all CVIMMAP_ defines for the Duo S 512 MB).
    cp ${memmap} include/cvi_board_memmap.h

    # Place the partition definitions header (the SDK generates it via mkcvipart.py).
    cp ${cvipart} include/cvipart.h

    # Patch 1: add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig. The vendor Kconfig
    # lacks it, so the defconfig value is dropped and CONFIG_SYS_TEXT_BASE ends up
    # undeclared (riscv also uses it in .quad in boot0.h).
    cat ${kconfigSysTextBase} >> board/cvitek/cv181x/Kconfig

    # Core-select latch (strapsel) + USER-button profile-select (btnsel), both
    # appended to cmd/efuse.c with btnsel's per-core desktop conf path.
    ${wireCommands}

    # `trng` (EIP-76 TRNG bring-up), then `devek` (uses cvi_trng_read4 + CVI_EFUSE_*),
    # appended to cmd/efuse.c. Order matters: devek needs trng; devek needs
    # CONFIG_SHA256 (defconfig). See the trngCmd/devekCmd notes above.
    cat ${trngCmd} >> cmd/efuse.c
    cat ${devekCmd} >> cmd/efuse.c

    # `efuseraw`/`efusedumpraw`: true physical fuse read (bypasses the secure shadow).
    # Uses cvi_efuse_read_from_phy (static, earlier in the TU), so append after the
    # driver. See efuserawCmd note above.
    cat ${efuserawCmd} >> cmd/efuse.c

    # LOCK-word verify fix (see lockFixPatch above); edits CVI_EFUSE_Lock, so it runs
    # after the appends.
    patch -p1 < ${lockFixPatch}

    # Patch 2: append _zicsr_zifencei to ARCH_FLAGS in arch/riscv/Makefile. binutils
    # >= 2.38 needs zicsr/zifencei listed explicitly in -march for CSR (csrr/csrw) and
    # fence.i; the vendor tree targeted GCC 12 / binutils 2.35, which accepted them.
    sed -i 's/-march=$(ARCH_BASE)\$(ARCH_A)\$(ARCH_C)/-march=$(ARCH_BASE)$(ARCH_A)$(ARCH_C)_zicsr_zifencei/' arch/riscv/Makefile

    # Patch 3: provide the missing riscv control DTS. The vendor tree has none, but
    # dts/Makefile expects cv181x_cv181xasic.dtb. This minimal self-contained DTS gives
    # U-Boot a valid control FDT (/memory for dram_init's fdtdec_setup_mem_size_base,
    # ns16550 uart, cvi_sdhci MMC); with OF_EMBED it links in as __dtb_dt_begin.
    cp ${controlDts} arch/riscv/dts/cv181x_cv181xasic.dts
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    export CROSS_COMPILE=${crossPrefix}
    export ARCH=riscv
    export PATH=${cc}/bin:${cc.bintools.bintools}/bin:$PATH
    # SOURCE_DATE_EPOCH=1 makes U-Boot's filechk_timestamp.h use a fixed epoch
    # instead of date(1), so the U_BOOT_DATE/TIME/etc. constants are deterministic.
    export SOURCE_DATE_EPOCH=1

    # cvitek.mk/dts Makefile use CHIP=cv181x CVIBOARD=cv181xasic; STORAGE_TYPE=sd
    # sets -DCONFIG_SD_BOOT; OF_EMBED=y compiles and links the control DTS in.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=riscv \
      -j$NIX_BUILD_CORES \
      cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig

    # GCC 15 is stricter than the GCC 12 Sophgo targeted:
    # -Wno-enum-int-mismatch (cmd_process int vs enum), -Wno-format (%d for ulong,
    # harmless on 64-bit), -Wno-error.
    #
    # -O1 works around a separate -Os-only GCC 15 codegen bug (distinct from arm's
    # PR target/121957): under -Os, dram_init() -> fdtdec_setup() reads a corrupted
    # gd->fdt_blob, so the first FDT access after the OpenSBI handoff hits a bad
    # pointer and u-boot hangs before any console. Bench A/B is decisive: -Os fails,
    # -O2 and -O1 boot, and -Os -fno-late-combine-instructions still fails (so arm's
    # flag is not the fix here, a level change is). -O1 is bench-proven and builds
    # clean across GCC 15.2/15.3.
    #
    # -fno-strict-overflow: as in the arm build, close the signed-overflow-UB gap
    # alongside u-boot's built-in -fno-strict-aliasing.
    #
    # -O0 is not an option: u-boot 2021.10 only links once dead OF_LIVE refs are
    # dropped (of_read_u64 / of_find_property).
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=riscv \
      KCFLAGS="-Wno-enum-int-mismatch -Wno-format -Wno-error -O1 -fno-strict-overflow" \
      -j$NIX_BUILD_CORES \
      all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # u-boot.bin is the raw U-Boot binary (LOADER_2ND for riscv fip packing).
    cp u-boot.bin $out/u-boot-raw.bin
    # Keep the u-boot ELF and map for debugging.
    cp u-boot $out/u-boot || true
    cp u-boot.map $out/u-boot.map || true

    runHook postInstall
  '';

  meta = {
    description = "Sophgo SG2000 U-Boot 2021.10 for Milk-V Duo S (riscv64, S-mode, SD boot)";
    license = lib.licenses.gpl2Plus;
  };
}
