#!/usr/bin/env python3
# Verify the chainload fip is a valid CVBL01 fip whose BL2 is the
# oversized overflow blob (BL2_IMG_SIZE == 0x3E400) carrying the polyglot word.
# Usage: test_chainload_fip.py <fip>
import sys, struct

blob = open(sys.argv[1], "rb").read()
assert blob[:6] == b"CVBL01", blob[:8]
assert struct.unpack_from("<I", blob, 0xD8)[0] == 0x3E400, "BL2_IMG_SIZE must be the 0x3E400 overflow"
assert b"\x6f\x00\x00\x14" in blob, "polyglot word (0x1400006F) not packed into the BL2"
print("chainload fip OK")
