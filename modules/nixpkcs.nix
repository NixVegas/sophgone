# Declarative nixpkcs keypairs for the SG1 (SG2000 device #1) secure-boot chain:
# the in-repo source of truth for the four RSA-2048 keys. Import into the signing
# host's NixOS config (which must import nixpkcs and its overlay and provide a TPM
# + SO/user PIN files):
#
#   imports = [ inputs.nixpkcs.nixosModules.default ./keys.nix ];
#   security.pkcs11 = { enable = true; tpm2.enable = true; };
#
# Keys never leave the TPM; certOptions.writeTo exports each self-signed cert
# (public) to /etc/nixpkcs. Chain: root_pk(sg1-root) -> bl_pk(sg1-sb); sg1-enc is
# the deterministic-firmware-key KDF key (sign-only); sg1-attest is a separate
# attestation root.
{ pkgs, ... }:

let
  # The TPM PKCS#11 module (nixpkcs adds `.pkcs11Module`). Swap to `.abrmd` if the
  # host reaches the TPM through tpm2-abrmd rather than /dev/tpmrm0.
  tpmModule = pkgs.tpm2-pkcs11.pkcs11Module;
  # Owner-only (0600) PIN file; nixpkcs uses it for both SO and user here.
  pinFile = "/etc/nixpkcs/tpm2.user.pin";
  certDir = "/etc/nixpkcs";

  subjectBase = "C=US/ST=California/L=Carlsbad/O=Nix Vegas/OU=Keymaster";

  # Extensions for a leaf code-signing cert (sg1-sb / sg1-enc).
  leafExtensions = [
    "basicConstraints=critical,CA:FALSE"
    "keyUsage=critical,nonRepudiation,digitalSignature"
    "extendedKeyUsage=critical,codeSigning"
    "subjectKeyIdentifier=hash"
    "authorityKeyIdentifier=keyid:always"
  ];

  # Extensions for a CA/root cert (sg1-root / sg1-attest).
  caExtensions = [
    "v3_ca"
    "keyUsage=critical,nonRepudiation,keyCertSign,digitalSignature,cRLSign"
  ];

  mkKey =
    name:
    {
      id,
      cn,
      extensions,
    }:
    {
      pkcs11Module = tpmModule;
      token = "nixpkcs";
      inherit id;

      keyOptions = {
        algorithm = "RSA";
        type = "2048";
        usage = [ "sign" ];
        soPinFile = pinFile;
        loginAsUser = true;
      };

      certOptions = {
        digest = "SHA256";
        subject = "${subjectBase}/CN=${cn}";
        inherit extensions;
        pinFile = pinFile;
        validityDays = 1825;
        renewalPeriod = -1;
        writeTo = "${certDir}/${name}.crt";
      };
    };
in
{
  security.pkcs11.keypairs = pkgs.lib.mapAttrs mkKey {
    # root_pk: its SHA-256 is fused as KPUB_HASH; signs bl_pk (cold ceremony).
    sg1-root = {
      id = 15;
      cn = "SG1 Root";
      extensions = caExtensions;
    };

    # bl_pk: the working image signer (chip_conf / BL2 / BLCP / MONITOR / …).
    sg1-sb = {
      id = 16;
      cn = "SG1 Secure Boot";
      extensions = leafExtensions;
    };

    # Image-encryption KDF key: sign-only deterministic PKCS#1 v1.5 PRF for bl_ek.
    sg1-enc = {
      id = 17;
      cn = "SG1 Image Encryption";
      extensions = leafExtensions;
    };

    # Attestation root: its own hierarchy, signs device attestation certs.
    sg1-attest = {
      id = 18;
      cn = "SG1 Attestation Root";
      extensions = caExtensions;
    };
  };
}
