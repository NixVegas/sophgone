#!/bin/sh
# Runs the nixbadge_slot walk, the no-slot branch, the envpick copy chooser and the
# whole nixbadge_boot chain (walk + legacy tail, ext4-mbr and gpt cards, BOOT/USER held or
# not, signed-FIT boots and their failure modes) in the U-Boot sandbox
# (pkgs/uboot-sandbox/package.nix: stand-in sdready/sysboot/part/load, the real btnsel,
# source and bootm). The stand-ins are driven by env vars the test sets:
#   sb_parts  partition numbers `part uuid` finds (unset: none)
#   sb_files  files on the FAT: confs sysboot finds, FITs load finds. A found conf
#             "boots": the stand-in prints BOOTED <file> plus name=value for every
#             name in sb_show, then exits (unset: every sysboot prints SYSBOOT <args>
#             and returns). A found FIT is copied into sandbox RAM from
#             $sb_dir/<path> (unset sb_files: every load fails).
#   sb_dir    host directory holding the FAT's files (a tests/fixtures/fit/out/<case>)
#   sb_parts<d>, sb_files<d>, sb_dir<d>  the same for mmc <d> alone (a second card);
#             sb_parts<d> holds `<n>:<name>` words, which `part number` also answers from
#   sb_btn    "held" = BOOT held for the real btnsel's sample window
#   sb_user   "held" = USER held for the real btnsel's sample window (both held: factory
#             reset, the default profile plus nixbadge_args=nixbadge.reset=userdata)
#   sb_fused  "1" = the fake eFuse under the real nixbadge_fuse starts provisioned as
#             SG1-0003 (unset: blank); sb_core (arm, else riscv), sb_switch (unset =
#             Auto), sb_devek, sb_efuse, sb_efuser, sb_lock and sb_trng model the cores,
#             the board switch and the failure cases (pkgs/uboot-sandbox/
#             nixbadge-sandbox-stubs.c); `reset` prints RESET plus the sb_show values
# A bootm that reaches the kernel hand-off likewise prints "BOOTED bootm" plus the
# sb_show values and exits. Control flow only.
#
# The FIT cases (8, 9, 11, 13-15) need the signed fixtures and the sandbox control DTB that
# trusts their scratch key: run `sh tests/make-fit-fixtures.sh` first.
#
# Every env string comes out of pkgs/uboot-common/nixbadge.env, converted by the build's
# env2string.awk: the plain build's by default, the secure build's (the `#else` branch of
# its `#ifdef CONFIG_CMD_SYSBOOT`) for case 11f. The second argument is the core
# NIXBADGE_CORE stands for (default arm).
set -eu
UB=$1; NBCORE=${2:-arm}
TOP=$(cd "$(dirname "$0")/.." && pwd)
ENVFILE=$TOP/pkgs/uboot-common/nixbadge.env
FIX=$TOP/tests/fixtures/fit/out
[ -f "$FIX/control.dtb" ] || { echo "no FIT fixtures in $FIX: run sh tests/make-fit-fixtures.sh" >&2; exit 1; }
# nixbadge.env as the build's preprocessor leaves it: C comments dropped, the
# `#ifdef CONFIG_CMD_SYSBOOT` block resolved for the plain (sysboot compiled in) or
# secure (sysboot absent) build, NIXBADGE_CORE replaced. Any other directive fails.
envtext() {
  awk -v v="$1" -v core="$NBCORE" '
    incom { if (sub(/^.*\*\//, "")) incom = 0; else next }
    { while (match($0, /\/\*/)) {
        rest = substr($0, RSTART + 2)
        if (match(rest, /\*\//)) $0 = substr($0, 1, index($0, "/*") - 1) substr(rest, RSTART + 2)
        else { $0 = substr($0, 1, index($0, "/*") - 1); incom = 1 } } }
    /^#ifdef CONFIG_CMD_SYSBOOT$/ { inif = 1; keep = (v == "plain"); next }
    inif && /^#else$/ { keep = (v != "plain"); next }
    inif && /^#endif$/ { inif = 0; next }
    /^#/ { print "unexpected directive: " $0 > "/dev/stderr"; exit 1 }
    inif && !keep { next }
    { gsub(/NIXBADGE_CORE/, core); print }' "$ENVFILE" \
  | awk -f "$TOP/pkgs/uboot-common/env2string.awk" \
  | sed 's/^#define CONFIG_EXTRA_ENV_TEXT "//; s/"$//; s/\\0/\n/g; s/\\"/"/g'
}
# one env variable's value (plain build unless $2 = secure)
var() { envtext "${2:-plain}" | sed -n "s/^$1=//p"; }
SLOT=$(var nixbadge_slot); PICK=$(var nixbadge_envpick); BOOT=$(var nixbadge_boot); TRY=$(var nixbadge_try)
WALK=$(var nixbadge_walk); LEGACY=$(var nixbadge_legacy); CORE=$(var core); FIT=$(var nixbadge_fit)
FUSEONCE=$(var nixbadge_fuseonce); CARDFIT=$(var nixbadge_cardfit); FITBOOT=$(var nixbadge_fitboot)
PDEF=$(var nixbadge_profile_default); PBOOT=$(var nixbadge_profile_boot); PUSER=$(var nixbadge_profile_user)
[ "$PDEF/$PBOOT/$PUSER" = default/desktop/video ] || { echo "unexpected profile defaults in $ENVFILE: $PDEF/$PBOOT/$PUSER" >&2; exit 1; }
VBADDR=$(var vbaddr); LOADADDR=$(var loadaddr); SECLEGACY=$(var nixbadge_legacy secure)
[ -n "$SLOT" ] && [ -n "$PICK" ] && [ -n "$BOOT" ] && [ -n "$TRY" ] && [ -n "$WALK" ] && [ -n "$LEGACY" ] && [ -n "$CORE" ] \
  && [ -n "$FIT" ] && [ -n "$FITBOOT" ] && [ -n "$CARDFIT" ] && [ -n "$VBADDR" ] && [ -n "$LOADADDR" ] && [ -n "$SECLEGACY" ] && [ -n "$FUSEONCE" ] \
  || { echo "could not extract env strings from $ENVFILE" >&2; exit 1; }
# btnsel's extlinux directory is compiled in per core; the sandbox binary carries the arm one
# (pkgs/uboot-sandbox/package.nix), whichever core is under test.
BTNCORE=arm
# timeout: a sandbox that hangs (the `reset` stand-in prints RESET and exits)
run() { timeout 60 "$UB" -c "$1" 2>&1 | tr -d '\r'; }
# same, with the control DTB that carries the fixtures' public key (FIT cases)
runf() { timeout 60 "$UB" -d "$FIX/control.dtb" -c "$1" 2>&1 | tr -d '\r'; }
pre="setenv nixbadge_slot '$SLOT'; setenv nixbadge_envpick '$PICK'; setenv nixbadge_boot '$BOOT'; setenv nixbadge_try '$TRY'; setenv nixbadge_walk '$WALK'; setenv nixbadge_legacy '$LEGACY'; setenv nixbadge_fit '$FIT'; setenv nixbadge_fuseonce '$FUSEONCE'; setenv nixbadge_cardfit '$CARDFIT'; setenv nixbadge_fitboot '$FITBOOT'; setenv core $CORE; setenv scriptaddr 0x1000; setenv vbaddr $VBADDR; setenv loadaddr $LOADADDR; setenv nixbadge_profile_default $PDEF; setenv nixbadge_profile_boot $PBOOT; setenv nixbadge_profile_user $PUSER"
show="setenv sb_show 'rauc_slot rauc_ext nixroot BOOT_A_LEFT BOOT_B_LEFT'"
# 1. normal: A first, 3 attempts -> A chosen, A_LEFT 2
out=$(run "$pre; setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3; run nixbadge_slot; printenv rauc_slot BOOT_A_LEFT BOOT_B_LEFT")
echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'BOOT_A_LEFT=2' && echo "$out" | grep -qx 'BOOT_B_LEFT=3' || { echo "FAIL 1: $out"; exit 1; }
# 2. A exhausted -> B
out=$(run "$pre; setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 3; run nixbadge_slot; printenv rauc_slot BOOT_B_LEFT")
echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'BOOT_B_LEFT=2' || { echo "FAIL 2: $out"; exit 1; }
# 3. both exhausted -> re-arm, boot A, no reset
out=$(run "$pre; setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 0; run nixbadge_slot; printenv rauc_slot BOOT_A_LEFT BOOT_B_LEFT")
echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'BOOT_A_LEFT=2' && echo "$out" | grep -qx 'BOOT_B_LEFT=3' || { echo "FAIL 3: $out"; exit 1; }
# 4. defaults when unset (first boot on compiled-in env)
out=$(run "$pre; run nixbadge_slot; printenv BOOT_ORDER rauc_slot env_loaded")
echo "$out" | grep -qx 'BOOT_ORDER=A B' && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'env_loaded=1' || { echo "FAIL 4: $out"; exit 1; }
# 5. gpt card (partitions 3 and 4), no slot FIT anywhere (every load fails): eMMC boot
#    never calls sdready; the fallback order marks the failed slot bad, tries the other
#    slot, then the legacy conf last with slot A's PARTUUID re-derived (nixpart=3) and
#    rauc_slot=A (never B on slot A's kernel); SD boot does call sdready.
out=$(run "$pre; setenv sb_parts '3 4'; setenv bootmedium 0; setenv mmcdev 1; setenv env_loaded 1; run nixbadge_boot; printenv BOOT_A_LEFT nixpart rauc_slot")
echo "$out" | grep -q 'SDREADY-CALLED' && { echo "FAIL 5a (sdready on eMMC): $out"; exit 1; }
echo "$out" | grep -qx 'nixbadge: slot A has no vbmeta' || { echo "FAIL 5b: $out"; exit 1; }
echo "$out" | grep -qx 'BOOT_A_LEFT=0' || { echo "FAIL 5c (failed slot not marked bad): $out"; exit 1; }
echo "$out" | grep -qx 'nixbadge: slot B has no vbmeta' || { echo "FAIL 5d (other slot not tried next): $out"; exit 1; }
echo "$out" | grep -q "SYSBOOT mmc 1:1 any 0x1000 /$CORE/extlinux/extlinux.conf" || { echo "FAIL 5e (legacy conf not tried last): $out"; exit 1; }
echo "$out" | grep -qx 'nixpart=3' || { echo "FAIL 5f (legacy tail did not re-derive slot A's nixpart): $out"; exit 1; }
echo "$out" | grep -qx 'rauc_slot=A' || { echo "FAIL 5h (legacy tail left rauc_slot != A): $out"; exit 1; }
out=$(run "$pre; setenv sb_parts '3 4'; setenv bootmedium 1; setenv mmcdev 0; setenv env_loaded 1; run nixbadge_boot")
echo "$out" | grep -q 'SDREADY-CALLED' || { echo "FAIL 5g (no sdready on SD): $out"; exit 1; }
# 6. envpick: flags ff/00 -> second copy is newer; 01/02 -> second; 02/01 -> first
pick() { run "$pre; mw.b 0x82000004 $1 1; mw.b 0x82020004 $2 1; run nixbadge_envpick_test; printenv nb_first" | sed -n 's/^nb_first=//p'; }
prepick="$pre; setenv nixbadge_envpick_test '$(echo "$PICK" | sed 's/env import[^;]*;//g; s/env import.*$//')'"
pre0=$pre; pre=$prepick
[ "$(pick ff 00)" = 0x82020000 ] || { echo "FAIL 6a"; exit 1; }
[ "$(pick 01 02)" = 0x82020000 ] || { echo "FAIL 6b"; exit 1; }
[ "$(pick 02 01)" = 0x82000000 ] || { echo "FAIL 6c"; exit 1; }
[ "$(pick 00 ff)" = 0x82000000 ] || { echo "FAIL 6d"; exit 1; }
pre=$pre0
# 7. ext4-mbr card: MBR FAT + ext4, no partition 3; the FAT has only
#    extlinux.conf and extlinux-desktop.conf; compiled-in env (no env_loaded).
mbr="$pre; $show; setenv bootmedium 1; setenv mmcdev 0; setenv sb_files '/$CORE/extlinux/extlinux.conf /$BTNCORE/extlinux/extlinux-desktop.conf'"
#  7a. BOOT not held -> the legacy conf boots; rauc_slot (and nixroot) empty; no per-slot
#      sysboot and no saveenv attempted (the walk is skipped).
out=$(run "$mbr; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$CORE/extlinux/extlinux.conf" || { echo "FAIL 7a (legacy conf not booted): $out"; exit 1; }
echo "$out" | grep -qx 'rauc_slot=' || { echo "FAIL 7b (rauc_slot not empty in the APPEND): $out"; exit 1; }
echo "$out" | grep -qx 'nixroot=' || { echo "FAIL 7c (nixroot not empty): $out"; exit 1; }
echo "$out" | grep -q 'extlinux-[AB]\.conf' && { echo "FAIL 7d (per-slot sysboot on an ext4-mbr card): $out"; exit 1; }
echo "$out" | grep -qi 'saving environment' && { echo "FAIL 7e (saveenv on an ext4-mbr card): $out"; exit 1; }
echo "$out" | grep -q 'not a gpt-squashfs card, skipping the A/B walk' || { echo "FAIL 7f (no skip message): $out"; exit 1; }
#  7g. BOOT held -> the legacy desktop conf boots, rauc_slot empty.
out=$(run "$mbr; setenv sb_btn held; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$BTNCORE/extlinux/extlinux-desktop.conf" || { echo "FAIL 7g (BOOT held did not boot the desktop conf): $out"; exit 1; }
echo "$out" | grep -qx 'rauc_slot=' || { echo "FAIL 7h (rauc_slot not empty on the desktop boot): $out"; exit 1; }
#  7i. USER held -> the legacy video conf boots, rauc_slot empty.
mbrv="$pre; $show; setenv bootmedium 1; setenv mmcdev 0; setenv sb_files '/$CORE/extlinux/extlinux.conf /$BTNCORE/extlinux/extlinux-desktop.conf /$BTNCORE/extlinux/extlinux-video.conf'"
out=$(run "$mbrv; setenv sb_user held; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$BTNCORE/extlinux/extlinux-video.conf" || { echo "FAIL 7i (USER held did not boot the video conf): $out"; exit 1; }
echo "$out" | grep -qx 'rauc_slot=' || { echo "FAIL 7j (rauc_slot not empty on the video boot): $out"; exit 1; }
#  7k. BOOT and USER both held -> factory reset: the default conf boots, with
#      nixbadge_args=nixbadge.reset=userdata set for its APPEND line.
out=$(run "$mbrv; setenv sb_show 'rauc_slot nixbadge_args'; setenv sb_btn held; setenv sb_user held; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$CORE/extlinux/extlinux.conf" && echo "$out" | grep -qx 'nixbadge_args=nixbadge.reset=userdata' \
  || { echo "FAIL 7k (both held did not boot the default conf with the reset args): $out"; exit 1; }
#  7l. USER held on a card with no extlinux-video.conf -> falls through to the legacy conf.
out=$(run "$mbr; setenv sb_user held; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$CORE/extlinux/extlinux.conf" || { echo "FAIL 7l (missing video conf did not fall through): $out"; exit 1; }
gptbase="$pre; setenv sb_parts '3 4'; setenv env_loaded 1; setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3"
gpt="$gptbase; $show"
# FIT cases: a gpt card whose FAT carries each slot's signed vbmeta.itb + boot.itb
# (tests/fixtures/fit/out/<case>/<core>/slot-<A|B>/), booted by nixbadge_fit through the
# real source/bootm against the control DTB holding the fixtures' public key.
fitfiles="/$CORE/slot-A/vbmeta.itb /$CORE/slot-A/boot.itb /$CORE/slot-B/vbmeta.itb /$CORE/slot-B/boot.itb"
fit="$gptbase; setenv sb_show 'rauc_slot rauc_ext nixroot target bootargs BOOT_A_LEFT BOOT_B_LEFT'; setenv sb_dir $FIX/good; setenv bootmedium 0; setenv mmcdev 1"
# 8. gpt card, both slots' FITs present: the walk boots slot A's boot.itb (conf-default)
#    with slot A's PARTUUID; rauc_ext rides along as set.
out=$(runf "$fit; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -q "Using 'conf-default' configuration" || { echo "FAIL 8a (gpt walk did not boot slot A's conf-default): $out"; exit 1; }
echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'nixroot=sbuuid-3' && echo "$out" | grep -qx 'BOOT_A_LEFT=2' || { echo "FAIL 8b: $out"; exit 1; }
echo "$out" | grep -qx 'rauc_ext=' || { echo "FAIL 8c (rauc_ext not empty on the eMMC boot): $out"; exit 1; }
out=$(runf "$fit; setenv bootmedium 1; setenv mmcdev 0; setenv rauc_ext rauc.external; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A rauc.external nixbadge.profile=default ' || { echo "FAIL 8d (SD boot: $out)"; exit 1; }
#  8e. BOOT held on slot B -> target desktop: script-desktop boots conf-desktop
out=$(runf "$fit; setenv sb_btn held; setenv BOOT_ORDER 'B A'; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'btnsel: target desktop' && echo "$out" | grep -q "Using 'conf-desktop' configuration" && echo "$out" | grep -qx 'BOOTED bootm' \
  && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'nixroot=sbuuid-4' && echo "$out" | grep -qx 'target=desktop' \
  || { echo "FAIL 8e (gpt BOOT held: $out)"; exit 1; }
#  8f. both held -> factory reset: target default, script-default boots conf-default
#      with nixbadge.reset=userdata appended to bootargs
out=$(runf "$fit; setenv sb_btn held; setenv sb_user held; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'btnsel: target default' && echo "$out" | grep -qx 'target=default' && echo "$out" | grep -qx 'rauc_slot=A' \
  && echo "$out" | grep -q "Using 'conf-default' configuration" && echo "$out" | grep -qx 'BOOTED bootm' \
  && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A  nixbadge.profile=default nixbadge.reset=userdata' \
  || { echo "FAIL 8f (gpt both held: $out)"; exit 1; }
# 9. gpt card, slot A's boot.itb missing (its vbmeta present) -> A marked bad, B boots
#    with B's PARTUUID
out=$(runf "$fit; setenv sb_files '/$CORE/slot-A/vbmeta.itb /$CORE/slot-B/vbmeta.itb /$CORE/slot-B/boot.itb'; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'nixroot=sbuuid-4' && echo "$out" | grep -qx 'BOOT_A_LEFT=0' || { echo "FAIL 9: $out"; exit 1; }
# 10. gpt card, neither slot has a FIT -> the legacy conf boots as slot A (checked on
#     the actual boot, not just the final env): rauc_slot=A, slot A's PARTUUID.
out=$(run "$gpt; setenv bootmedium 0; setenv mmcdev 1; setenv sb_files '/$CORE/extlinux/extlinux.conf'; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$CORE/extlinux/extlinux.conf" && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'nixroot=sbuuid-3' || { echo "FAIL 10: $out"; exit 1; }
#  10b. same, USER held -> the legacy video conf (slot A's copy) boots as slot A.
out=$(run "$gpt; setenv bootmedium 0; setenv mmcdev 1; setenv sb_user held; setenv sb_files '/$CORE/extlinux/extlinux.conf /$BTNCORE/extlinux/extlinux-video.conf'; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$BTNCORE/extlinux/extlinux-video.conf" && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'nixroot=sbuuid-3' || { echo "FAIL 10b: $out"; exit 1; }
# 11. signed-FIT verification, gpt card, slot A chosen first.
#  11a. happy path: both scripts (vbmeta's frag, boot.itb's script-default) pass `source`'s
#       image check (column-0 "sg1-image-img+" lines; the per-image key, required =
#       "image"), bootm checks conf-default's signature (sg1-image+ OK, once for the
#       kernel and once for the fdt) and hands off; the profile script saw verityargs
#       from the vbmeta script and the walk's rauc_slot.
out=$(runf "$fit; setenv sb_files '$fitfiles'; run nixbadge_boot")
[ "$(echo "$out" | grep -c '^sha256,rsa2048:sg1-image-img+ sha256+')" = 2 ] || { echo "FAIL 11a (vbmeta + profile script not both verified): $out"; exit 1; }
[ "$(echo "$out" | grep -c 'sha256,rsa2048:sg1-image+ OK')" = 2 ] && echo "$out" | grep -q "Using 'conf-default' configuration" || { echo "FAIL 11a (conf-default signature not verified): $out"; exit 1; }
echo "$out" | grep -q '^## Transferring control to Linux' && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'target=default' \
  && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A  nixbadge.profile=default ' || { echo "FAIL 11a (boot): $out"; exit 1; }
#  11b. USER held, boot.itb has no script-video -> script-default is sourced and boots
#       conf-default; target keeps the button's name.
out=$(runf "$fit; setenv sb_user held; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -q '^btnsel: USER held -> video' && echo "$out" | grep -qx 'nixbadge: no script-video' \
  && echo "$out" | grep -q "Using 'conf-default' configuration" && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'target=video' \
  && echo "$out" | grep -qx 'rauc_slot=A' || { echo "FAIL 11b (profile missing): $out"; exit 1; }
#  11c. slot A has no vbmeta.itb -> A marked bad, B boots
out=$(runf "$fit; setenv sb_files '/$CORE/slot-A/boot.itb /$CORE/slot-B/vbmeta.itb /$CORE/slot-B/boot.itb'; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge: slot A has no vbmeta' && echo "$out" | grep -qx 'nixbadge: slot A did not boot, marking it bad and trying the other' \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'BOOT_A_LEFT=0' || { echo "FAIL 11c (vbmeta missing): $out"; exit 1; }
#  11d. slot A's boot.itb signed with another key -> its script fails the image check,
#       nothing of it runs, the walk moves on to B
out=$(runf "$fit; setenv sb_dir $FIX/badsig; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -q '^sha256,rsa2048:sg1-image-img- ' && echo "$out" | grep -qx 'Bad Data Hash' \
  && echo "$out" | grep -qx 'nixbadge: slot A did not boot, marking it bad and trying the other' \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' || { echo "FAIL 11d (bad signature): $out"; exit 1; }
[ "$(echo "$out" | grep -c "Using 'conf-default' configuration")" = 2 ] || { echo "FAIL 11d (slot A's bootm ran, or B's did not): $out"; exit 1; }
#  11e. one byte of slot A's kernel data flipped after signing -> the configuration
#       signature still checks (it covers the hash nodes) but the kernel image fails
#       its own check, bootm gives up, the walk moves on to B
out=$(runf "$fit; setenv sb_dir $FIX/tampered; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'Bad Data Hash' && echo "$out" | grep -qx "ERROR: can't get kernel image!" \
  && echo "$out" | grep -qx 'nixbadge: slot A did not boot, marking it bad and trying the other' \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' || { echo "FAIL 11e (tampered kernel): $out"; exit 1; }
#  11f. secure build (no sysboot compiled in): its env strings never mention sysboot,
#       nixbadge_legacy only reports and then halts (the sandbox's nixbadge_halt
#       stand-in prints HALTED and exits; the board's idles forever), so a card with no
#       bootable slot ends the walk at "nixbadge: no slot booted" + HALTED, never at
#       the command line, on a gpt card and on an ext4-mbr card alike.
envtext secure | grep -q sysboot && { echo "FAIL 11f (secure env references sysboot)"; exit 1; }
[ "$SECLEGACY" = 'echo nixbadge: no slot booted; nixbadge_halt' ] || { echo "FAIL 11f (secure nixbadge_legacy = '$SECLEGACY')"; exit 1; }
secpre="$(echo "$fit" | sed "s|setenv nixbadge_legacy '[^']*'|setenv nixbadge_legacy '$SECLEGACY'|")"
out=$(runf "$secpre; setenv sb_files '/$CORE/extlinux/extlinux.conf'; run nixbadge_boot; echo AFTER-BOOTCMD")
[ "$(echo "$out" | grep '^nixbadge: ' | tail -n1)" = 'nixbadge: no slot booted' ] && [ "$(echo "$out" | tail -n1)" = HALTED ] \
  && ! echo "$out" | grep -q '^SYSBOOT\|^BOOTED' || { echo "FAIL 11f (gpt): $out"; exit 1; }
out=$(runf "$secpre; setenv sb_parts; setenv sb_files '/$CORE/extlinux/extlinux.conf'; run nixbadge_boot; echo AFTER-BOOTCMD")
[ "$(echo "$out" | grep '^nixbadge: ' | tail -n1)" = 'nixbadge: no slot booted' ] && [ "$(echo "$out" | tail -n1)" = HALTED ] \
  && ! echo "$out" | grep -q '^SYSBOOT\|^BOOTED' || { echo "FAIL 11f (ext4-mbr): $out"; exit 1; }
#  11g. BOOT held, slot A's boot.itb has script-desktop but conf-desktop is signed with
#       another key: script-desktop runs, its bootm refuses the configuration and
#       returns, the log says so, and script-default then boots conf-default on slot A
#       (a profile is a convenience; the slot is still good).
out=$(runf "$fit; setenv sb_btn held; setenv sb_dir $FIX/profilefail; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -q "Using 'conf-desktop' configuration" && echo "$out" | grep -qx "Failed to verify required signature 'key-sg1-image'" \
  && echo "$out" | grep -qx 'nixbadge: script-desktop did not boot, trying script-default' \
  && ! echo "$out" | grep -q 'nixbadge: no script-desktop' && echo "$out" | grep -q "Using 'conf-default' configuration" \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'target=desktop' \
  && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A  nixbadge.profile=default ' || { echo "FAIL 11g (profile script returned): $out"; exit 1; }
#  11h. slot A's vbmeta is validly signed but sets no verityargs -> the
#       test -n "${verityargs}" gate stops slot A before its boot.itb is even loaded;
#       A is marked bad and B boots.
out=$(runf "$fit; setenv sb_dir $FIX/noverity; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -q 'nixbadge fixture: this frag sets no verityargs$' \
  && echo "$out" | grep -qx 'nixbadge: slot A did not boot, marking it bad and trying the other' \
  && [ "$(echo "$out" | grep -c '^## Executing script at 8a000000')" = 1 ] \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'BOOT_A_LEFT=0' || { echo "FAIL 11h (no verityargs): $out"; exit 1; }
# 12. nixbadge_fuseonce, first in nixbadge_boot: with $nixbadge_fuse_serial in the stored
#     env the real nixbadge_fuse runs over the sandbox's fake eFuse, TRNG and core-select
#     latch ($sb_core picks the core, riscv unless "arm"; $sb_switch pins the strap). Its
#     $nb_done deletes the variables, its $nb_reset saves and resets; else the boot goes on.
USERHEX=2d6415b2598a43bff3d18c4fd4d9764ccef49102fbb4f85b8b0e4cf956e2df879642829d207f6efc
fuse="$mbr; setenv sb_show 'nixbadge_fuse_serial nixbadge_fuse_return'"
booted() { echo "$1" | grep -qx "BOOTED /$CORE/extlinux/extlinux.conf" && ! echo "$1" | grep -q '^RESET'; }
reset_() { echo "$1" | grep -qx 'nixbadge: resetting after the fuse step' && echo "$1" | grep -qx RESET && ! echo "$1" | grep -q '^BOOTED\|^SYSBOOT'; }
cleared() { echo "$1" | grep -qx 'nixbadge_fuse_serial=' && echo "$1" | grep -qx 'nixbadge_fuse_return='; }
efusew() { echo "$1" | grep '^EFUSEW ' | cut -d' ' -f1-3 | sed 's/^\(EFUSEW DEVICE_EK\) .*/\1/'; }
IDENT="$(printf 'EFUSEW DEVICE_ID 5347312d30303037\nEFUSEW USER %s' "$USERHEX")"
#  12a. riscv, blank badge: DEVICE_ID, USER, then the device key burned and read-locked,
#       in that order; both variables gone, saved, reset.
out=$(run "$fuse; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
[ "$(efusew "$out")" = "$(printf '%s\nEFUSEW DEVICE_EK' "$IDENT")" ] && echo "$out" | grep -qx 'nixbadge_fuse: fused SG1-0007' \
  && echo "$out" | grep -qx 'EFUSE-LOCK DEVICE_EK' && echo "$out" | grep -qx 'devek: DEVICE_EK provisioned + read-locked (0xE8)' \
  && ! echo "$out" | grep -q 'fusing failed\|^LATCH' && echo "$out" | grep -qi 'saving environment' && reset_ "$out" && cleared "$out" \
  || { echo "FAIL 12a (riscv, blank badge): $out"; exit 1; }
#  12b. riscv, identity and key both done: nothing written, variable cleared, boots.
out=$(run "$fuse; setenv sb_fused 1; setenv sb_devek locked; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge_fuse: already provisioned SG1-0003' && echo "$out" | grep -qx 'nixbadge_fuse: device key already burned and locked' \
  && ! echo "$out" | grep -q '^EFUSEW\|^EFUSE-LOCK\|fusing failed' && booted "$out" && cleared "$out" || { echo "FAIL 12b (both done): $out"; exit 1; }
#  12c. no variable: no fuse step at all, nothing saved.
out=$(run "$fuse; run nixbadge_boot")
! echo "$out" | grep -q '^nixbadge_fuse:\|^EFUSEW\|^LATCH' && ! echo "$out" | grep -qi 'saving environment' && booted "$out" \
  || { echo "FAIL 12c (fuse step without the variable): $out"; exit 1; }
#  12d. malformed serials (too long, zero, lower case, a hush separator inside), on either
#       core: refused before any read, write or latch, cleared, the boot goes on; the
#       value is one argument, never parsed as commands.
for c in riscv arm; do
  for bad in SG1-12345 SG1-0000 sg1-0007 'SG1-000x' 'SG1-0007; echo PWNED'; do
    out=$(run "$fuse; setenv sb_core $c; setenv nixbadge_fuse_serial '$bad'; run nixbadge_boot")
    echo "$out" | grep -qx 'nixbadge_fuse: the serial must be SG1-0001 .. SG1-9999' \
      && echo "$out" | grep -qx 'nixbadge: fusing failed' && ! echo "$out" | grep -q '^EFUSEW\|^PWNED\|^LATCH' \
      && booted "$out" && cleared "$out" || { echo "FAIL 12d ($c, '$bad'): $out"; exit 1; }
  done
done
#  12e. riscv, DEVICE_ID does not read back as written: the bad word is named, USER and
#       the key are never written; the riscv run is final: cleared, then the reset.
out=$(run "$fuse; setenv sb_efuse stuck; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge_fuse: DEVICE_ID word 0x8c reads 0x2d314752, want 0x2d314753' \
  && echo "$out" | grep -q '^nixbadge_fuse: DEVICE_ID did not program' && ! echo "$out" | grep -q '^EFUSEW USER\|^EFUSEW DEVICE_EK' \
  && echo "$out" | grep -qx 'nixbadge: fusing failed' && reset_ "$out" && cleared "$out" || { echo "FAIL 12e (read-back mismatch): $out"; exit 1; }
#  12f. riscv, efuser unavailable: the physical read decides the identity; devek, which
#       needs efuser to verify the key, cannot start and burns nothing.
out=$(run "$fuse; setenv sb_efuser fail; setenv nixbadge_fuse_serial SG1-0025; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge_fuse: efuser read unavailable, deciding on the physical read' \
  && echo "$out" | grep -qx 'nixbadge_fuse: fused SG1-0025' && echo "$out" | grep -qx 'devek: DEVICE_EK read failed' \
  && echo "$out" | grep -qx 'nixbadge_fuse: device key NOT burned (DEVICE_EK read failed); re-run nix-badge-install to retry' && ! echo "$out" | grep -q '^EFUSEW DEVICE_EK' \
  && reset_ "$out" && cleared "$out" || { echo "FAIL 12f (no efuser): $out"; exit 1; }
#  12g. riscv, DEVICE_EK already set but not locked: never touched again, said loudly.
out=$(run "$fuse; setenv sb_devek set; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
[ "$(efusew "$out")" = "$IDENT" ] && echo "$out" | grep -qx 'devek: DEVICE_EK already set; refusing' \
  && echo "$out" | grep -qx 'nixbadge_fuse: devek: key set but NOT locked; not touching it' && ! echo "$out" | grep -q '^EFUSE-LOCK' \
  && reset_ "$out" && cleared "$out" || { echo "FAIL 12g (key set, unlocked): $out"; exit 1; }
#  12h. riscv, the read-lock does not take (the LOCK-word -5): burned but NOT locked,
#       never success, never retried.
out=$(run "$fuse; setenv sb_lock fail; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -q '^EFUSEW DEVICE_EK ' && echo "$out" | grep -q '^devek: read-lock failed (LOCK word ' \
  && echo "$out" | grep -qx 'nixbadge_fuse: devek: key burned but NOT locked' && ! echo "$out" | grep -q 'provisioned + read-locked' \
  && echo "$out" | grep -qx 'nixbadge: fusing failed' && reset_ "$out" && cleared "$out" || { echo "FAIL 12h (lock failed): $out"; exit 1; }
#  12i. riscv, the TRNG never answers: no hang, nothing of the key burned.
out=$(run "$fuse; setenv sb_trng dead; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'devek: TRNG not responding; nothing burned' && ! echo "$out" | grep -q '^EFUSEW DEVICE_EK' \
  && echo "$out" | grep -qx 'nixbadge_fuse: device key NOT burned (TRNG not responding); re-run nix-badge-install to retry' \
  && reset_ "$out" && cleared "$out" || { echo "FAIL 12i (dead TRNG): $out"; exit 1; }
#  12i2. the TRNG repeats itself: refused before burning anything.
out=$(run "$fuse; setenv sb_trng stuck; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'devek: TRNG output has a zero or repeated block; nothing burned' && ! echo "$out" | grep -q '^EFUSEW DEVICE_EK' \
  && echo "$out" | grep -qx 'nixbadge_fuse: device key NOT burned (TRNG output failed the sanity check); re-run nix-badge-install to retry' \
  && reset_ "$out" && cleared "$out" || { echo "FAIL 12i2 (stuck TRNG): $out"; exit 1; }
#  12h2. the lock takes only partly (write-lock, one read-lock bit): NOT locked; a
#        partial lock found before burning is never touched either.
out=$(run "$fuse; setenv sb_lock partial; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -q '^EFUSEW DEVICE_EK ' && echo "$out" | grep -q '^devek: read-lock failed (LOCK word 0x000040c0)' \
  && echo "$out" | grep -qx 'nixbadge_fuse: devek: key burned but NOT locked' && reset_ "$out" && cleared "$out" \
  || { echo "FAIL 12h2 (partial lock): $out"; exit 1; }
out=$(run "$fuse; setenv sb_fused 1; setenv sb_devek partial; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -q '^devek: DEVICE_EK lock is partial' && ! echo "$out" | grep -q '^EFUSEW\|^EFUSE-LOCK' \
  && echo "$out" | grep -qx 'nixbadge_fuse: devek: key burned but NOT locked' && booted "$out" && cleared "$out" \
  || { echo "FAIL 12h2 (partial lock found): $out"; exit 1; }
#  12l2. arm, forced ARM: an identity that does not read back is never retried.
out=$(run "$fuse; setenv sb_core arm; setenv sb_switch arm; setenv sb_efuse stuck; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -q '^nixbadge_fuse: DEVICE_ID did not program' && ! echo "$out" | grep -q 'key pending' \
  && reset_ "$out" && cleared "$out" || { echo "FAIL 12l2 (arm identity failure): $out"; exit 1; }
#  12j. arm, switch on Auto: nothing written on arm; latch riscv, remember to come back,
#       keep the serial, save, reset.
out=$(run "$fuse; setenv sb_core arm; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'LATCH riscv' && echo "$out" | grep -qx 'nixbadge_fuse: switching to the riscv core to fuse; it switches back' \
  && ! echo "$out" | grep -q '^EFUSEW\|^LATCH arm' && echo "$out" | grep -qi 'saving environment' && reset_ "$out" \
  && echo "$out" | grep -qx 'nixbadge_fuse_serial=SG1-0007' && echo "$out" | grep -qx 'nixbadge_fuse_return=arm' \
  || { echo "FAIL 12j (arm, Auto: hop to riscv): $out"; exit 1; }
#  12k. riscv after that hop: identity and key, latch arm again, both variables cleared,
#       reset.
out=$(run "$fuse; setenv nixbadge_fuse_return arm; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
[ "$(efusew "$out")" = "$(printf '%s\nEFUSEW DEVICE_EK' "$IDENT")" ] && echo "$out" | grep -qx 'nixbadge_fuse: switching back to the arm core' \
  && echo "$out" | grep -qx 'LATCH arm' && reset_ "$out" && cleared "$out" || { echo "FAIL 12k (riscv, back to arm): $out"; exit 1; }
#  12l. arm, switch forced to ARM: the latch does not move the strap, so it is put back;
#       the identity is written on arm, the key is pending, the serial is kept, reset.
out=$(run "$fuse; setenv sb_core arm; setenv sb_switch arm; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
[ "$(echo "$out" | grep '^LATCH')" = "$(printf 'LATCH riscv\nLATCH arm')" ] && [ "$(efusew "$out")" = "$IDENT" ] \
  && echo "$out" | grep -qx 'nixbadge_fuse: device key pending, boot the riscv core once' && ! echo "$out" | grep -q '^EFUSE-LOCK' \
  && reset_ "$out" && echo "$out" | grep -qx 'nixbadge_fuse_serial=SG1-0007' && echo "$out" | grep -qx 'nixbadge_fuse_return=' \
  || { echo "FAIL 12l (arm, forced: identity only): $out"; exit 1; }
#  12m. arm, forced, identity already there: key pending, serial kept, no reset, boots.
out=$(run "$fuse; setenv sb_core arm; setenv sb_switch arm; setenv sb_fused 1; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge_fuse: already provisioned SG1-0003' && echo "$out" | grep -qx 'nixbadge_fuse: device key pending, boot the riscv core once' \
  && ! echo "$out" | grep -q '^EFUSEW' && booted "$out" && echo "$out" | grep -qx 'nixbadge_fuse_serial=SG1-0007' \
  || { echo "FAIL 12m (arm, forced, provisioned): $out"; exit 1; }
#  12n. arm with a hop already recorded (the riscv run never finished): no second hop.
out=$(run "$fuse; setenv sb_core arm; setenv sb_fused 1; setenv nixbadge_fuse_return arm; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
! echo "$out" | grep -q '^LATCH' && echo "$out" | grep -qx 'nixbadge_fuse: device key pending, boot the riscv core once' && booted "$out" \
  || { echo "FAIL 12n (arm, no second hop): $out"; exit 1; }
#  12o. gpt card: a riscv run that writes resets before the A/B walk; once both are done
#       the walk goes on.
out=$(run "$gpt; setenv bootmedium 0; setenv mmcdev 1; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge_fuse: fused SG1-0007' && ! echo "$out" | grep -q 'slot A' && reset_ "$out" \
  || { echo "FAIL 12o (gpt, fused): $out"; exit 1; }
out=$(run "$gpt; setenv bootmedium 0; setenv mmcdev 1; setenv sb_fused 1; setenv sb_devek locked; setenv nixbadge_fuse_serial SG1-0007; run nixbadge_boot; printenv nixbadge_fuse_serial")
echo "$out" | grep -qx 'nixbadge_fuse: already provisioned SG1-0003' && echo "$out" | grep -qx 'nixbadge: slot A has no vbmeta' \
  && echo "$out" | grep -q '"nixbadge_fuse_serial" not defined' || { echo "FAIL 12o (gpt, done): $out"; exit 1; }
# 13. btnsel's profile variables. Each run starts with a stale nixbadge_args, which
#     btnsel must clear unless both buttons are held.
bs() {
  out=$(run "$pre; setenv nixbadge_args stale; setenv bootconf unset; $1; btnsel; echo \"T=\${target}\"; echo \"A=[\${nixbadge_args}]\"; echo \"C=\${bootconf}\"")
  echo "$out" | grep -qxF "T=$2" && echo "$out" | grep -qxF "A=[$3]" && echo "$out" | grep -qxF "C=$4" || { echo "FAIL 13 ($5): $out"; exit 1; }
}
#  13a. the defaults: neither, BOOT, USER, both
bs 'true' default '' unset 'no button'
bs 'setenv sb_btn held' desktop '' /$BTNCORE/extlinux/extlinux-desktop.conf 'BOOT'
bs 'setenv sb_user held' video '' /$BTNCORE/extlinux/extlinux-video.conf 'USER'
bs 'setenv sb_btn held; setenv sb_user held' default 'nixbadge.reset=userdata' unset 'both'
#  13b. overridden names are respected, including for the factory reset
bs 'setenv nixbadge_profile_boot demo; setenv sb_btn held' demo '' /$BTNCORE/extlinux/extlinux-demo.conf 'boot=demo'
bs 'setenv nixbadge_profile_user kiosk-2; setenv sb_user held' kiosk-2 '' /$BTNCORE/extlinux/extlinux-kiosk-2.conf 'user=kiosk-2'
bs 'setenv nixbadge_profile_default desktop' desktop '' /$BTNCORE/extlinux/extlinux-desktop.conf 'default=desktop'
bs 'setenv nixbadge_profile_default video; setenv sb_btn held; setenv sb_user held' video 'nixbadge.reset=userdata' /$BTNCORE/extlinux/extlinux-video.conf 'both, default=video'
#  13c. unset, empty-by-deletion, malformed or overlong names fall back to the built-in ones
bs 'setenv nixbadge_profile_boot; setenv sb_btn held' desktop '' /$BTNCORE/extlinux/extlinux-desktop.conf 'boot unset'
bs 'setenv nixbadge_profile_user ../x; setenv sb_user held' video '' /$BTNCORE/extlinux/extlinux-video.conf 'user=../x'
bs "setenv nixbadge_profile_default 'a b'" default '' unset 'default with a space'
bs 'setenv nixbadge_profile_boot abcdefghijklmnopqrstuvwxyz0123456; setenv sb_btn held' desktop '' /$BTNCORE/extlinux/extlinux-desktop.conf 'boot, 33 chars'
bs 'setenv nixbadge_profile_boot abcdefghijklmnopqrstuvwxyz012345; setenv sb_btn held' abcdefghijklmnopqrstuvwxyz012345 '' \
  /$BTNCORE/extlinux/extlinux-abcdefghijklmnopqrstuvwxyz012345.conf 'boot, 32 chars'
#  13d. with rauc_slot set the conf carries the slot suffix
bs 'setenv rauc_slot B; setenv sb_btn held' desktop '' /$BTNCORE/extlinux/extlinux-desktop-B.conf 'BOOT, slot B'
#  13e. an overridden name on the FIT path: no script-demo in boot.itb, so script-default
#       boots conf-default and target keeps the name
out=$(runf "$fit; setenv nixbadge_profile_boot demo; setenv sb_btn held; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge: no script-demo' && echo "$out" | grep -q "Using 'conf-default' configuration" && echo "$out" | grep -qx 'BOOTED bootm' \
  && echo "$out" | grep -qx 'target=demo' || { echo "FAIL 13e (FIT, boot=demo): $out"; exit 1; }
#  13f. and on the legacy tail: extlinux-demo.conf boots
out=$(run "$mbr; setenv nixbadge_profile_boot demo; setenv sb_btn held; setenv sb_files '/$CORE/extlinux/extlinux.conf /$BTNCORE/extlinux/extlinux-demo.conf'; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$BTNCORE/extlinux/extlinux-demo.conf" || { echo "FAIL 13f (legacy, boot=demo): $out"; exit 1; }
# 14. overrides stored from Linux. The board's stored-env write list
#     (uboot-bootenv.patch) and nixbadge_envpick's import list name the same variables,
#     the three profile variables among them and nixbadge_args in neither.
WL=$(sed -n 's/^+ *"\(BOOT_ORDER:[^"]*\)"$/\1/p' "$TOP/pkgs/uboot-common/uboot-bootenv.patch" | tr ',' '\n' | sed 's/:.*//' | sort | tr '\n' ' ')
IL=$(echo "$PICK" | sed -n 's/^.*env import -c ${nb_first} 0x20000 \([^|]*\) ||.*$/\1/p' | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
[ -n "$WL" ] && [ "$WL" = "$IL" ] || { echo "FAIL 14a (write list '$WL' != envpick import list '$IL')"; exit 1; }
for v in nixbadge_profile_default nixbadge_profile_boot nixbadge_profile_user; do
  case " $WL" in *" $v "*) ;; *) echo "FAIL 14a ($v not storable)"; exit 1 ;; esac
done
case " $WL" in *" nixbadge_args "*) echo "FAIL 14a (nixbadge_args storable)"; exit 1 ;; esac
#  14b. a stored copy (both redundant slots, as `env export -c` writes it) carrying the
#       given variables, imported by nixbadge_envpick, then btnsel with no button held.
stored() {
  out=$(run "$pre; $1; env export -c -s 0x20000 0x82000000 $2; cp.b 0x82000000 0x82020000 0x20000; setenv nixbadge_profile_default $PDEF; setenv nixbadge_args; run nixbadge_envpick; echo \"P=[\${nixbadge_args}]\"; btnsel; echo \"T=\${target}\"")
}
stored 'setenv nixbadge_profile_default desktop' nixbadge_profile_default
echo "$out" | grep -qxF 'btnsel: no button held -> desktop' && echo "$out" | grep -qxF 'T=desktop' || { echo "FAIL 14b (stored default=desktop): $out"; exit 1; }
stored "setenv nixbadge_profile_default '../x'" nixbadge_profile_default
echo "$out" | grep -qxF 'btnsel: $nixbadge_profile_default is not a profile name, using default' && echo "$out" | grep -qxF 'T=default' \
  || { echo "FAIL 14c (stored invalid name): $out"; exit 1; }
#  14d. a stored nixbadge_args is never imported (and btnsel clears it regardless)
stored 'setenv nixbadge_args nixbadge.reset=userdata' 'nixbadge_args BOOT_ORDER'
echo "$out" | grep -qxF 'P=[]' && echo "$out" | grep -qxF 'T=default' || { echo "FAIL 14d (stored nixbadge_args imported): $out"; exit 1; }
# 15. data cards: on an eMMC boot (mmc 1), a card in mmc 0 with BOOT and USERDATA
#     partitions and no NIX_A supplies boot.itb from its BOOT (vbmeta stays the
#     eMMC's) while its USERDATA has /.nixbadge-cardfit-<slot> and the eMMC's own FIT for
#     the slot has nixbadge-datacard, and nixbadge.cardfit=1 is appended; otherwise, or if
#     the card's FIT does not boot, the eMMC's FIT boots.
#  15a. the eMMC's FIT for slot A has nixbadge-datacard, so the card's boots
cardfile="setenv sb_files0 '/$CORE/slot-A/boot.itb /.nixbadge-cardfit-A'"
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 2:USERDATA'; $cardfile; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -q 'nixbadge: slot A boots the FIT on the data card' \
  && echo "$out" | grep -q '^bootargs=.* nixbadge.cardfit=1$' || { echo "FAIL 15a (data card FIT): $out"; exit 1; }
#  15b. the card has no FIT for the slot
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 2:USERDATA'; setenv sb_files0 /none; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15b (card without a FIT): $out"; exit 1; }
#  15c. the card has NIX_A (a boot card, not a data card)
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 3:NIX_A 5:USERDATA'; $cardfile; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15c (card with NIX_A): $out"; exit 1; }
#  15d. the card has no BOOT
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:USERDATA'; $cardfile; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15d (card without BOOT): $out"; exit 1; }
#  15e. an SD boot (mmc 0 is the boot card) never looks at another device
out=$(runf "$fit; setenv bootmedium 1; setenv mmcdev 0; setenv sb_files '$fitfiles'; setenv sb_parts1 '1:BOOT 2:USERDATA'; setenv sb_files1 '/$CORE/slot-A/boot.itb'; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15e (SD boot looked for a card): $out"; exit 1; }
#  15f. a factory reset keeps its token ahead of the card's
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_btn held; setenv sb_user held; setenv sb_parts0 '1:BOOT 2:USERDATA'; $cardfile; run nixbadge_boot")
echo "$out" | grep -q '^bootargs=.* nixbadge.reset=userdata nixbadge.cardfit=1$' || { echo "FAIL 15f (factory reset with a card): $out"; exit 1; }
#  15g. the card's FIT without its marker (the card's Nix layer for the slot was reset
#       since, or the card was formatted) is stale: the eMMC's FIT boots
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 2:USERDATA'; setenv sb_files0 '/$CORE/slot-A/boot.itb'; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15g (stale card FIT): $out"; exit 1; }
#  15h. the card's FIT loads but does not boot (tampered): the eMMC's own FIT for the
#       same slot boots, without the token, and the slot keeps its tries
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 2:USERDATA'; $cardfile; setenv sb_dir0 $FIX/tampered; run nixbadge_boot")
echo "$out" | grep -qx 'nixbadge: the FIT on the data card did not boot, trying the eMMC' \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && echo "$out" | grep -qx 'BOOT_A_LEFT=2' \
  && ! echo "$out" | grep -q 'nixbadge.cardfit=1' || { echo "FAIL 15h (bad card FIT): $out"; exit 1; }
#  15i. the eMMC's FIT lacks nixbadge-datacard (the system has data cards off): the card's
#       FIT is not looked at
out=$(runf "$fit; setenv sb_files '$fitfiles'; setenv sb_parts0 '1:BOOT 2:USERDATA'; $cardfile; setenv sb_dir1 $FIX/nodatacard; run nixbadge_boot")
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=A' && ! echo "$out" | grep -q 'nixbadge.cardfit=1' \
  && ! echo "$out" | grep -q 'FIT on the data card' || { echo "FAIL 15i (data cards off): $out"; exit 1; }
echo PASS
