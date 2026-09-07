# The overflow BL2 (Component 2), in three variants for the bench bisect:
#   variant="a53"      : A53 hijack (fill 0x4013F000, 19-slot launch, island); validates
#                        the aa chainloader in isolation (ARM strap).
#   variant="c906"     : C906 spray (rv-stub entry 0x0C000160 across [0x3E000,0x3E400));
#                        validates the rv chainloader (RISC-V strap).
#   variant="polyglot" : unified: dual-valid fill 0x0C03F000, 18-slot A53 launch (drops
#                        0x3E308) + C906 word @0x3E308.
# Common to all: polyglot word @0x20, rv stub @0x160/0x1000, aa stub @0x1DC/0x2000.
# Offsets/base values from sophgone-map.json.
{
  pkgsCross,
  python3,
  runCommand,
  writeText,
  variant ? "polyglot",
}:
let
  map = ./sophgone-map.json;
  gensyms = ./gen-syms.py;

  aaBin =
    runCommand "sophgone-aa.bin"
      {
        nativeBuildInputs = [
          pkgsCross.aarch64-multiplatform.buildPackages.binutils
          python3
        ];
      }
      ''
        python3 -P ${gensyms} ${map} aa > sophgone-syms-aa.inc
        cp ${./sophgone-boot-banner.txt} sophgone-boot-banner.txt   # LF newlines, matching the mask ROM
        substituteInPlace sophgone-boot-banner.txt --subst-var out  # @out@ -> this stub's store path
        aarch64-unknown-linux-gnu-as -I . -march=armv8-a ${./sophgone-aa.S} -o o.o
        aarch64-unknown-linux-gnu-ld o.o -o e.elf -Ttext=0x40100000 -e _start --no-relax
        aarch64-unknown-linux-gnu-objcopy -O binary e.elf "$out"
      '';

  rvBin =
    runCommand "sophgone-rv.bin"
      {
        nativeBuildInputs = [
          pkgsCross.riscv64.buildPackages.binutils
          python3
        ];
      }
      ''
        python3 -P ${gensyms} ${map} rv > sophgone-syms-rv.inc
        cp ${./sophgone-boot-banner.txt} sophgone-boot-banner.txt   # LF newlines, matching the mask ROM
        substituteInPlace sophgone-boot-banner.txt --subst-var out  # @out@ -> this stub's store path
        riscv64-unknown-linux-gnu-as -I . -march=rv64imac -mabi=lp64 ${./sophgone-rv.S} -o o.o
        riscv64-unknown-linux-gnu-ld o.o -o e.elf -Ttext=0x0C000000 -e _start --no-relax
        riscv64-unknown-linux-gnu-objcopy -O binary e.elf "$out"
      '';

  merge = writeText "merge.py" ''
    import struct, sys, json
    aa = open(sys.argv[1], "rb").read()
    rv = open(sys.argv[2], "rb").read()
    M  = json.load(open(sys.argv[3]))
    variant = sys.argv[4]
    a, c = M["a53"], M["c906"]
    TOTAL   = a["bl2_total"]
    LAUNCH  = a["syms"]["launch_or_entry"]            # 0x4000E020
    RVENT_C = c["bl2_base"] + a["rv_stub_off"]        # 0x0C000160 (C906 view of the rv tramp)
    A53     = [off for off, _ in a["hijack"]]         # 19-slot read cluster

    if variant == "a53":
        base_fill, spray, islands = a["fill_value"], None, a["islands"]
        hij = [(o, LAUNCH) for o in A53]
    elif variant == "c906":
        base_fill, spray, islands = 0, (RVENT_C, 0x3E000, 0x3E400), c["islands"]
        hij = []
    elif variant == "polyglot":
        # 0x3C200 island collides: A53 needs its SD host base (g_sdhci_base=0x04310000) there,
        # C906's map lists the eMMC base (0x04300000). The C906 SD-boot path derefs only the SD
        # base at 0x3C230, never 0x3C200 (eMMC path, media-gated, not taken on SD boot), so drop
        # C906's eMMC island and let A53's SD base win: both cores get 0x04310000.
        c_islands = [i for i in c["islands"] if i[0] != 0x3C200]
        # Unified config F (per-slot fill split): one fip boots both cores. Each core boots in
        # isolation but wants the opposite base fill, so split it. The A53's deref/data slots
        # (need 0x0C03F000) are disjoint from the C906's critical deref slots (sd_ops 0x3E258,
        # 0x3E2C0, 0x3E238/48, fip_param 0x3E3B8, ..., which stay RVENT_C). Base RVENT_C +
        # 0x0C03F000 at the A53 deref slots + LAUNCH at the 5 collision slots (A53 launches
        # there; the C906 returns there but never reaches them, since its launch is jr a5 with
        # a5=s0+0x20 and s0 loaded fresh, not from the stack).
        A53_DEREF = [0x3E140,0x3E148,0x3E150,0x3E158,0x3E160,0x3E168,0x3E170,0x3E180,0x3E1A0,0x3E1A8,
                     0x3E1B0,0x3E1C0,0x3E1D0,0x3E1F0,0x3E1F8,0x3E200,0x3E218,0x3E220,0x3E250,0x3E270,
                     0x3E280,0x3E2A0,0x3E2C8,0x3E2D0,0x3E2F0,0x3E310,0x3E330,0x3E358,0x3E360,0x3E378,
                     0x3E380,0x3E390,0x3E3A0,0x3E3C0,0x3E3C8,0x3E3D0,0x3E3E0]
        COLLISIONS = [0x3E208, 0x3E288, 0x3E2D8, 0x3E318, 0x3E368]
        base_fill, spray, islands = RVENT_C, None, a["islands"] + c_islands
        hij = [(o, 0x0C03F000) for o in A53_DEREF] + [(o, LAUNCH) for o in COLLISIONS]
    else:
        raise SystemExit("bad variant " + variant)

    blob = bytearray(struct.pack("<Q", base_fill) * (TOTAL // 8)) if base_fill else bytearray(TOTAL)
    assert len(blob) == TOTAL

    struct.pack_into("<I", blob, a["polyglot_word_off"], 0x1400006F)   # dispatch word
    rvt, rvb = a["rv_stub_off"], a["rv_body_off"]
    blob[rvt:rvt+4] = rv[rvt:rvt+4]; blob[rvb:len(rv)] = rv[rvb:]
    aat, aab = a["aa_stub_off"], a["aa_body_off"]
    blob[aat:aat+4] = aa[aat:aat+4]; blob[aab:len(aa)] = aa[aab:]
    assert len(aa) < 0x3C000 and len(rv) < 0x3C000, "stub body overruns into the stack region"
    assert aab + (len(aa) - aab) <= rvb or rvb + (len(rv) - rvb) <= aab, "aa/rv bodies overlap"

    if spray:
        val, lo, hi = spray
        for o in range(lo, hi, 8):
            struct.pack_into("<Q", blob, o, val)
    for o, v in islands:
        struct.pack_into("<Q", blob, o, v)
    for o, v in hij:
        struct.pack_into("<Q", blob, o, v)

    assert len(blob) == TOTAL
    open(sys.argv[5], "wb").write(blob)
  '';
in
runCommand "sg2000-polyglot-overflow-bl2-${variant}.bin" { nativeBuildInputs = [ python3 ]; } ''
  python3 -P ${merge} ${aaBin} ${rvBin} ${map} ${variant} "$out"
''
