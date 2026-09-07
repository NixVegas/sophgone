# U-Boot for the Milk-V Duo S (Sophgo SG2000, aarch64).
# Builds sophgo/u-boot-2021.10 (sg200x-dev, commit a955e4df4d034b214416e3913e68b2d90ebce714).
# Produces $out/u-boot-raw.bin (the LOADER_2ND blob for fip packing).
#
# Board glue is authored here, not taken from the SDK build/ tree:
#   configs/cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig  (via postPatch)
#   board/cvitek/cvi_board_init.c                               (arm: no prior_stage_fdt_address)
#   include/cvi_board_memmap.h                                  (Duo S 512 MB memory map)
#   include/cvipart.h                                           (minimal SD partition defs)
#
# Uses CONFIG_OF_EMBED, not OF_PRIOR_STAGE: a clean Nix build writes no valid DTB at
# 0x80080000, so prior_stage_fdt_address would be invalid and fdtdec_setup() hangs.
# Instead a minimal self-contained control DTS (postPatch, cv181x_cv181xasic.dts) is
# compiled in as __dtb_dt_begin: /memory at 0x80000000/512MB, A53 + GIC, uart0
# (0x04140000), cv-sd@4310000. Removing OF_PRIOR_STAGE drops prior_stage_fdt_address,
# so both cores share one cvi_board_init.c.
#
# Patches: 1) add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig (else CONFIG_SYS_TEXT_BASE
# is undeclared). 2) override CONFIG_BOOTCOMMAND/EXTRA_ENV in cv181x-asic.h (vendor uses
# hush + riscv args) with a sysboot/extlinux boot; load addresses clear U-Boot text
# (0x80200000) and FSBL_UNZIP (0x81800000-0x82800000). 3) provide the missing arm control
# DTS; SD node "cvitek,cv181x-sd" matches sdhci-mars.c, pinmux handled in its probe.
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
  # Core-agnostic U-Boot pieces shared with the riscv build: upstream src +
  # version, the strapsel/btnsel commands, the SYS_TEXT_BASE Kconfig and the
  # boot-env override (specialised to this core's /arm path). See
  # uboot-duos-common.nix.
  common = callPackage ../uboot-common/package.nix { };
  inherit (common) ubootSrc kconfigSysTextBase;
  bootenvPatch = common.bootenvPatch "arm";
  wireCommands = common.wireCommands "arm";

  cc = pkgsCross.aarch64-multiplatform.stdenv.cc;
  crossPrefix = cc.targetPrefix;

  defconfig = ./cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig;
  boardInit = ../uboot-common/cvi_board_init.c;
  memmap = ./duos-arm-uboot-memmap.h;
  cvipart = ../uboot-common/cvipart.h;

  controlDts = writeText "cv181x_cv181xasic.dts" ''
    /dts-v1/;

    / {
        model = "SOPHGO SG2000 Milk-V Duo S (aarch64)";
        compatible = "milkv,duos", "sophgo,sg2000", "cvitek,cv181x";

        #address-cells = <2>;
        #size-cells = <2>;

        memory@80000000 {
            device_type = "memory";
            /* 512 MB DDR at 0x80000000; the first 2 MB is reserved for BL31 */
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

            cpu0: cpu@0 {
                device_type = "cpu";
                compatible = "arm,cortex-a53";
                reg = <0x0>;
                enable-method = "psci";
            };
        };

        psci {
            compatible = "arm,psci-0.2";
            method = "smc";
        };

        gic: interrupt-controller@1f01000 {
            compatible = "arm,gic-400", "arm,cortex-a15-gic";
            #interrupt-cells = <3>;
            interrupt-controller;
            reg = <0x00 0x01f01000 0x00 0x1000>,
                  <0x00 0x01f02000 0x00 0x2000>;
        };

        timer {
            compatible = "arm,armv8-timer";
            interrupts = <1 13 0xff01>,
                         <1 14 0xff01>,
                         <1 11 0xff01>,
                         <1 10 0xff01>;
            interrupt-parent = <&gic>;
        };

        soc {
            #address-cells = <2>;
            #size-cells = <2>;
            compatible = "simple-bus";
            ranges;

            uart0: serial@4140000 {
                compatible = "snps,dw-apb-uart";
                reg = <0x00 0x04140000 0x00 0x1000>;
                clock-frequency = <25000000>;
                reg-shift = <2>;
                reg-io-width = <4>;
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
    };
  '';
in
stdenv.mkDerivation {
  pname = "uboot-duos-arm";
  version = common.version;

  src = ubootSrc;

  # Shared hang()->reset + autoboot STAT-LED blink, plus the arm boot-env override.
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
    # Stub the SCM version so scripts/setlocalversion skips git.
    # setlocalversion reads .scmversion first and returns its contents, which
    # bypasses all git calls. An empty file adds no suffix, the same result as
    # the riscv build (no git there).
    echo -n "" > .scmversion

    # Place the authored defconfig.
    cp ${defconfig} configs/cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig

    # Place the board init. The vendor tree gitignores it; the SDK generates it.
    cp ${boardInit} board/cvitek/cvi_board_init.c

    # Place the memory map header (all CVIMMAP_ defines for the Duo S 512 MB).
    cp ${memmap} include/cvi_board_memmap.h

    # Place the partition definitions header (the SDK generates it via mkcvipart.py).
    cp ${cvipart} include/cvipart.h

    # Patch 1: add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig. The vendor Kconfig
    # lacks it, so the defconfig value is dropped and CONFIG_SYS_TEXT_BASE ends up
    # undeclared in board_f.c / efi_runtime.c.
    cat ${kconfigSysTextBase} >> board/cvitek/cv181x/Kconfig

    # Core-select latch (strapsel) + USER-button profile-select (btnsel), both
    # appended to cmd/efuse.c with btnsel's per-core desktop conf path.
    ${wireCommands}

    # Patch 3: provide the missing arm control DTS. The vendor tree has none, but
    # dts/Makefile expects cv181x_cv181xasic.dtb. This minimal self-contained DTS
    # gives U-Boot a valid control FDT (/memory, ns16550 uart, cvi_sdhci MMC, GIC at
    # GICD 0x01F01000 / GICC 0x01F02000); with OF_EMBED it links in as __dtb_dt_begin.
    # The SD node "cvitek,cv181x-sd" matches sdhci-mars.c, which does SDIO0 pad setup
    # in its probe.
    cp ${controlDts} arch/arm/dts/cv181x_cv181xasic.dts
  '';

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    export CROSS_COMPILE=${crossPrefix}
    # This vendor tree uses ARCH=arm for both arm and arm64. arm64 is a
    # subarch under arch/arm/ (CONFIG_ARM=y, CONFIG_ARM64=y via Kconfig).
    # ARCH=arm64 fails because there is no arch/arm64/ directory.
    export ARCH=arm
    export PATH=${cc}/bin:${cc.bintools.bintools}/bin:$PATH
    # SOURCE_DATE_EPOCH=1 makes U-Boot's filechk_timestamp.h use a fixed epoch
    # instead of date(1), so the U_BOOT_DATE/TIME/etc. constants are deterministic.
    export SOURCE_DATE_EPOCH=1

    # cvitek.mk and dts/Makefile use CHIP=cv181x and CVIBOARD=cv181xasic.
    # STORAGE_TYPE=sd enables -DCONFIG_SD_BOOT via cvitek.mk.
    # OF_EMBED=y: U-Boot compiles arch/arm/dts/cv181x_cv181xasic.dts and links
    # it into the binary; no runtime FDT pointer is needed.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=arm \
      -j$NIX_BUILD_CORES \
      cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig

    # GCC 15 is stricter than the GCC 12 Sophgo targeted:
    # -Wno-enum-int-mismatch (cmd_process int vs enum), -Wno-format (%d for ulong,
    # harmless on 64-bit), -Wno-error. -Os is u-boot 2021.10's default level.
    #
    # -fno-late-combine-instructions + -mno-{early,late}-ldp-fusion work around GCC
    # PR target/121957, a 15.x AArch64 ldp/stp-fusion regression: distinct stack
    # slots get an identical wrong MEM_EXPR at expand, so fusion merges two stores
    # to different addresses and corrupts a neighbouring .bss/.data global (here
    # serial_current: reads -1, serial_puts faults on ldr x1,[x0,#64], esr
    # 0x96000021). Intermittent and GCC-rev/-O-dependent; fixed only on GCC 16, not
    # backported. The three flags are pure de-optimizations, bench-proven to boot.
    #
    # -fno-strict-overflow: u-boot has latent signed-overflow patterns an optimizer
    # could fold/hoist around (same class of miscompile); the top Makefile already
    # forces -fno-strict-aliasing, this closes the sibling gap.
    #
    # Net: the arm u-boot boots on GCC 15.2/15.3 at -Os independent of the exact
    # pin. -O0 is not an option (u-boot 2021.10 only links once dead OF_LIVE refs
    # are dropped).
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=arm \
      KCFLAGS="-Wno-enum-int-mismatch -Wno-format -Wno-error -Os -fno-late-combine-instructions -mno-early-ldp-fusion -mno-late-ldp-fusion -fno-strict-overflow" \
      -j$NIX_BUILD_CORES \
      all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # u-boot.bin is the raw U-Boot binary (LOADER_2ND for fip packing).
    cp u-boot.bin $out/u-boot-raw.bin
    # Keep the u-boot ELF and map for debugging.
    cp u-boot $out/u-boot || true
    cp u-boot.map $out/u-boot.map || true

    runHook postInstall
  '';

  meta = {
    description = "Sophgo SG2000 U-Boot 2021.10 for Milk-V Duo S (aarch64, SD boot)";
    license = lib.licenses.gpl2Plus;
  };
}
