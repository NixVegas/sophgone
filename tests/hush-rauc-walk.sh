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
#   sb_btn    "held" = BOOT held for the real btnsel's sample window
#   sb_user   "held" = USER held for the real btnsel's sample window (both held: USER wins)
# A bootm that reaches the kernel hand-off likewise prints "BOOTED bootm" plus the
# sb_show values and exits. Control flow only.
#
# The FIT cases (8, 9, 11) need the signed fixtures and the sandbox control DTB that
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
VBADDR=$(var vbaddr); LOADADDR=$(var loadaddr); SECLEGACY=$(var nixbadge_legacy secure)
[ -n "$SLOT" ] && [ -n "$PICK" ] && [ -n "$BOOT" ] && [ -n "$TRY" ] && [ -n "$WALK" ] && [ -n "$LEGACY" ] && [ -n "$CORE" ] \
  && [ -n "$FIT" ] && [ -n "$VBADDR" ] && [ -n "$LOADADDR" ] && [ -n "$SECLEGACY" ] \
  || { echo "could not extract env strings from $ENVFILE" >&2; exit 1; }
# btnsel's desktop and video confs are compiled in per core; the sandbox binary carries the arm ones
# (pkgs/uboot-sandbox/package.nix), whichever core is under test.
BTNCORE=arm
# timeout: a sandbox that ever reaches `reset` relaunches itself forever
run() { timeout 60 "$UB" -c "$1" 2>&1 | tr -d '\r'; }
# same, with the control DTB that carries the fixtures' public key (FIT cases)
runf() { timeout 60 "$UB" -d "$FIX/control.dtb" -c "$1" 2>&1 | tr -d '\r'; }
pre="setenv nixbadge_slot '$SLOT'; setenv nixbadge_envpick '$PICK'; setenv nixbadge_boot '$BOOT'; setenv nixbadge_try '$TRY'; setenv nixbadge_walk '$WALK'; setenv nixbadge_legacy '$LEGACY'; setenv nixbadge_fit '$FIT'; setenv core $CORE; setenv scriptaddr 0x1000; setenv vbaddr $VBADDR; setenv loadaddr $LOADADDR"
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
#  7k. BOOT and USER both held -> USER wins (video).
out=$(run "$mbrv; setenv sb_btn held; setenv sb_user held; run nixbadge_boot")
echo "$out" | grep -qx "BOOTED /$BTNCORE/extlinux/extlinux-video.conf" || { echo "FAIL 7k (both held did not boot the video conf): $out"; exit 1; }
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
echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A rauc.external nixbadge.profile=default' || { echo "FAIL 8d (SD boot: $out)"; exit 1; }
#  8e. BOOT held on slot B -> target desktop: script-desktop boots conf-desktop
out=$(runf "$fit; setenv sb_btn held; setenv BOOT_ORDER 'B A'; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'btnsel: target desktop' && echo "$out" | grep -q "Using 'conf-desktop' configuration" && echo "$out" | grep -qx 'BOOTED bootm' \
  && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'nixroot=sbuuid-4' && echo "$out" | grep -qx 'target=desktop' \
  || { echo "FAIL 8e (gpt BOOT held: $out)"; exit 1; }
#  8f. both held -> USER wins: target video (this boot.itb has no script-video, so the
#      default profile boots; 11b covers that fallback)
out=$(runf "$fit; setenv sb_btn held; setenv sb_user held; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -qx 'btnsel: target video' && echo "$out" | grep -qx 'target=video' && echo "$out" | grep -qx 'rauc_slot=A' || { echo "FAIL 8f (gpt both held: $out)"; exit 1; }
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
  && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A  nixbadge.profile=default' || { echo "FAIL 11a (boot): $out"; exit 1; }
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
  && echo "$out" | grep -qx 'bootargs=nixbadge.fixture.verity=sg1 rauc.slot=A  nixbadge.profile=default' || { echo "FAIL 11g (profile script returned): $out"; exit 1; }
#  11h. slot A's vbmeta is validly signed but sets no verityargs -> the
#       test -n "${verityargs}" gate stops slot A before its boot.itb is even loaded;
#       A is marked bad and B boots.
out=$(runf "$fit; setenv sb_dir $FIX/noverity; setenv sb_files '$fitfiles'; run nixbadge_boot")
echo "$out" | grep -q 'nixbadge fixture: this frag sets no verityargs$' \
  && echo "$out" | grep -qx 'nixbadge: slot A did not boot, marking it bad and trying the other' \
  && [ "$(echo "$out" | grep -c '^## Executing script at 8a000000')" = 1 ] \
  && echo "$out" | grep -qx 'BOOTED bootm' && echo "$out" | grep -qx 'rauc_slot=B' && echo "$out" | grep -qx 'BOOT_A_LEFT=0' || { echo "FAIL 11h (no verityargs): $out"; exit 1; }
echo PASS
