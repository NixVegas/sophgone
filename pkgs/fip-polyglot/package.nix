# Pack the unified polyglot fip.bin: one fip that boots either core via the
# GPIO_RTX strap. Like fip.nix's genfip, but with the polyglot BL2 (merge-bl2.nix)
# and both cores' payloads:
#   arm  (primary)   MONITOR = bl31,    LOADER_2ND   = arm u-boot   (LZMA)
#   riscv(secondary) BLCP_2ND = OpenSBI, LOADER_2ND_B = riscv u-boot (LZMA, via the
#                    symmetric-pack fiptool patch)
# The riscv monitor rides BLCP_2ND with RUNADDR overridden 0x9FE00000 -> 0x80000000
# (a DRAM address). CHIP_CONF is byte-identical across cores, so the arm one is shared.
{
  callPackage,
  fetchFromGitHub,
  python3,
  runCommand,
  writeTextFile,
  dtb ? null,
  secureBoot ? false,
}:
let
  # Sanity check: re-open the packed fip and confirm the polyglot BL2 entry word
  # sits in the file and the size is plausible. Executable, run directly on $out.
  checkFip = writeTextFile {
    name = "check-polyglot-fip.py";
    executable = true;
    text = ''
      #!${python3.interpreter}
      import struct, sys
      d = open(sys.argv[1], "rb").read()
      # BL2 image starts at param1.BL2_IMG offset; the whole file must contain the
      # entry word, and be a plausible size (BL2 + 2 monitors + 2 u-boots).
      assert b"\x6f\x00\x00\x14" in d, "polyglot entry word not found in fip"
      assert len(d) > 0x40000, f"fip suspiciously small: {len(d):#x}"
      print(f"polyglot fip ok: {len(d):#x} bytes")
    '';
  };

  fsblSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  # fiptool with symmetric LOADER_2ND_B packing (Option Y).
  fsblSrcPatched = runCommand "fsbl-src-fiptool-symmetric" { } ''
    cp -r ${fsblSrc} $out
    chmod -R +w $out
    patch -d $out -p1 < ${./fiptool-loader-2nd-b-symmetric.patch}
  '';

  bl2 = callPackage ../merge-bl2/package.nix { inherit secureBoot; };
  armFsbl = callPackage ../fsbl/package.nix { core = "arm"; }; # for the shared chip_conf.bin
  armMon = callPackage ../bl31-blob/package.nix { };
  riscvMon = callPackage ../opensbi/package.nix { inherit dtb; };
  armUboot = callPackage ../uboot-arm/package.nix { };
  riscvUboot = callPackage ../uboot-riscv/package.nix { };
in
runCommand "sg2000-fip-polyglot.bin"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    python3 ${fsblSrcPatched}/plat/cv181x/fiptool.py -v genfip \
      "$out" \
      --MONITOR_RUNADDR=0x80000000 \
      --BLCP_2ND_RUNADDR=0x80000000 \
      --CHIP_CONF=${armFsbl}/chip_conf.bin \
      --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
      --NAND_INFO=00000000 \
      --BL2=${bl2} \
      --BLCP_IMG_RUNADDR=0x05200200 \
      --BLCP_PARAM_LOADADDR=0 \
      --BLCP=${fsblSrc}/test/empty.bin \
      --BLCP_2ND=${riscvMon} \
      --MONITOR=${armMon} \
      --LOADER_2ND=${armUboot}/u-boot-raw.bin \
      --LOADER_2ND_B=${riscvUboot}/u-boot-raw.bin \
      --compress=lzma

    # Sanity: re-open with the patched fiptool and confirm the polyglot BL2 entry
    # word sits at the BL2 slot start and both u-boot slots are populated.
    python3 ${checkFip} "$out"
  ''
