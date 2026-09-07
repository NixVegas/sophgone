#!/usr/bin/env python3
"""Merge two per-ISA FSBL bodies + their relocating stubs into one polyglot BL2
for the SG2000 unified fip.

Image layout (offsets from byte 0):

    0x000  8-word bl2_head (zero); ROM does not read it
    0x020  entry word 0x1400006F   aarch64 `b #444` / riscv `j 320`
    0x160  riscv trampoline        `jal x0` to the riscv relocator
    0x1DC  arm stub                relocates arm body to BL2_BASE, enters it
    <a4>   riscv relocator         right after the arm stub (4-aligned)
    0x1000 arm FSBL body
    <pg>   riscv FSBL body

ROM jumps to offset 0x20 (past the head), so the entry word and the `b #444`/`j
320` displacements are measured from there. Each stub is PIC; its trailing pool
words (BODY_SRC, BODY_LEN) are patched here, BL2_BASE/SCRATCH in the .S files.
"""
import struct

ENTRY_WORD      = 0x1400006F
ENTRY_OFF       = 0x20         # ROM's BL2 entry (past the 8-word bl2_head)
ARM_BASE        = 0x40100000   # arm BL2_BASE (mirror view), must match stub-arm.S
RISCV_BASE      = 0x0C000000   # riscv BL2_BASE (origin view), must match stub-riscv.S
RISCV_TRAMP_OFF = ENTRY_OFF + 320   # riscv `j 320` landing = 352
ARM_STUB_OFF    = ENTRY_OFF + 444   # arm `b #444` landing = 476
BODY_PAGE       = 0x1000       # first FSBL body starts here (page-aligned)
BL2_SIZE        = 0x37000      # ROM BL2 slot budget
POOL_TAIL       = 8            # bytes of (SRC, LEN) at the end of each stub


def _align(x, a):
    return (x + a - 1) & ~(a - 1)


def encode_jal_x0(imm):
    """Encode `jal x0, imm` (unconditional jump, no link). imm is a byte offset
    from the jal, even, in [-2^20, 2^20)."""
    assert imm % 2 == 0, f"jal imm {imm} not even"
    assert -(1 << 20) <= imm < (1 << 20), f"jal imm {imm} out of range"
    u = imm & 0x1FFFFF
    imm20   = (u >> 20) & 1
    imm10_1 = (u >> 1) & 0x3FF
    imm11   = (u >> 11) & 1
    imm19_12= (u >> 12) & 0xFF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (0 << 7) | 0x6F


def _patch_stub(stub, base, body_off, body_len):
    """Replace the stub's trailing (SRC, LEN) pool words. SRC is the body's
    runtime address (base + offset in the loaded image); LEN is rounded up to a
    word so the stub's word-copy is exact."""
    assert len(stub) >= POOL_TAIL
    src = base + body_off
    ln  = _align(body_len, 4)
    return stub[:-POOL_TAIL] + struct.pack("<II", src, ln)


def merge_bl2(arm_bl2, riscv_bl2, arm_stub, riscv_stub):
    arm_off        = BODY_PAGE
    riscv_body_off = arm_off + _align(len(arm_bl2), BODY_PAGE)
    total          = riscv_body_off + len(riscv_bl2)

    riscv_reloc_off = _align(ARM_STUB_OFF + len(arm_stub), 4)

    # sanity: nothing in the first page overlaps
    assert ARM_STUB_OFF + len(arm_stub) <= riscv_reloc_off, "arm stub / riscv reloc overlap"
    assert riscv_reloc_off + len(riscv_stub) <= BODY_PAGE, "stubs overrun the body page"
    assert RISCV_TRAMP_OFF + 4 <= ARM_STUB_OFF, "riscv trampoline overruns the arm stub"
    assert total <= BL2_SIZE, f"polyglot BL2 {total:#x} exceeds BL2_SIZE {BL2_SIZE:#x}"

    # The riscv reloc self-copies to a SCRATCH hardcoded in its pool (word 0, at
    # len-16). SRAM above the ROM-loaded image is unreachable via the C906 origin
    # window this early, so SCRATCH must sit in the dead gap between where the
    # riscv body lands and where it is sourced from, inside the writable image
    # (clobbering only the arm body's tail, dead on a riscv boot). Enforced here
    # so a body-size change that closes the gap fails the build, not the board.
    rv_scratch      = struct.unpack_from("<I", riscv_stub, len(riscv_stub) - 16)[0]
    rv_body_dst_end = RISCV_BASE + _align(len(riscv_bl2), 4)
    rv_body_src     = RISCV_BASE + riscv_body_off
    assert rv_body_dst_end <= rv_scratch, (
        f"riscv SCRATCH {rv_scratch:#x} below body-dst end {rv_body_dst_end:#x}: "
        f"the body copy would clobber the relocated stub")
    assert rv_scratch + len(riscv_stub) <= rv_body_src, (
        f"riscv SCRATCH {rv_scratch:#x}+{len(riscv_stub):#x} overruns body-src "
        f"{rv_body_src:#x}: the self-copy would corrupt the riscv body")

    buf = bytearray(total)
    struct.pack_into("<I", buf, ENTRY_OFF, ENTRY_WORD)   # entry word at the ROM's jump target
    # offsets 0..31 stay zero: the 8-word bl2_head the ROM steps over
    jal = encode_jal_x0(riscv_reloc_off - RISCV_TRAMP_OFF)
    struct.pack_into("<I", buf, RISCV_TRAMP_OFF, jal)

    arm_s = _patch_stub(arm_stub,   ARM_BASE,   arm_off,        len(arm_bl2))
    rv_s  = _patch_stub(riscv_stub, RISCV_BASE, riscv_body_off, len(riscv_bl2))
    buf[ARM_STUB_OFF:ARM_STUB_OFF + len(arm_s)]        = arm_s
    buf[riscv_reloc_off:riscv_reloc_off + len(rv_s)]   = rv_s
    buf[arm_off:arm_off + len(arm_bl2)]                = arm_bl2
    buf[riscv_body_off:riscv_body_off + len(riscv_bl2)] = riscv_bl2
    return bytes(buf)


if __name__ == "__main__":
    import sys
    arm, rv, arm_stub, rv_stub, out = sys.argv[1:6]
    data = merge_bl2(open(arm, "rb").read(), open(rv, "rb").read(),
                     open(arm_stub, "rb").read(), open(rv_stub, "rb").read())
    with open(out, "wb") as f:
        f.write(data)
