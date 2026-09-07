#!/usr/bin/env python3
# Verify the sophgone RE symbol/offset map pins the established anchors
# (regression guard on the RE) AND the RE-derived unknowns (f_open / f_read / load_image
# on both cores). Run: python3 tests/test_sophgone_map.py
import json, pathlib

M = json.load(open(pathlib.Path(__file__).parent.parent / "pkgs" / "overflow-bl2" / "sophgone-map.json"))
a, c = M["a53"], M["c906"]

# established anchors (must match; do not re-derive)
assert a["bl2_base"] == 0x40100000 and c["bl2_base"] == 0x0C000000, "bl2_base"
assert a["bl2_total"] == 0x3E400 == c["bl2_total"], "bl2_total"
assert a["polyglot_word_off"] == 0x20, "polyglot word offset"
assert a["rv_stub_off"] == 0x160 and a["aa_stub_off"] == 0x1DC, "stub tramp offsets"
assert a["syms"]["launch_or_entry"] == 0x4000E020, "A53 launch_bl2"
assert a["syms"]["load_image"] == 0x4000197C, "A53 load_image"
assert a["syms"]["flush_dcache"] == 0x400107A0 and a["syms"]["inv_icache"] == 0x400010A0, "A53 cache maint"

# hijack maps: A53 deep-cluster-only, C906 single slot -> the polyglot word
assert [h for h in a["hijack"] if h[0] == 0x3E178 and h[1] == "launch"], "A53 read-cluster missing 0x3E178"
assert len(a["hijack"]) == 19 and all(0x3E178 <= h[0] <= 0x3E388 and h[1] == "launch" for h in a["hijack"]), \
    "A53 hijack must be the 19-slot read-cluster launch (v13-proven)"
assert c["hijack"] == [[0x3E308, "word"]], "C906 = single disk_read slot -> polyglot word"

# body pages distinct from tramps and from each other
for isa in (a, c):
    assert isa["aa_body_off"] != isa["rv_body_off"], "bodies must be distinct pages"
    for b in (isa["aa_body_off"], isa["rv_body_off"]):
        assert b > 0x1DC, "bodies live past the tramps"

# RE-derived unknowns must be pinned to plausible ROM addresses (not None/0)
def in_rom_a53(x): return 0x40000000 <= x < 0x40018000
def in_rom_c906(x): return 0x04418000 <= x < 0x04430000   # C906 mask ROM runtime range
for k in ("f_open", "f_read", "load_image"):
    assert a["syms"].get(k) and in_rom_a53(a["syms"][k]), f"A53 {k} unpinned/out-of-rom"
    assert c["syms"].get(k) and in_rom_c906(c["syms"][k]), f"C906 {k} unpinned/out-of-rom"

print("map OK")
