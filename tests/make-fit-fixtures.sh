#!/bin/sh
# Builds the signed-FIT fixtures tests/hush-rauc-walk.sh boots in the U-Boot sandbox,
# into tests/fixtures/fit/out/ (gitignored). Everything secret is generated here, at
# test time, and never committed: a scratch RSA-2048 keypair + self-signed cert (the
# "good" key, which the sandbox control DTB trusts) and a second, unrelated one (the
# "other" key, for the bad-signature case). The checked-in tests/fixtures/fit-dev.crt
# is not used: no private key for it is available to sign with.
#
#   sh tests/make-fit-fixtures.sh
#
# Needs mkimage, fdt_add_pubkey (ubootTools), dtc and openssl; re-runs itself under
# `nix shell` with this flake's pinned nixpkgs when any is missing.
#
# Output (tests/fixtures/fit/out/):
#   control.dtb          sandbox control DTB: an empty tree plus the two key nodes,
#                        built exactly like pkgs/uboot-common/fit-key-dtb.nix does
#                        (fdt_add_pubkey, key-sg1-image required = "conf",
#                        key-sg1-image-img required = "image"); pass with `u-boot -d`
#   <case>/<core>/slot-<A|B>/{vbmeta,boot}.itb, for core arm and riscv, where <case>:
#     good       both slots signed with the good key
#     badsig     slot A's boot.itb signed with the other key; slot B good
#     tampered   slot A's boot.itb with one byte of kernel data flipped after
#                signing; slot B good
#     profilefail  slot A's boot.itb with conf-desktop signed by the other key
#                (everything else good), so script-desktop runs and its bootm
#                returns; slot B good
#     noverity   slot A's vbmeta.itb is validly signed but its frag sets no
#                verityargs; slot B good
#     nodatacard slot A's boot.itb lacks nixbadge-datacard (data cards off); slot B good
#   and in every case /.nixbadge-cardfit-A and -B, a data card's USERDATA markers
set -eu
here=$(cd "$(dirname "$0")" && pwd)
for t in mkimage fdt_add_pubkey dtc openssl; do
  command -v "$t" >/dev/null || exec nix shell --inputs-from "path:$here/.." \
    nixpkgs#ubootTools nixpkgs#dtc nixpkgs#openssl -c sh "$0" "$@"
done
src=$here/fixtures/fit
out=$src/out
rm -rf "$out"
mkdir -p "$out/build"

# One keypair per key set, copied under both key-name-hints (sg1-image signs the
# configurations, sg1-image-img the images): the same split as the production key,
# whose one certificate becomes both key nodes.
mkkeys() {
  mkdir -p "$out/$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=nix-badge test $1" \
    -keyout "$out/$1/sg1-image.key" -out "$out/$1/sg1-image.crt" 2>/dev/null
  cp "$out/$1/sg1-image.key" "$out/$1/sg1-image-img.key"
  cp "$out/$1/sg1-image.crt" "$out/$1/sg1-image-img.crt"
}
mkkeys keys
mkkeys other-keys

echo '/dts-v1/; / { };' | dtc -I dts -O dtb -p 4096 -o "$out/control.dtb"
fdt_add_pubkey -a sha256,rsa2048 -k "$out/keys" -n sg1-image -r conf "$out/control.dtb"
fdt_add_pubkey -a sha256,rsa2048 -k "$out/keys" -n sg1-image-img -r image "$out/control.dtb"

# FIT inputs next to the .its files (dtc resolves /incbin/ relative to the cwd).
cp "$src"/vbmeta.its "$src"/boot.its "$out/build/"
# The scripts lose their trailing newline: U-Boot 2021.10 hush returns the status of
# the last statement it parsed, and a final newline adds an empty one (status 0), so
# a script ending "false\n" returns 0. Without it the profile scripts' closing
# `false` is what `source` returns when their bootm comes back.
for f in "$src"/*.txt; do printf %s "$(cat "$f")" > "$out/build/${f##*/}"; done
cd "$out/build"
# 64 KiB dummy kernel: a recognisable marker repeated, so the tampered case can find
# the kernel data inside the .itb.
yes NIXBADGE-FIXTURE-KERNEL | head -c 65536 > kernel.bin
echo '/dts-v1/; / { compatible = "nix-badge,fixture"; };' | dtc -I dts -O dtb -o fdt.dtb

sign() { mkimage -f "$1" -k "$out/$2" -r "$3" >/dev/null; }
sign vbmeta.its keys vbmeta.itb
sign boot.its keys boot.itb
sign boot.its other-keys boot-othersig.itb
# without nixbadge-datacard: a system with data cards off
sed '/nixbadge-datacard/d' boot.its > boot-nodatacard.its
sign boot-nodatacard.its keys boot-nodatacard.itb
cp boot.itb boot-tampered.itb
off=$(grep -abo -m1 NIXBADGE-FIXTURE-KERNEL boot-tampered.itb | head -n1 | cut -d: -f1)
[ -n "$off" ] || { echo "kernel marker not found in boot.itb" >&2; exit 1; }
printf X | dd of=boot-tampered.itb bs=1 seek=$((off + 100)) conv=notrunc 2>/dev/null
cmp -s boot.itb boot-tampered.itb && { echo "tamper did not change boot.itb" >&2; exit 1; }
# conf-desktop signed by the other key: the second sg1-image hint in boot.its is
# conf-desktop's (images use sg1-image-img); it becomes sg1-other, signed with the
# other key copied in under that name next to the good ones.
mkdir -p "$out/mixed-keys"
cp "$out"/keys/* "$out/mixed-keys/"
cp "$out/other-keys/sg1-image.key" "$out/mixed-keys/sg1-other.key"
cp "$out/other-keys/sg1-image.crt" "$out/mixed-keys/sg1-other.crt"
awk '/key-name-hint = "sg1-image";/ && ++n == 2 { sub(/sg1-image/, "sg1-other") } { print }' boot.its > boot-profilefail.its
grep -q sg1-other boot-profilefail.its || { echo "conf-desktop hint not rewritten" >&2; exit 1; }
sign boot-profilefail.its mixed-keys boot-profilefail.itb
# a vbmeta whose (validly signed) frag sets no verityargs
printf %s 'echo nixbadge fixture: this frag sets no verityargs' > vbmeta-noverity.txt
sed 's/vbmeta-frag\.txt/vbmeta-noverity.txt/' vbmeta.its > vbmeta-noverity.its
sign vbmeta-noverity.its keys vbmeta-noverity.itb

# <case> <slot-A boot.itb> [<slot-A vbmeta.itb>]; slot B always gets the good ones.
mkcase() {
  for core in arm riscv; do
    for s in A B; do
      d=$out/$1/$core/slot-$s
      mkdir -p "$d"
      if [ "$s" = A ]; then cp "${3:-vbmeta.itb}" "$d/vbmeta.itb"; else cp vbmeta.itb "$d/vbmeta.itb"; fi
      if [ "$s" = A ]; then cp "$2" "$d/boot.itb"; else cp boot.itb "$d/boot.itb"; fi
    done
  done
}
mkcase good boot.itb
mkcase badsig boot-othersig.itb
mkcase tampered boot-tampered.itb
mkcase profilefail boot-profilefail.itb
mkcase noverity boot.itb vbmeta-noverity.itb
mkcase nodatacard boot-nodatacard.itb
# A data card's USERDATA marks the slots whose card FIT is current (badgeos's installer
# writes the marker, stage 0 removes it when the card's Nix layer for the slot goes).
for c in good badsig tampered profilefail noverity nodatacard; do
  for s in A B; do printf 'card generation %s\n' "$s" > "$out/$c/.nixbadge-cardfit-$s"; done
done
echo "fixtures in $out"
