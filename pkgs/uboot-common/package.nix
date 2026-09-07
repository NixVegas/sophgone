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

  # Two custom u-boot commands, cat'd onto cmd/efuse.c (obj-y, already includes
  # <mmio.h>). strapsel = core-select latch; btnsel = USER-button profile;
  # sdready = wait out the SD init race before anything boots off it.
  strapselCmd = ./cvi-strapsel-cmd.c;
  btnselCmd = ./cvi-btnsel-cmd.c;
  sdreadyCmd = ./cvi-sdready-cmd.c;

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

  # Boot-env override (CONFIG_BOOTCOMMAND / CONFIG_EXTRA_ENV_SETTINGS) for
  # include/configs/cv181x-asic.h, one patch per core. The cores differ only in
  # the /arm vs /riscv extlinux path. See pkgs/uboot-bootenv-<core>.patch.
  bootenvPatch =
    core:
    {
      arm = ./uboot-bootenv-arm.patch;
      riscv = ./uboot-bootenv-riscv.patch;
    }
    .${core};

  # Vendor-tree patches applied by both cores via the derivation `patches` attr:
  # hang() -> reset_cpu() (an intermittent early bind failure retries instead of
  # parking) and the autoboot STAT-LED blink.
  commonPatches = [
    hangResetPatch
    statledAutobootPatch
  ];

  # postPatch snippet for the file appends that aren't patches: both custom
  # commands onto cmd/efuse.c (btnsel's per-core desktop conf #defined just before
  # it), and the STAT-LED helpers onto board.c (driven by statledAutobootPatch,
  # applied via `patches`). See pkgs/cvi-{strapsel,btnsel,sdready,statled-early}.c.
  wireCommands = core: ''
    cat ${strapselCmd} >> cmd/efuse.c
    printf '#define BTNSEL_DESKTOP_CONF "/${core}/extlinux/extlinux-desktop.conf"\n' >> cmd/efuse.c
    cat ${btnselCmd} >> cmd/efuse.c
    cat ${sdreadyCmd} >> cmd/efuse.c
    cat ${statledEarly} >> board/cvitek/cv181x/board.c
  '';
}
