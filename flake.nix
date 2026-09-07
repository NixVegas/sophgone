{
  description = "one file, two architectures, zero secure boot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    autopen = {
      url = "git+ssh://forgejo@git.nixos.lv/NixSec/autopen.git?ref=hardware-signing-experiments";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkcs = {
      url = "github:numinit/nixpkcs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      autopen,
      nixpkcs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Raw package functions: the public API. badgeos consumes these with its own
      # nixpkgs (`pkgs.callPackage sophgone.lib.<name> { ... }`), so they stay as
      # uncalled functions. Each lives in its own ./pkgs/<name>/package.nix; the
      # called view for this repo comes from packagesFromDirectoryRecursive below.
      lib = {
        # benign FIP generation
        fip = import ./pkgs/fip/package.nix; # { core ? "arm", dumpRom ? false, dtb ? null }
        fipPolyglot = import ./pkgs/fip-polyglot/package.nix; # { dtb ? null, secureBoot ? false }
        fsbl = import ./pkgs/fsbl/package.nix; # { core ? "arm", dumpRom ? false, slot ? "primary" }
        bl31Blob = import ./pkgs/bl31-blob/package.nix;
        opensbi = import ./pkgs/opensbi/package.nix; # { dtb ? null }
        ubootArm = import ./pkgs/uboot-arm/package.nix;
        ubootRiscv = import ./pkgs/uboot-riscv/package.nix;
        mergeBl2 = import ./pkgs/merge-bl2/package.nix;

        # overflowBl2: oversized BL2 whose unbounded BL2_IMG_SIZE overruns the mask
        #   ROM stack. variant "polyglot"|"a53"|"c906".
        # chainloadFip: full malicious fip.bin (real MONITOR/LOADER_2ND, only the BL2
        #   slot swapped for overflowBl2); written to SD as fip.bin, paired with
        #   fipPolyglot as sophg.1.
        overflowBl2 = import ./pkgs/overflow-bl2/package.nix; # { variant ? "polyglot" }
        chainloadFip = import ./pkgs/chainload/package.nix; # { variant ? "polyglot", dtb ? null }

        # signFip: Route B, sg1-sb signs a FIP via the autopen daemon; emits the
        #   signed fip.bin + KPUB_HASH. { fip, blCert?, rootCert?, blPkSig?, ... }
        # blPkSigCeremony: offline sg1-root ceremony producing bl_pk_sig.bin.
        signFip = import ./pkgs/fip-sign/package.nix;
        blPkSigCeremony = import ./pkgs/bl-pk-sig-ceremony/package.nix;
        # deriveFwKey: deterministic per-serial AES key via the sg1-enc PRF.
        deriveFwKey = import ./pkgs/derive-fw-key/package.nix;
        # fuseMap: per-serial efuse provisioning plan from KPUB_HASH + ldr_ek.
        fuseMap = import ./pkgs/fuse-map/package.nix;
        # graftFip: locked-cart exploit, reuse a genuine signed(+enc) header and swap
        #   only BL2 for the plaintext overflow blob (keyless). { signedFip, overflowBl2 }
        graftFip = import ./pkgs/graft-fip/package.nix;
      };
    in
    {
      inherit lib;

      # nixpkcs declares the SG1 secure-boot keypairs (the in-repo source of truth);
      # a signing host imports it and provides the TPM + PINs.
      nixosModules.nixpkcs = ./modules/nixpkcs.nix;

      packages = forAllSystems (
        system:
        let
          # The autopen + nixpkcs overlays give us autopen.pkcs11Module,
          # openssl.withPkcs11Module and pkcs11-provider for the Route-B fip-sign.
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              autopen.overlays.default
              nixpkcs.overlays.default
            ];
          };
          inherit (pkgs) callPackage;

          # Called package set, auto-discovered from ./pkgs/<name>/package.nix (default
          # args). Simple packages come straight from here; variants use .override; the
          # parametric ones (signFip/graftFip/deriveFwKey/fuseMap) are callPackage'd
          # with their required derivation args below.
          firmware = pkgs.lib.packagesFromDirectoryRecursive {
            inherit (pkgs) callPackage;
            directory = ./pkgs;
          };

          # Firmware keys for badge #1.
          fwBlEk = callPackage lib.deriveFwKey {
            domain = "SG1-FWENC-v1";
            serial = "SG1-0001";
            name = "sg1-bl-ek-SG1-0001";
          };
          fwLdrEk = callPackage lib.deriveFwKey {
            domain = "SG1-LDRKEK-v1";
            serial = "SG1-0001";
            name = "sg1-ldr-ek-SG1-0001";
          };

          signedEncFipArm = callPackage lib.signFip {
            fip = firmware.fip;
            encrypt = true;
            blEk = fwBlEk;
            ldrEk = fwLdrEk;
          };
          signedEncFipRiscv = callPackage lib.signFip {
            fip = firmware.fip.override { core = "riscv"; };
            encrypt = true;
            blEk = fwBlEk;
            ldrEk = fwLdrEk;
          };

          fipPolyglotSecure = firmware.fip-polyglot.override { secureBoot = true; };
          signedFipPolyglotStub = callPackage lib.signFip { fip = firmware.fip-polyglot; };
          signedEncFipPolyglotStub = callPackage lib.signFip {
            fip = firmware.fip-polyglot;
            encrypt = true;
            blEk = fwBlEk;
            ldrEk = fwLdrEk;
          };
          signedFipPolyglotSecure = callPackage lib.signFip { fip = fipPolyglotSecure; };
          signedEncFipPolyglotSecure = callPackage lib.signFip {
            fip = fipPolyglotSecure;
            encrypt = true;
            blEk = fwBlEk;
            ldrEk = fwLdrEk;
          };
          overflowBl2Polyglot = firmware.overflow-bl2;
        in
        {
          # normal FIPs
          fip-polyglot = firmware.fip-polyglot;
          fip-arm = firmware.fip;
          fip-riscv = firmware.fip.override { core = "riscv"; };

          # exploit FIPs (not grafted off a signed fip, so don't work with secure boot)
          chainload-fip = firmware.chainload;
          sophg1 = firmware.fip-polyglot;

          # example overflows (also don't work with secure boot)
          overflow-bl2-polyglot = firmware.overflow-bl2;
          overflow-bl2-a53 = firmware.overflow-bl2.override { variant = "a53"; };
          overflow-bl2-c906 = firmware.overflow-bl2.override { variant = "c906"; };

          # signed FIPs
          signed-fip-arm = callPackage lib.signFip { fip = firmware.fip; };
          signed-fip-riscv = callPackage lib.signFip { fip = firmware.fip.override { core = "riscv"; }; };
          signed-fip-polyglot = signedFipPolyglotSecure;

          # signed(/encrypted) grafted chainloader FIPs. The final exploits for badge #1.
          chainload-fip-locked-signed = callPackage lib.graftFip {
            signedFip = signedFipPolyglotStub;
            overflowBl2 = overflowBl2Polyglot;
          };
          chainload-fip-locked-enc = callPackage lib.graftFip {
            signedFip = signedEncFipPolyglotStub;
            overflowBl2 = overflowBl2Polyglot;
          };

          # Signs the BL_PK using the root key:
          # `nix run .#bl-pk-sig-ceremony -- pkgs/fip-sign/bl_pk_sig.bin`
          bl-pk-sig-ceremony = firmware.bl-pk-sig-ceremony;

          # deterministic per-serial firmware keys and the signed+encrypted FIPs.
          fw-bl-ek = fwBlEk;
          fw-ldr-ek = fwLdrEk;
          signed-enc-fip-arm = signedEncFipArm;
          signed-enc-fip-riscv = signedEncFipRiscv;
          signed-enc-fip-polyglot = signedEncFipPolyglotSecure;

          # per-serial efuse provisioning plan, for badge #1
          fuse-plan = callPackage lib.fuseMap {
            serial = "SG1-0001";
            signedFip = signedEncFipArm;
            ldrEk = fwLdrEk;
            encrypt = true;
          };

          # should work on anything that's not secure booted
          default = firmware.chainload;
        }
      );
    };
}
