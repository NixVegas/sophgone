#!/usr/bin/env python3
# Verify the merged polyglot overflow BL2 is exactly 0x3E400 bytes, carrying
# the polyglot word at 0x20, both stubs' dispatch tramps at 0x160/0x1DC, the g_sdhci_base
# island at 0x3C200, the A53 deep-cluster hijack (-> launch_bl2), the C906 single-slot
# hijack (-> polyglot word), and fill_value elsewhere.  Usage: test_...py <blob>
import struct, sys, json, pathlib

blob = open(sys.argv[1], "rb").read()
M = json.load(open(pathlib.Path(__file__).parent.parent / "pkgs" / "overflow-bl2" / "sophgone-map.json"))
a, c = M["a53"], M["c906"]
def q(off): return struct.unpack_from("<Q", blob, off)[0]
def w(off): return struct.unpack_from("<I", blob, off)[0]

assert len(blob) == 0x3E400, hex(len(blob))
assert w(0x20) == 0x1400006F, "polyglot word missing at 0x20"
# stub dispatch tramps present (non-fill) at their offsets
assert w(a["rv_stub_off"]) not in (0, a["fill_value"] & 0xffffffff), "rv tramp @0x160 missing"
assert w(a["aa_stub_off"]) not in (0, a["fill_value"] & 0xffffffff), "aa tramp @0x1DC missing"
# g_sdhci_base island
assert q(0x3C200) == 0x04310000, "g_sdhci_base island missing"
# A53 read-cluster hijack -> launch_bl2 (all 19 slots except 0x3E308, which the C906 owns)
for off, key in a["hijack"]:
    if off == 0x3E308:
        continue
    assert q(off) == a["syms"]["launch_or_entry"], f"A53 hijack {off:#x}"
# C906 single slot -> polyglot word (bl2_base + 0x20)
assert q(0x3E308) == c["bl2_base"] + a["polyglot_word_off"], "C906 slot -> polyglot word"
# dual-valid shared-physical fill elsewhere
assert q(0x38000) == 0x0C03F000, "dual-valid fill (0x0C03F000) not present in the body"
print("overflow-bl2 layout OK")
