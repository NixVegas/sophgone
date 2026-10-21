# OpenSBI fw_dynamic.bin for Sophgo SG2000 / Milk-V Duo S (RISC-V MONITOR).
#
# Upstream OpenSBI PLATFORM=generic, dynamic firmware only (no payload; the FSBL
# loads U-Boot separately and passes next-stage info via the dynamic-info struct).
#
# Generic OpenSBI requires a device tree (console UART, CLINT/timer, PLIC, hart).
# The FSBL passes a1=0x80080000 but nothing places a valid DTB there, so
# FW_FDT_PATH embeds ./opensbi.dts, which carries only the nodes OpenSBI reads.
# OpenSBI copies it to a1 (0x80080000) and hands it to U-Boot, which ignores it
# (CONFIG_OF_EMBED); Linux gets its DTB from the FIT.
#
# The image, its stack and heap must end below that copy and inside the 512 KiB
# Linux reserves for M-mode (mmode_resv0). The linker rounds the RX part up to a
# power of two for PMP, so the RX part must stay under 256 KiB; a full board DTB
# pushes it over and puts the R/W part on top of the FDT copy.
#
# `dtb` is accepted for older callers and ignored.
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
  dtc,
  dtb ? null,
}:
let
  # Reuse the source and version nixpkgs 26.05 already pins (v1.8.1).
  inherit (opensbi) src version;

  # riscv64-unknown-linux-gnu cross toolchain available from nixpkgs.
  crossGcc = pkgsCross.riscv64.buildPackages.gcc;
  crossPrefix = crossGcc.targetPrefix;
in
lib.warnIf (dtb != null) "opensbi: `dtb` is ignored; OpenSBI embeds pkgs/opensbi/opensbi.dts"
  stdenv.mkDerivation
  {
    pname = "opensbi-fw-dynamic";
    inherit version src;

    nativeBuildInputs = [
      crossGcc
      crossGcc.bintools
      python3
      gnumake
      dtc
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

      dtc -I dts -O dtb -o opensbi.dtb ${./opensbi.dts}

      make -j$NIX_BUILD_CORES \
        PLATFORM=generic \
        CROSS_COMPILE=${crossPrefix} \
        FW_DYNAMIC=y \
        FW_JUMP=n \
        FW_PAYLOAD=n \
        FW_FDT_PATH=$PWD/opensbi.dtb
    '';

    # _fw_end is relative to FW_TEXT_START (0, position independent). One hart's
    # stack and heap fit in 64 KiB; all of it must end before a1 = start + 512 KiB.
    doCheck = true;
    checkPhase = ''
      fw_end=$((0x$(${crossPrefix}nm build/platform/generic/firmware/fw_dynamic.elf | sed -n 's/ [A-Za-z] _fw_end$//p')))
      rw_start=$((0x$(${crossPrefix}nm build/platform/generic/firmware/fw_dynamic.elf | sed -n 's/ [A-Za-z] _fw_rw_start$//p')))
      printf 'opensbi: fdt %d B, rw at %#x, end %#x (+64 KiB stack/heap, limit 0x80000)\n' \
        "$(stat -c %s opensbi.dtb)" "$rw_start" "$fw_end"
      if [ $((fw_end + 0x10000)) -gt $((0x80000)) ]; then
        echo "opensbi: image reaches the FDT handoff at +0x80000" >&2
        exit 1
      fi
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
