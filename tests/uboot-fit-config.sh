#!/bin/sh
# Checks that a plain/secure pair of U-Boot builds (pkgs/uboot-{arm,riscv}) has the
# FIT feature split verified boot relies on. Run once per core:
#
#   nix shell nixpkgs#dtc -c sh tests/uboot-fit-config.sh result-uboot-arm result-uboot-arm-secure
#
# both:   `fdt` linked (do_fdt: nixbadge_fit tells an absent profile script from a
#         failed one with `fdt addr` + `fdt get`), bootm's gzip path (gunzip,
#         image_decomp: badgeos' boot.itb carries a gzip-compressed kernel), and
#         nixbadge_fuse (the board identity, cvi-fuse-cmd.c).
# plain:  FIT parsing linked (fit_image_verify), NO RSA verifier, extlinux boot kept
#         (do_sysboot, do_booti).
# secure: RSA + required-signature check linked, no sysboot/booti/pxe, no legacy
#         (unsigned) image format, the commands nixbadge_fit runs (load, source,
#         bootm) and nixbadge_halt linked (absent in plain), no autoboot stop
#         prompt, bootdelay=-2 in the default env, no env string that references
#         sysboot, and the embedded control DTB carries the two sg1-image key nodes
#         (one required = "conf", one required = "image"), both sha256,rsa2048.
#
# Symbols come from the linker map (u-boot.map), strings from u-boot-raw.bin, the
# DTB from u-boot.dtb (the embedded dts/dt.dtb), all installed by the packages.
# Needs fdtget (dtc) on PATH. Prints PASS, or every FAIL line and exits nonzero.
set -eu
PLAIN=$1; SECURE=$2
command -v fdtget >/dev/null || { echo "fdtget not on PATH (nix shell nixpkgs#dtc)" >&2; exit 2; }
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# A function is linked if the map lists it as a symbol line ("0x... name") or as its
# own -ffunction-sections input section (".text.name"). Only the part after "Linker
# script and memory map" counts: the "Discarded input sections" list before it names
# functions --gc-sections threw away.
linked() {
  [ -f "$1/u-boot.map" ] || return 1
  sed -n '/^Linker script and memory map/,$p' "$1/u-boot.map" |
    grep -Eq "(^|[[:space:]])(\.text\.)?$2([[:space:]]|$)"
}
want() { linked "$1" "$2" || fail "$1: $2 not linked"; }
reject() { if linked "$1" "$2"; then fail "$1: $2 linked"; fi; }
prop() {
  got=$(fdtget "$1/u-boot.dtb" "$2" "$3" 2>&1) || got="<missing: $got>"
  [ "$got" = "$4" ] || fail "$1/u-boot.dtb $2 $3 = '$got', want '$4'"
}
# the default environment's "name=value" strings (NUL-separated in the binary)
envstr() { tr '\0' '\n' < "$1/u-boot-raw.bin" | grep -a '^[A-Za-z0-9_]*='; }

[ -f "$PLAIN/u-boot.map" ] || fail "$PLAIN/u-boot.map missing"
[ -f "$SECURE/u-boot.map" ] || fail "$SECURE/u-boot.map missing"

for b in "$PLAIN" "$SECURE"; do
  want "$b" do_fdt
  want "$b" gunzip
  want "$b" image_decomp
  # nixbadge_fuseonce's command (cvi-fuse-cmd.c) and the reset after it
  want "$b" do_nixbadge_fuse
  want "$b" do_reset
done
# trng/devek exist only on riscv (the arm U-Boot cannot reach the TRNG)
case "$PLAIN" in
  *riscv*) for b in "$PLAIN" "$SECURE"; do want "$b" do_devek; want "$b" do_trng; done ;;
  *) for b in "$PLAIN" "$SECURE"; do reject "$b" do_devek; reject "$b" do_trng; done ;;
esac

want "$PLAIN" fit_image_verify
reject "$PLAIN" rsa_verify
reject "$PLAIN" fit_config_verify
want "$PLAIN" do_sysboot
want "$PLAIN" do_booti
# legacy-image header check: linked only with LEGACY_IMAGE_FORMAT, which
# FIT_SIGNATURE turns off. (image_get_kernel, the obvious name, is static and
# inlined into its one caller, so it never shows in the map in either build.)
want "$PLAIN" image_check_hcrc

want "$SECURE" rsa_verify
# fit_config_verify_required_sigs (common/image-fit-sig.c) is static with a single
# caller, so GCC inlines it into fit_config_verify and it never reaches the map or
# the symbol table. fit_config_verify is that wrapper (its whole body is the call),
# and only exists with FIT_SIGNATURE; fit_image_verify_required_sigs is the
# image-level counterpart (required = "image").
want "$SECURE" fit_config_verify
want "$SECURE" fit_image_verify_required_sigs
reject "$SECURE" do_sysboot
reject "$SECURE" do_booti
reject "$SECURE" do_pxe
reject "$SECURE" image_check_hcrc
want "$SECURE" do_load_wrapper
want "$SECURE" do_source
want "$SECURE" do_bootm
# the secure walk ends in nixbadge_halt (cvi-halt-cmd.c, CONFIG_FIT_SIGNATURE only)
want "$SECURE" do_nixbadge_halt
reject "$PLAIN" do_nixbadge_halt
if [ ! -f "$SECURE/u-boot-raw.bin" ]; then
  fail "$SECURE/u-boot-raw.bin missing"
else
  for s in 'Press ENTER within' 'Hit any key to stop autoboot'; do
    if grep -aq "$s" "$SECURE/u-boot-raw.bin"; then fail "$SECURE: autoboot stop prompt '$s' present"; fi
  done
  envstr "$SECURE" | grep -qx 'bootdelay=-2' || fail "$SECURE: default env has no bootdelay=-2"
  if envstr "$SECURE" | grep -q sysboot; then
    fail "$SECURE: an env string references sysboot: $(envstr "$SECURE" | grep sysboot | head -n1 | cut -c1-80)"
  fi
  envstr "$SECURE" | grep -qx 'nixbadge_legacy=echo nixbadge: no slot booted; nixbadge_halt' || fail "$SECURE: nixbadge_legacy does not report and halt"
fi
# the same env check must see sysboot in the plain build, or it proves nothing
[ -f "$PLAIN/u-boot-raw.bin" ] && envstr "$PLAIN" | grep -q sysboot || fail "$PLAIN: no env string references sysboot (legacy tail missing?)"

if [ -f "$SECURE/u-boot.dtb" ]; then
  prop "$SECURE" /signature/key-sg1-image required conf
  prop "$SECURE" /signature/key-sg1-image-img required image
  prop "$SECURE" /signature/key-sg1-image algo sha256,rsa2048
  prop "$SECURE" /signature/key-sg1-image-img algo sha256,rsa2048
else
  fail "$SECURE/u-boot.dtb missing"
fi

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo PASS
