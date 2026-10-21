# Shared building blocks for the two Milk-V Duo S U-Boot derivations
# (uboot-duos-arm.nix and uboot-duos-riscv.nix). Both build the same
# sophgo/u-boot-2021.10 tree with the same overrides -- a clean sysboot/extlinux
# boot, the `strapsel` core-select command and the `btnsel` profile-select
# command -- and differ only in the cross toolchain, defconfig, control DTS,
# board init and the /arm vs /riscv extlinux path. Everything that does NOT
# depend on the core lives here.
{
  lib,
  fetchFromGitHub,
  writeText,
}:
rec {
  # Same upstream tree + rev for both cores.
  ubootSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "u-boot-2021.10";
    rev = "a955e4df4d034b214416e3913e68b2d90ebce714";
    hash = "sha256-n3Me9Q0knGv6rl4gdanHovkEf3pu9iVlaNJqCWe8hYU=";
  };

  version = "2021.10-a955e4d";

  # A SYS_TEXT_BASE Kconfig symbol the vendor tree lacks (the defconfig value is
  # otherwise dropped and board_f.c / efi_runtime.c get it undeclared). Appended
  # to board/cvitek/cv181x/Kconfig by each core's postPatch. Identical for both.
  kconfigSysTextBase = writeText "cv181x-kconfig-sys-text-base" ''

    config SYS_TEXT_BASE
    	hex "Text Base"
    	default 0x80200000
    	help
    	  U-Boot text/code base address in DRAM. For Milk-V Duo S the
    	  SDK places U-Boot at DRAM_BASE + 2 MB = 0x80200000, per
    	  build/boards/cv181x/sg2000_milkv_duos_glibc_arm64_sd/memmap.py.
  '';

  # Custom u-boot commands, cat'd onto cmd/efuse.c (obj-y, already includes
  # <mmio.h>). strapsel = core-select latch; btnsel = BOOT/USER-button profile;
  # sdready = wait out the SD init race before anything boots off it.
  strapselCmd = ./cvi-strapsel-cmd.c;
  btnselCmd = ./cvi-btnsel-cmd.c;
  sdreadyCmd = ./cvi-sdready-cmd.c;
  # nixbadge_halt: the secure build's end of the walk (idles; compiled only with
  # CONFIG_FIT_SIGNATURE, see the file).
  haltCmd = ./cvi-halt-cmd.c;
  # `trng` (the EIP-76 TRNG) and `devek` (DEVICE_EK from it, burned and
  # read-locked): riscv only inside, see the files. nixbadge_fuse: the serial,
  # the board record and the device key, once (see the file), preceded by the
  # USER record as NIXBADGE_BOARD_USER. devek needs trng, nixbadge_fuse both,
  # and CONFIG_SHA256 (both defconfigs).
  trngCmd = ./cvi-trng-cmd.c;
  devekCmd = ./cvi-devek-cmd.c;
  fuseCmd = ./cvi-fuse-cmd.c;

  # The 40-byte eFuse USER record every badge carries: the fabricated PCB's store
  # path /nix/store/dchav4nca8fzz7lcc9zadjxjcrvs920p-nix-badge-board-2.0-20260706-07f6efc
  # encoded by badgeos' pkgs/badge/board-id/board_id.py. Only DEVICE_ID (the
  # serial) differs between badges.
  boardUserRecord = "2d6415b2598a43bff3d18c4fd4d9764ccef49102fbb4f85b8b0e4cf956e2df879642829d207f6efc";
  boardUserHeader =
    assert lib.assertMsg (
      builtins.match "[0-9a-f]{80}" boardUserRecord != null
    ) "boardUserRecord must be 40 bytes of lowercase hex";
    writeText "nixbadge-board-user.h" ''
      #define NIXBADGE_BOARD_USER { ${
        lib.concatMapStringsSep ", " (i: "0x${builtins.substring (2 * i) 2 boardUserRecord}") (
          lib.range 0 39
        )
      } }
    '';

  # Make hang() reset the board instead of parking forever. Shared by both
  # cores: the intermittent -12 bind failure this exists for is not
  # core-specific. See pkgs/uboot-hang-reset.patch for the rationale.
  hangResetPatch = ./uboot-hang-reset.patch;

  # STAT LED, blinked during the autoboot countdown. cvi-statled-early.c is
  # appended to board.c and provides statled_begin/toggle/end;
  # uboot-autoboot-statled.patch drives them from abortboot_key_sequence's poll
  # loop, lighting the LED only while holding BOOT or pressing ENTER does
  # something.
  statledEarly = ./cvi-statled-early.c;
  statledAutobootPatch = ./uboot-autoboot-statled.patch;

  # Board hooks for where the U-Boot environment lives (SD: start of the GPT
  # partition UBOOT; eMMC: boot area 2), the env load order, and the
  # bootmedium/mmcdev/rauc_ext variables. Appended to board.c.
  envMedium = ./cvi-env-medium.c;

  # bootcmd (run nixbadge_boot), the generated-env include and the env write
  # list, for include/configs/cv181x-asic.h. Core-independent.
  bootenvPatch = ./uboot-bootenv.patch;

  # The default environment: nixbadge.env, preprocessed against the board
  # config and converted by upstream's env2string.awk into
  # include/generated/nixbadge-env.h (rules in nixbadge-env.mk). envMakeArgs
  # are the arguments that build it, appended to the board's own make
  # variables after the defconfig step; the core reaches the file only as
  # NIXBADGE_CORE.
  envFile = ./nixbadge.env;
  env2stringAwk = ./env2string.awk;
  envMk = ./nixbadge-env.mk;
  envMakeArgs =
    core:
    "-f Makefile -f ${envMk} NIXBADGE_ENV=${envFile} NIXBADGE_ENV_AWK=${env2stringAwk} NIXBADGE_CORE=${core} include/generated/nixbadge-env.h";

  # Vendor-tree patches applied by both cores via the derivation `patches` attr:
  # hang() -> reset_cpu() (an intermittent early bind failure retries instead of
  # parking), the autoboot STAT-LED blink and the boot-env patch.
  commonPatches = [
    hangResetPatch
    statledAutobootPatch
    bootenvPatch
  ];

  # postPatch snippet for the file appends that aren't patches: the custom
  # commands onto cmd/efuse.c (btnsel's per-core extlinux directory
  # #defined just before it), the STAT-LED helpers and env-medium hooks onto
  # board.c, and the CBSIZE raise in cv181x-asic.h.
  wireCommands = core: ''
    cat ${strapselCmd} >> cmd/efuse.c
    printf '#define BTNSEL_CONF_DIR "/${core}/extlinux"\n' >> cmd/efuse.c
    cat ${btnselCmd} >> cmd/efuse.c
    cat ${sdreadyCmd} >> cmd/efuse.c
    cat ${haltCmd} >> cmd/efuse.c
    cat ${trngCmd} ${devekCmd} ${boardUserHeader} ${fuseCmd} >> cmd/efuse.c
    cat ${statledEarly} >> board/cvitek/cv181x/board.c
    cat ${envMedium} >> board/cvitek/cv181x/board.c

    # Raise CONFIG_SYS_CBSIZE (and the PBSIZE/BARGSIZE derived from it) from
    # 512 to 2048: pxe_utils.c's label_boot() refuses longer bootargs with
    # "bootarg overflow", and the dm-verity APPEND line is ~800 bytes.
    substituteInPlace include/configs/cv181x-asic.h \
      --replace-fail '#define CONFIG_SYS_CBSIZE		512' '#define CONFIG_SYS_CBSIZE		2048'
  '';
}
