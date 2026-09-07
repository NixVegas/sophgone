# fip.bin packer for Sophgo SG2000 / Milk-V Duo S.
#
# `core` selects the boot core; only three inputs differ:
#   MONITOR:    arm = bl31-blob.nix (bl31.bin), riscv = opensbi-fw-dynamic.nix (fw_dynamic.bin)
#   BL2 + CHIP_CONF: fsbl.nix with matching core=
#   LOADER_2ND: uboot-duos-{arm,riscv}.nix (u-boot-raw.bin, S-mode)
# The TOC magic (0xAA640001 arm / 0xC906B001 riscv) follows the BL2 from fsbl.nix.
#
# Constants from fip.mk: BLCP_IMG_RUNADDR=0x05200200, BLCP_PARAM_LOADADDR=0,
# NAND_INFO=00000000, NOR_INFO=72 hex chars (36 bytes 0xFF), FIP_COMPRESS=lzma.
# Run addresses (fsbl mmap.h): MONITOR_RUNADDR=0x80000000, BLCP_2ND_RUNADDR=0x9FE00000.
# BLCP and BLCP_2ND use test/empty.bin (no BLCP/RTOS). Output: $out is fip.bin.
#
# callPackage ./package.nix { } gives the ARM fip. dumpRom=true builds a BL2 that
# prints the mask ROM over UART (see fsbl.nix); off by default.
{
  callPackage,
  fetchFromGitHub,
  python3,
  runCommand,
  core ? "arm",
  dumpRom ? false,
  dtb ? null,
}:
let
  fsblSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  # Per-core input selection. Only these three swap; everything else is shared.
  coreInputs =
    if core == "arm" then
      {
        fsbl = callPackage ../fsbl/package.nix { inherit dumpRom; };
        monitor = callPackage ../bl31-blob/package.nix { };
        uboot = callPackage ../uboot-arm/package.nix { };
      }
    else if core == "riscv" then
      {
        fsbl = callPackage ../fsbl/package.nix {
          inherit dumpRom;
          core = "riscv";
        };
        monitor = callPackage ../opensbi/package.nix { inherit dtb; };
        uboot = callPackage ../uboot-riscv/package.nix { };
      }
    else
      throw "fip: unknown core=${core}, expected arm or riscv";

  fsbl = coreInputs.fsbl;
  monitor = coreInputs.monitor;
  uboot = coreInputs.uboot;
in
runCommand "sg2000-fip-${core}.bin"
  {
    nativeBuildInputs = [ python3 ];
  }
  ''
    # fip-all recipe from fsbl/make_helpers/fip.mk (BOOT_CPU=aarch64/riscv). The
    # genfip call below mirrors those arguments.
    python3 ${fsblSrc}/plat/cv181x/fiptool.py -v genfip \
      "$out" \
      --MONITOR_RUNADDR=0x80000000 \
      --BLCP_2ND_RUNADDR=0x9FE00000 \
      --CHIP_CONF=${fsbl}/chip_conf.bin \
      --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
      --NAND_INFO=00000000 \
      --BL2=${fsbl}/bl2.bin \
      --BLCP_IMG_RUNADDR=0x05200200 \
      --BLCP_PARAM_LOADADDR=0 \
      --BLCP=${fsblSrc}/test/empty.bin \
      --BLCP_2ND=${fsblSrc}/test/empty.bin \
      --MONITOR=${monitor} \
      --LOADER_2ND=${uboot}/u-boot-raw.bin \
      --compress=lzma
  ''
