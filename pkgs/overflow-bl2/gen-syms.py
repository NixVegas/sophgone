#!/usr/bin/env python3
# Emit per-ISA GAS `.equ` includes from sophgone-map.json, so the chainloader stubs
# reference ROM addresses/offsets symbolically (no hardcoded RE unknowns in the asm).
#   gen-syms.py sophgone-map.json aa|rv  > sophgone-syms-<isa>.inc
import json, sys

m = json.load(open(sys.argv[1]))[{"aa": "a53", "rv": "c906"}[sys.argv[2]]]
for k, v in m["syms"].items():
    if v is not None:
        print(f".equ {k.upper()}, {v:#x}")
for k in ("bl2_base", "spare_window", "bl2_total", "polyglot_word_off",
          "aa_stub_off", "rv_stub_off", "aa_body_off", "rv_body_off", "fill_value"):
    if isinstance(m.get(k), int):
        print(f".equ {k.upper()}, {m[k]:#x}")
