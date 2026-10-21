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
# Instead a minimal self-contained control DTS (duos.dts, as cv181x_cv181xasic.dts) is
# compiled in as __dtb_dt_begin: /memory at 0x80000000/512MB, A53 + GIC, uart0
# (0x04140000), cv-sd@4310000. Removing OF_PRIOR_STAGE drops prior_stage_fdt_address,
# so both cores share one cvi_board_init.c.
#
# Patches: 1) add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig (else CONFIG_SYS_TEXT_BASE
# is undeclared). 2) replace the vendor CONFIG_BOOTCOMMAND/EXTRA_ENV in cv181x-asic.h
# (hush + riscv args) with the nixbadge boot (../uboot-common/nixbadge.env); load
# addresses clear U-Boot text (0x80200000) and FSBL_UNZIP (0x81800000-0x82800000).
# 3) provide the missing arm control DTS; SD node "cvitek,cv181x-sd" matches
# sdhci-mars.c, pinmux handled in its probe.
{
  stdenv,
  lib,
  callPackage,
  pkgsCross,
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
  # secure: the verified-boot variant (signed FIT only, no extlinux, no autoboot
  # prompt; see ../uboot-common/secure-defconfig.fragment). fitKeyCert: the PEM
  # certificate of the sg1-image FIT signing key, embedded as the two key nodes.
  secure ? false,
  fitKeyCert ? null,
}:
assert secure -> fitKeyCert != null;
let
  # Core-agnostic U-Boot pieces shared with the riscv build: upstream src +
  # version, the strapsel/btnsel commands, the SYS_TEXT_BASE Kconfig and the
  # boot environment. See ../uboot-common/package.nix.
  common = callPackage ../uboot-common/package.nix { };
  mkFitKeyDtb = callPackage ../uboot-common/fit-key-dtb.nix { };
  secureFragment = ../uboot-common/secure-defconfig.fragment;
  # secure: embed the control DTB with the sg1-image key nodes instead of the one
  # dts/Makefile compiles from controlDts (same source, keys added).
  extDtbFlag = lib.optionalString secure "EXT_DTB=${
    mkFitKeyDtb { inherit controlDts fitKeyCert; }
  }/control.dtb";
  inherit (common) ubootSrc kconfigSysTextBase;
  wireCommands = common.wireCommands "arm";

  cc = pkgsCross.aarch64-multiplatform.stdenv.cc;
  crossPrefix = cc.targetPrefix;

  defconfig = ./cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig;
  boardInit = ../uboot-common/cvi_board_init.c;
  memmap = ./duos-arm-uboot-memmap.h;
  cvipart = ../uboot-common/cvipart.h;

  controlDts = ./duos.dts;
in
stdenv.mkDerivation {
  pname = "uboot-duos-arm" + lib.optionalString secure "-secure";
  version = common.version;

  src = ubootSrc;

  # Shared hang()->reset, autoboot STAT-LED blink and boot-env patches.
  patches = common.commonPatches;

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
  ''
  # secure: append the verified-boot overrides (later defconfig lines win). The
  # copy keeps the store file's read-only mode, hence the chmod.
  + lib.optionalString secure ''
    chmod u+w configs/cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig
    cat ${secureFragment} >> configs/cvitek_sg2000_milkv_duos_glibc_arm64_sd_defconfig
  ''
  + ''

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

    # Core-select latch (strapsel) + BOOT/USER-button profile-select (btnsel), both
    # appended to cmd/efuse.c with btnsel's per-core extlinux directory.
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

    # The default environment (../uboot-common/nixbadge.env) as
    # include/generated/nixbadge-env.h. Its preprocessing needs include/config.h
    # and the Kconfig symbols, so this make also runs syncconfig.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=arm \
      ${common.envMakeArgs "arm"}

    # Some defconfig symbols are silently dropped when their Kconfig dependencies are
    # unmet; print the ones this build depends on so a dropped one shows in the log.
    grep -E "CONFIG_(FIT|RSA|SHA256|CMD_SYSBOOT|CMD_BOOTI|CMD_PXE|BOOTDELAY|AUTOBOOT_KEYED|AUTOBOOT_PROMPT|CMD_SOURCE)" .config || true
    # secure: no FIT_SIGNATURE, no build (the grep above is informational).
    ${lib.optionalString secure ''
      grep -qx CONFIG_FIT_SIGNATURE=y .config || { echo "secure U-Boot: CONFIG_FIT_SIGNATURE=y missing from .config" >&2; exit 1; }
    ''}

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
      ${extDtbFlag} \
      -j$NIX_BUILD_CORES \
      all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # u-boot.bin is the raw U-Boot binary (LOADER_2ND for fip packing).
    cp u-boot.bin $out/u-boot-raw.bin
    # The embedded control DTB (with the key nodes in the secure variant), for
    # tests/uboot-fit-config.sh.
    cp dts/dt.dtb $out/u-boot.dtb
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
