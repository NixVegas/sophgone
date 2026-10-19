# The U-Boot control DTB with the sg1-image FIT public keys added, for the secure
# U-Boot (pkgs/uboot-{arm,riscv}/package.nix passes $out/control.dtb as EXT_DTB,
# which dts/Makefile embeds instead of compiling the in-tree DTS).
#
# A key node has exactly one `required` value, so the same key goes in twice:
# key-sg1-image (required = "conf") and key-sg1-image-img (required = "image").
# fdt_add_pubkey reads <keydir>/<name>.crt, hence the two copies. Only the
# certificate is needed; the private key never enters a build.
#
# The control DTS must stay self-contained (no #include, no cpp macros): this
# compiles it with plain dtc, while the plain build runs cpp+dtc over the same
# file, so preprocessor use would build there and break or differ here.
#
# Usage: (callPackage ./fit-key-dtb.nix { }) { controlDts, fitKeyCert }
{
  runCommand,
  dtc,
  ubootTools,
}:
{ controlDts, fitKeyCert }:
runCommand "uboot-control-dtb-sg1-image"
  {
    nativeBuildInputs = [
      dtc
      ubootTools
    ];
  }
  ''
    dtc -I dts -O dtb -o control.dtb ${controlDts}

    mkdir keys
    cp ${fitKeyCert} keys/sg1-image.crt
    cp ${fitKeyCert} keys/sg1-image-img.crt
    fdt_add_pubkey -a sha256,rsa2048 -k keys -n sg1-image -r conf control.dtb
    fdt_add_pubkey -a sha256,rsa2048 -k keys -n sg1-image-img -r image control.dtb

    mkdir -p $out
    install -m 0444 control.dtb $out/control.dtb
    install -m 0444 control.dtb $out/u-boot.dtb
  ''
