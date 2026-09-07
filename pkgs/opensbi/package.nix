# OpenSBI fw_dynamic.bin for Sophgo SG2000 / Milk-V Duo S (RISC-V MONITOR).
#
# Upstream OpenSBI PLATFORM=generic, dynamic firmware only (no payload; the FSBL
# loads U-Boot separately and passes next-stage info via the dynamic-info struct).
#
# Generic OpenSBI requires a device tree (console UART, CLINT/timer, PLIC, memory).
# The FSBL passes a1=0x80080000 but nothing places a valid DTB there in a clean
# build, so FW_FDT_PATH embeds one (OpenSBI forwards it to U-Boot, which ignores it
# via CONFIG_OF_EMBED). `dtb` is the kernel-coupled RISC-V DTB derivation (dir with
# sophgo/sg2000-milkv-duo-s.dtb), passed in by the consumer (badgeos). Standalone
# builds default dtb = null: OpenSBI still builds (no FW_FDT_PATH), enough to verify
# the build but not to boot.
#
# Source: opensbi v1.8.1 (nixpkgs pin). Toolchain: riscv64-unknown-linux-gnu.
# $out is fw_dynamic.bin directly, so it drops into fip.nix's MONITOR slot.
{
  stdenv,
  lib,
  pkgsCross,
  opensbi,
  python3,
  gnumake,
  dtb ? null,
}:
let
  # Reuse the source and version nixpkgs 26.05 already pins (v1.8.1).
  inherit (opensbi) src version;

  # riscv64-unknown-linux-gnu cross toolchain available from nixpkgs.
  crossGcc = pkgsCross.riscv64.buildPackages.gcc;
  crossPrefix = crossGcc.targetPrefix;

  # Optional embedded FDT: only when the consumer passes its DTB. OpenSBI
  # generic consumes cpu/clint/plic/uart/memory from it.
  fdtArg = lib.optionalString (dtb != null) "FW_FDT_PATH=${dtb}/sophgo/sg2000-milkv-duo-s.dtb";
in
stdenv.mkDerivation {
  pname = "opensbi-fw-dynamic";
  inherit version src;

  nativeBuildInputs = [
    crossGcc
    crossGcc.bintools
    python3
    gnumake
  ];

  # OpenSBI scripts have Python shebangs; patch them so Nix sandbox finds
  # the interpreter.
  postPatch = ''
    patchShebangs ./scripts
  '';

  buildPhase = ''
    export PATH=${crossGcc}/bin:${crossGcc.bintools.bintools}/bin:$PATH
    # SOURCE_DATE_EPOCH=1 makes OpenSBI's Makefile use a fixed epoch for
    # OPENSBI_BUILD_TIME_STAMP instead of date(1), for a reproducible build.
    export SOURCE_DATE_EPOCH=1

    make -j$NIX_BUILD_CORES \
      PLATFORM=generic \
      CROSS_COMPILE=${crossPrefix} \
      FW_DYNAMIC=y \
      FW_JUMP=n \
      FW_PAYLOAD=n \
      ${fdtArg}
  '';

  installPhase = ''
    install -D build/platform/generic/firmware/fw_dynamic.bin "$out"
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "OpenSBI fw_dynamic for RISC-V MONITOR slot (SG2000 / Milk-V Duo S)";
    license = lib.licenses.bsd2;
  };
}
