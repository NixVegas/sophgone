#!/usr/bin/env python3
"""Emit the SG2000 fuse plan (dry-run report + ordered efusew script).

Args: KPUB_HASH_FILE  LDR_EK_FILE  SERIAL  SEL(01|02)  OUT_DIR  [BOARD_USER_HEX]

Identity-only mode: pass "-" for both key files and SEL. Burns only the board
identity (DEVICE_ID + USER), leaving the badge open to unsigned FIPs and to
fusing secure boot later. BOARD_USER_HEX is badgeos board_id.py's 80-hex record;
DEVICE_ID derives from SERIAL. See SECURE-BOOT-FUSES.md.
"""
import sys

kpub_path, ldr_path, serial, sel, out = sys.argv[1:6]
board_user = (sys.argv[6].strip().lower() if len(sys.argv) > 6 else "")

identity_only = kpub_path == "-" and ldr_path == "-"
if identity_only:
    kpub = ldr = ""
    assert sel == "-", 'identity-only mode takes SEL "-" (no secure boot is enabled)'
else:
    kpub = open(kpub_path).read().strip().lower()
    ldr = open(ldr_path, "rb").read().hex()
    assert len(kpub) == 64, f"KPUB_HASH must be 32 bytes (64 hex): {kpub!r}"
    assert len(ldr) == 32, f"ldr_ek must be 16 bytes (32 hex): {ldr!r}"

# DEVICE_ID (0x8C, 8B): the serial as NUL-padded 8-bit ASCII (the badge reads it
# back for its USB iSerialNumber). USER (0x40, 40B): the board-id record, if given.
device_id = serial.encode("ascii")[:8].ljust(8, b"\x00").hex()
assert board_user == "" or len(board_user) == 80, \
    f"BOARD_USER_HEX must be 40 bytes (80 hex): {board_user!r}"
board_lines = f"efusew DEVICE_ID {device_id}   # \"{serial}\"\nefuser DEVICE_ID\n"
if board_user:
    board_lines += f"efusew USER {board_user}\nefuser USER\n"

# The remaining words only exist for a secure-boot burn; in identity-only mode
# nothing below DEVICE_ID/USER is written, so they are never composed.
# LOCK word @ 0xF8: HASH0_PUBLIC + LOADER_EK, write + read (double-bit 0x3).
wlock = (0x3 << 0) | (0x3 << 4)  # noqa: E501
rlock = (0x3 << 8) | (0x3 << 12)
lock = wlock | rlock

# SECURE_CONF @ 0xA0 reference value (CVI_EFUSE_EnableSecureBoot composes it;
# `efusew SECUREBOOT <sel>` writes it; shown here for review only).
conf = (0x3 << 2) | (0x4 << 20)  # TEE_SCS_ENABLE + ROOT_KEY_SEL
if sel == "02":
    conf |= (0x3 << 6) | (0x4 << 23)  # BOOT_LOADER_ENC + LDR_KEY_SEL

mode = "signature + encryption" if sel == "02" else "signature only"

if identity_only:
    report = f"""SG1 board-identity fuse plan (no secure boot, no keys)
=====================================================
serial       : {serial}
mode         : identity only: DEVICE_ID + USER, nothing else

area           offset  size  value
DEVICE_ID      0x8C    8B    {device_id}   ("{serial}")
USER           0x40    40B   {board_user or "(none, board-id not provided)"}

Neither area has lock bits and neither affects boot: the badge reports the
serial as its USB iSerialNumber and can name the board revision it came from.
HASH0_PUBLIC, LOADER_EK, LOCK and SECURE_CONF are not touched, so this badge
still boots unsigned FIPs, still accepts the plaintext per-core recovery blobs,
and its owner can choose to fuse secure boot later with the full plan.

Still OTP: USER and DEVICE_ID can be written once. Verify with efuser after the
write (the plan does this) and check the serial before burning; burning the
wrong serial cannot be undone.
"""
else:
    report = f"""SG1 secure-boot fuse plan
=========================
serial       : {serial}
mode         : SECUREBOOT {sel} ({mode})
!! contains the loader key in the clear; transient factory artifact, do not commit

area           offset  size  value
DEVICE_ID      0x8C    8B    {device_id}   ("{serial}")
USER           0x40    40B   {board_user or "(none, board-id not provided)"}
HASH0_PUBLIC   0xA8    32B   {kpub}
LOADER_EK      0xD8    16B   {ldr}

composed words (for review)
LOCK       @0xF8 : 0x{lock:08x}   (HASH0 w+r, LOADER w+r)
SECURE_CONF@0xA0 : 0x{conf:08x}   (written by `efusew SECUREBOOT {sel}`)

Follow SECURE-BOOT-FUSES.md. Verify (efuser) before the locks. SECUREBOOT is
last and permanent; do the first burn on a sacrificial board.
"""
open(f"{out}/fuse-plan.txt", "w").write(report)

if identity_only:
    cmds = f"""# SG1 board-identity burn, serial {serial}. No keys, no secure boot.
# Run in U-Boot. efusew/efuser live in the riscv U-Boot.
# Neither area has lock bits or any boot impact, but both are OTP: check the
# serial below before running this.
{board_lines}"""
    open(f"{out}/burn.cmds", "w").write(cmds)
    open(f"{out}/fuse-plan.txt", "w").write(report)
    print(report)
    raise SystemExit(0)

cmds = f"""# SG1 secure-boot burn, serial {serial}, SECUREBOOT {sel} ({mode})
# Run in U-Boot on a sacrificial board first. See SECURE-BOOT-FUSES.md.
# 0. board identity (USER + DEVICE_ID; no lock bits, no boot impact, independent
#    of secure-boot ordering). efusew/efuser live in the riscv U-Boot.
{board_lines}# 1. write keys (not locked yet)
efusew LOADER_EK    {ldr}
efusew HASH0_PUBLIC {kpub}
# 2. verify before locking: compare to LOADER_EK={ldr}
#                                  and HASH0_PUBLIC={kpub}
efuser LOADER_EK
efuser HASH0_PUBLIC
# 3. write-lock + read-lock the key areas (LOCK word becomes 0x{lock:08x})
efusew LOCK_LOADER_EK
efusew LOCK_HASH0_PUBLIC
# 4. enable secure boot (last, permanent)
efusew SECUREBOOT {sel}
"""
open(f"{out}/burn.cmds", "w").write(cmds)
open(f"{out}/fuse-plan.txt", "w").write(report)

print(report)
