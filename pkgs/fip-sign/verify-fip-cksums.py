#!/usr/bin/env python3
"""Assert every checksum a FIP records matches the bytes it ships.

The FSBL validates these before decrypting, so a stale checksum (computed over a
pre-signature/pre-encryption image) gets the image rejected regardless of keys.
This has regressed on LOADER_2ND_B before. Run it on the finished artifact.

Checks, all against image_crc = 0xCAFE0000 | crc_hqx(data, 0):
  param2 BLCP_2ND / MONITOR cksums over their param2 bodies;
  loader_2nd header CKSUM (LOADER_2ND, LOADER_2ND_B) over image[CKSUM.end:SIZE].

Usage: verify-fip-cksums.py fip.bin
"""

import binascii
import struct
import sys

PARAM2_MAGIC = 0x000A3230444C5643  # "CVLD02\n\0"

# struct fip_param2 (plat/cv181x/include/bl2.h) offsets
BLCP_2ND = 0x20  # cksum, loadaddr, size, runaddr
MONITOR = 0x30
LOADER_2ND_LOADADDR = 0x44
LOADER_2ND_B_LOADADDR = 0x54
LOADER_2ND_B_SIZE = 0x58

# loader_2nd header: JUMP0, MAGIC, CKSUM, SIZE, RUNADDR(8), RESERVED1, RESERVED2
HDR_CKSUM = 8
HDR_SIZE = 12
HDR_CKSUM_END = 12  # the FSBL's cksum_offset


def image_crc(data):
    return 0xCAFE0000 | binascii.crc_hqx(data, 0)


def find_param2(blob):
    for off in range(0, len(blob) - 8, 0x200):
        if struct.unpack_from("<Q", blob, off)[0] == PARAM2_MAGIC:
            return off
    raise SystemExit("verify-fip-cksums: no PARAM2 magic found")


def main(path):
    blob = open(path, "rb").read()
    p2 = find_param2(blob)
    u32 = lambda o: struct.unpack_from("<I", blob, p2 + o)[0]

    failures = []

    def check(name, recorded, data):
        got = image_crc(data)
        ok = got == recorded
        print(
            "%-14s recorded=0x%08x computed=0x%08x  %s"
            % (name, recorded, got, "OK" if ok else "MISMATCH")
        )
        if not ok:
            failures.append(name)

    for name, base in (("BLCP_2ND", BLCP_2ND), ("MONITOR", MONITOR)):
        cksum, loadaddr, size = u32(base), u32(base + 4), u32(base + 8)
        if not size:
            print("%-14s absent (size=0)" % name)
            continue
        check(name, cksum, blob[loadaddr : loadaddr + size])

    for name, la_off in (
        ("LOADER_2ND", LOADER_2ND_LOADADDR),
        ("LOADER_2ND_B", LOADER_2ND_B_LOADADDR),
    ):
        la = u32(la_off)
        if not la:
            print("%-14s absent (loadaddr=0)" % name)
            continue
        cksum = struct.unpack_from("<I", blob, la + HDR_CKSUM)[0]
        size = struct.unpack_from("<I", blob, la + HDR_SIZE)[0]
        check(name, cksum, blob[la + HDR_CKSUM_END : la + size])
        # The FSBL loads LOADER_2ND_B for `size` bytes out of param2, then reads
        # the header's own SIZE. Disagreement means a truncated or over-long read.
        if la_off == LOADER_2ND_B_LOADADDR:
            p2size = u32(LOADER_2ND_B_SIZE)
            if p2size != size:
                print(
                    "LOADER_2ND_B   param2 SIZE=0x%x != header SIZE=0x%x" % (p2size, size)
                )
                failures.append("LOADER_2ND_B_SIZE")

    if failures:
        raise SystemExit(
            "verify-fip-cksums: FAILED (%s). The FSBL checks these before it "
            "decrypts, so this image would be rejected on the core that owns the "
            "slot." % ", ".join(failures)
        )
    print("verify-fip-cksums: all checksums self-consistent")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-fip-cksums.py fip.bin")
    main(sys.argv[1])
