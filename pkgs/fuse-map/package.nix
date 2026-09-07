# Per-serial SG2000 secure-boot fuse plan (off-board, safe).
#
# Emits a reviewable provisioning plan from the real KPUB_HASH (signed FIP) and
# the derived loader key (ldr_ek): the ordered `efusew`/`efuser` script and a
# bit-level dry-run (areas, values, the composed LOCK word at 0xF8, the
# SECURE_CONF reference value). Nothing here touches hardware.
#
# Order + protection bits follow SECURE-BOOT-FUSES.md: write keys, verify before
# lock, set write+read locks, enable SECUREBOOT last. DEVICE_EK is out of scope
# (see the doc section 9).
#
# The plan contains the loader key in the clear: a transient factory artifact.
# Do not commit it; it never goes on the device flash.
{
  runCommand,
  python3,

  serial,
  signedFip, # a signed(+enc) FIP derivation carrying kpub_hash.txt
  ldrEk, # the derived 16-byte loader key (fw-ldr-ek)
  encrypt ? true, # true -> SECUREBOOT 02 (sign+encrypt); false -> 01 (sign)
  # Optional 40-byte (80 hex) board-identity USER record from badgeos
  # board_id.py. Empty = burn DEVICE_ID (from serial) only, no USER record.
  boardIdUser ? "",
}:

let
  sel = if encrypt then "02" else "01";
in
runCommand "sg1-fuse-plan-${serial}"
  {
    nativeBuildInputs = [ python3 ];
    # Depends on the daemon-derived key; keep it off remote builders + caches.
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    python3 -P ${./gen-fuse-plan.py} \
      ${signedFip}/kpub_hash.txt ${ldrEk} '${serial}' '${sel}' $out '${boardIdUser}'
  ''
