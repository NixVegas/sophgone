# Native x86_64 U-Boot "sandbox" build from the same pinned vendor tree as
# uboot-common, using the stock upstream sandbox_defconfig: no cvitek board
# glue, no cross toolchain, none of our board patches. It is not a boot target;
# it exists so tests/hush-rauc-walk.sh can run the nixbadge_* HUSH strings
# (converted from the real nixbadge.env) against a real hush parser on the
# build host, via `u-boot -c '<script>'` (os_main() -> run_command(), no
# console). Control-flow only: it proves no HUSH quoting/splitting/setexpr bug,
# not board behaviour.
#
# Hush never falls back from a bare command to an env var of the same name, so
# the board commands the walk calls are compiled-in stand-ins, driven by env
# vars the test sets:
#
#   sysboot        prints "SYSBOOT <args>". With $sb_files set, a conf not in
#                  that list prints "SYSBOOT-MISSING <file>" and fails; a
#                  listed one boots (see below).
#   load           copies $sb_dir<path> into RAM at <addr> if <path> is in
#                  $sb_files, else fails like a missing file.
#   part           `part uuid` finds partition <n> only if <n> is in $sb_parts
#                  (value "sbuuid-<n>"); `part start` answers $sb_ubs if set.
#   sdready        prints "SDREADY-CALLED" and fails.
#   btnsel         the real cvi-btnsel-cmd.c with a fake MMIO read: BOOT held
#                  when $sb_btn=held, USER held when $sb_user=held.
#   nixbadge_halt  prints "HALTED" and exits.
#   nixbadge_fuse  the real cvi-fuse-cmd.c (and the strapsel/trng/devek it
#                  runs) over a fake eFuse array, TRNG and core-select latch:
#                  blank unless $sb_fused=1 (provisioned as SG1-0003); each
#                  write prints "EFUSEW <area> <hex>", the read-lock
#                  "EFUSE-LOCK DEVICE_EK", a latch "LATCH <core>"; $sb_core
#                  picks the core, $sb_switch pins the strap, and $sb_devek,
#                  $sb_efuse, $sb_efuser, $sb_lock, $sb_trng model the failure
#                  cases (see the stubs file).
#   reset          prints "RESET" and exits.
#
# A boot never returns, so a successful sysboot, or a bootm that reaches the
# kernel hand-off, prints "BOOTED <file|bootm>" and one name=value line per
# word of $sb_show, then exits 0. source, bootm and FIT_SIGNATURE are real, so
# signed FITs are verified against the control DTB passed with `u-boot -d`
# (tests/make-fit-fixtures.sh). saveenv is the real one (no storage here).
#
# The vendor fork does not build sandbox cleanly: sandbox-vendor.patch carries
# the vendor-file fixes and sandbox-defconfig.fragment the config changes.
{
  stdenv,
  lib,
  callPackage,
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
  # Same pinned src as every other U-Boot derivation in this repo.
  common = callPackage ../uboot-common/package.nix { };
  inherit (common) ubootSrc version;
in
stdenv.mkDerivation {
  pname = "uboot-sandbox";
  inherit version;

  src = ubootSrc;

  nativeBuildInputs = [
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

  patches = [ ./sandbox-vendor.patch ];

  # The guards catch a vendor bump that invalidates the patch's assumptions.
  postPatch = ''
    # Same stub as uboot-arm/uboot-riscv: setlocalversion has no .git here.
    echo -n "" > .scmversion

    grep -Eq '^#define[[:space:]]+CONFIG_SYS_BOOTM_LEN[[:space:]]+\(64 << 20\)$' include/configs/cv181x-asic.h \
      || { echo "cv181x-asic.h no longer sets CONFIG_SYS_BOOTM_LEN to (64 << 20): update sandbox-vendor.patch" >&2; exit 1; }
    [ "$(grep -c CONFIG_SYS_BOOTM_LEN include/configs/sandbox.h)" = 1 ] \
      || { echo "sandbox.h sets CONFIG_SYS_BOOTM_LEN more than once" >&2; exit 1; }
    grep -q 'nixbadge_sb_booted("bootm")' arch/sandbox/lib/bootm.c

    # The stand-in commands described in the file header, built obj-y (see the
    # patch), followed by the real strapsel, trng, devek and nixbadge_fuse over
    # their fake eFuse, TRNG and core-select latch, and the real btnsel behind a
    # fake-MMIO prelude.
    cat ${common.boardUserHeader} ${./nixbadge-sandbox-stubs.c} ${common.strapselCmd} \
      ${common.trngCmd} ${common.devekCmd} ${common.fuseCmd} > cmd/nixbadge-sandbox-stubs.c
    cat ${./nixbadge-sandbox-btnsel.c} ${../uboot-common/cvi-btnsel-cmd.c} > cmd/nixbadge-sandbox-btnsel.c

    # No-op board_save_time_record()/TIME_RECORDS_FIELD_*, -include'd into
    # every TU via KCFLAGS in buildPhase.
    cp ${./nixbadge-sandbox-compat.h} nixbadge-sandbox-compat.h
  '';

  # Custom configure/build: this is a plain upstream `make sandbox_defconfig`,
  # not the cvitek wrapper (CHIP=/CVIBOARD=/STORAGE_TYPE=) the board builds use.
  configurePhase = ''
    runHook preConfigure
    make sandbox_defconfig
    runHook postConfigure
  '';

  # syncconfig, not olddefconfig: it also writes include/config/auto.conf, so the
  # build never generates include/autoconf.mk and sandbox.h's ad-hoc CONFIG_
  # defines (CONFIG_I2C_EDID, CONFIG_PHYSMEM) stay out of the Makefiles.
  postConfigure = ''
    sh scripts/kconfig/merge_config.sh -m .config ${./sandbox-defconfig.fragment}
    make syncconfig
  '';
  buildPhase = ''
    runHook preBuild
    make NO_SDL=1 -j$NIX_BUILD_CORES \
      KCFLAGS="-Wno-enum-int-mismatch -Wno-format -Wno-error -include $PWD/nixbadge-sandbox-compat.h" \
      u-boot
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp u-boot $out/bin/u-boot
    runHook postInstall
  '';

  meta = {
    description = "Upstream U-Boot sandbox (vendor tree, sandbox_defconfig) for offline nixbadge_ HUSH control-flow testing";
    license = lib.licenses.gpl2Plus;
  };
}
