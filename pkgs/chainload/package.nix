# The malicious polyglot chainload fip; write this to the SD as `fip.bin`. On either
# strap-selected core the BootROM loads the oversized BL2 (the merged overflow blob,
# 0x3E400), overruns its stack, and the hijack lands each core in its own in-place
# chainloader stub (via the shared polyglot word), which reopens the SD, loads
# 0:sophg.1{aa,rv,} (the real FSBL), and launches it.
#
# Structurally this is the real polyglot fip (fip-polyglot.nix): same CHIP_CONF, real
# MONITOR (arm BL31), LOADER_2ND (arm u-boot), BLCP_2ND (riscv OpenSBI) and LOADER_2ND_B
# (riscv u-boot) packed with the symmetric fiptool; only the BL2 slot is swapped for the
# overflow blob. So the chainloaded FSBL reads the genuine MONITOR/LOADER_2ND back from
# 0:fip.bin and boots to NixOS. SCS=0, so this is a PoC.
#
# `variant` selects the overflow BL2:
#   "polyglot" (default): both cores from one fip (the merged/dual-core blob).
#   "c906" / "a53"      : the per-core overflow blob with the same 4-slot polyglot payload,
#                         validating the polyglot second stage on that one core without the
#                         dual-core island merge.
{
  callPackage,
  fetchFromGitHub,
  python3,
  runCommand,
  writeTextFile,
  variant ? "polyglot",
  dtb ? null,
}:
let
  fsblSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };
  fsblSrcPatched = runCommand "fsbl-src-fiptool-symmetric" { } ''
    cp -r ${fsblSrc} $out
    chmod -R +w $out
    patch -d $out -p1 < ${../fip-polyglot/fiptool-loader-2nd-b-symmetric.patch}
  '';
  armFsbl = callPackage ../fsbl/package.nix { core = "arm"; }; # shared chip_conf.bin
  armMon = callPackage ../bl31-blob/package.nix { };
  riscvMon = callPackage ../opensbi/package.nix { inherit dtb; };
  armUboot = callPackage ../uboot-arm/package.nix { };
  riscvUboot = callPackage ../uboot-riscv/package.nix { };
  overflowBl2 = callPackage ../overflow-bl2/package.nix { inherit variant; };

  # Sanity: the packed fip must be a real CVBL01 fip whose BL2 is the 0x3E400
  # overflow blob and which carries the polyglot word + a real MONITOR/LOADER.
  checkFip = writeTextFile {
    name = "check-chainload-fip.py";
    executable = true;
    text = ''
      #!${python3.interpreter}
      import sys, struct
      d = open(sys.argv[1], "rb").read()
      assert d[:6] == b"CVBL01"
      assert struct.unpack_from("<I", d, 0xD8)[0] == 0x3E400, "BL2 must be the overflow blob"
      assert b"\x6f\x00\x00\x14" in d, "polyglot word missing"
      assert len(d) > 0x40000, f"fip too small: {len(d):#x} -- MONITOR/LOADER_2ND not packed?"
      print(f"chainload fip ok: {len(d):#x} bytes (carries real MONITOR + both LOADER_2ND)")
    '';
  };
in
runCommand "sg2000-maskrom-chainload-fip-poly-${variant}.bin" { nativeBuildInputs = [ python3 ]; }
  ''
    python3 ${fsblSrcPatched}/plat/cv181x/fiptool.py -v genfip "$out" \
      --MONITOR_RUNADDR=0x80000000 --BLCP_2ND_RUNADDR=0x80000000 --CHIP_CONF=${armFsbl}/chip_conf.bin \
      --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
      --NAND_INFO=00000000 --BL2=${overflowBl2} --BLCP_IMG_RUNADDR=0x05200200 --BLCP_PARAM_LOADADDR=0 \
      --BLCP=${fsblSrc}/test/empty.bin --BLCP_2ND=${riscvMon} \
      --MONITOR=${armMon} --LOADER_2ND=${armUboot}/u-boot-raw.bin \
      --LOADER_2ND_B=${riscvUboot}/u-boot-raw.bin --compress=lzma
    ${checkFip} "$out"
  ''
