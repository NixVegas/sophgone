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
# (duos.dts, as cv181x_cv181xasic.dts) is compiled in as __dtb_dt_begin: /memory at
# 0x80000000/512MB, C906 + PLIC + CLINT, uart0 (0x04140000), cv-sd@4310000. Removing
# OF_PRIOR_STAGE drops prior_stage_fdt_address, so both cores share one
# cvi_board_init.c (SoC-pad pinmux: ethernet, WiFi/BT, JTAG, RTC power).
#
# Patches: 1) add a SYS_TEXT_BASE hex symbol to cv181x/Kconfig (else CONFIG_SYS_TEXT_BASE
# is undeclared; riscv boot0.h uses it in asm). 2) riscv-vendor.patch: append _zicsr_zifencei
# to ARCH_FLAGS in arch/riscv/Makefile (binutils >= 2.38 needs zicsr/zifencei listed explicitly for
# csrr/fence.i; the vendor tree targeted GCC 12 / binutils 2.35).
#
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
  # Core-agnostic U-Boot pieces shared with the arm build: upstream src +
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
  wireCommands = common.wireCommands "riscv";

  cc = pkgsCross.riscv64.stdenv.cc;
  crossPrefix = cc.targetPrefix;

  defconfig = ./cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig;
  boardInit = ../uboot-common/cvi_board_init.c;
  memmap = ./duos-riscv-uboot-memmap.h;
  cvipart = ../uboot-common/cvipart.h;

  # riscv-only command appended to cmd/efuse.c (see the file's header).
  efuserawCmd = ./cvi-efuseraw-cmd.c;
  # Fix: on riscv the LOCK-word (0xF8) write returns -5 (-EIO). The margin-read
  # verify in cvi_efuse_write_word false-negatives on that protected row even
  # when the fuse blew, and the secure shadow efuser reads is unreliable too;
  # the patch re-verifies against a true physical array read (EFUSE_AREAD). It
  # edits the existing CVI_EFUSE_Lock, so it applies after the efuse.c appends.
  lockFixPatch = ../uboot-common/uboot-efuse-lock-verify.patch;
  controlDts = ./duos.dts;
in
stdenv.mkDerivation {
  pname = "uboot-duos-riscv" + lib.optionalString secure "-secure";
  version = common.version;

  src = ubootSrc;

  # Shared hang()->reset, autoboot STAT-LED blink and boot-env patches, plus
  # the -march fix (riscv-vendor.patch). The efuse lock-verify
  # fix stays in postPatch: it must run after the efuse-command appends.
  patches = common.commonPatches ++ [ ./riscv-vendor.patch ];

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
  ''
  # secure: append the verified-boot overrides (later defconfig lines win). The
  # copy keeps the store file's read-only mode, hence the chmod.
  + lib.optionalString secure ''
    chmod u+w configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig
    cat ${secureFragment} >> configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig
  ''
  + ''

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

    # Core-select latch (strapsel) + BOOT/USER-button profile-select (btnsel), both
    # appended to cmd/efuse.c with btnsel's per-core extlinux directory.
    ${wireCommands}

    # `efuseraw`/`efusedumpraw`: true physical fuse read (bypasses the secure shadow).
    # Uses cvi_efuse_read_from_phy (static, earlier in the TU), so append after the
    # driver.
    cat ${efuserawCmd} >> cmd/efuse.c

    # LOCK-word verify fix (see lockFixPatch above); edits CVI_EFUSE_Lock, so it runs
    # after the appends.
    patch -p1 < ${lockFixPatch}

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

    # The default environment (../uboot-common/nixbadge.env) as
    # include/generated/nixbadge-env.h. Its preprocessing needs include/config.h
    # and the Kconfig symbols, so this make also runs syncconfig.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=riscv \
      ${common.envMakeArgs "riscv"}

    # Some defconfig symbols are silently dropped when their Kconfig dependencies are
    # unmet; print the ones this build depends on so a dropped one shows in the log.
    grep -E "CONFIG_(FIT|RSA|SHA256|CMD_SYSBOOT|CMD_BOOTI|CMD_PXE|BOOTDELAY|AUTOBOOT_KEYED|AUTOBOOT_PROMPT|CMD_SOURCE)" .config || true
    # secure: no FIT_SIGNATURE, no build (the grep above is informational).
    ${lib.optionalString secure ''
      grep -qx CONFIG_FIT_SIGNATURE=y .config || { echo "secure U-Boot: CONFIG_FIT_SIGNATURE=y missing from .config" >&2; exit 1; }
    ''}

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
      ${extDtbFlag} \
      -j$NIX_BUILD_CORES \
      all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    # u-boot.bin is the raw U-Boot binary (LOADER_2ND for riscv fip packing).
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
    description = "Sophgo SG2000 U-Boot 2021.10 for Milk-V Duo S (riscv64, S-mode, SD boot)";
    license = lib.licenses.gpl2Plus;
  };
}
