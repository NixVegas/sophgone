# Offline root ceremony: sg1-root signs bl_pk (sg1-sb's modulus), producing the
# committed BL_PK_SIG that fip-sign embeds. sg1-root is cold (not on the autopen
# daemon), so this is not a sandboxed build; the signature is made on the host
# that holds the token. The derivation produces the script; running it is the
# ceremony:
#
#   nix run .#bl-pk-sig-ceremony -- pkgs/fip-sign/bl_pk_sig.bin
#   git add pkgs/fip-sign/bl_pk_sig.bin
#
# Host needs sg1-root on its token, `nixpkcs-uri` on PATH, and OpenSSL's
# pkcs11-provider loaded system-wide.
{
  writeShellApplication,
  writeText,
  openssl,
  tpm2-pkcs11,
  python3,
  coreutils,

  # sg1-sb's public cert -> bl_pk. The nixpkcs key name for the cold root key.
  sbCert ? ../fip-sign/sg1-sb.crt,
  rootKeyName ? "sg1-root",
  pkcs11Module ? tpm2-pkcs11.pkcs11Module,
}:

let
  # Extract a cert's RSA modulus as 256 raw big-endian bytes (== the FIP BL_PK).
  extractModulus = writeText "extract-modulus.py" ''
    import sys
    from cryptography import x509
    n = x509.load_pem_x509_certificate(open(sys.argv[1], "rb").read()).public_key().public_numbers().n
    assert n.bit_length() <= 2048, n.bit_length()
    open(sys.argv[2], "wb").write(n.to_bytes(256, "big"))
  '';
  py = python3.withPackages (p: [ p.cryptography ]);
in
writeShellApplication {
  name = "sg1-bl-pk-sig-ceremony";
  runtimeInputs = [
    (openssl.withPkcs11Module { inherit pkcs11Module; })
    coreutils
    py
  ];
  text = ''
    out="''${1:-bl_pk_sig.bin}"
    root_uri="$(nixpkcs-uri ${rootKeyName})"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # bl_pk = sg1-sb's 256-byte modulus.
    python3 -P ${extractModulus} ${sbCert} "$tmp/bl_pk.bin"
    [ "$(stat -c%s "$tmp/bl_pk.bin")" = 256 ]

    # sg1-root signs SHA-256(bl_pk) with PKCS#1 v1.5, what the ROM's "verify
    # bl_pk" step checks.
    openssl dgst -sha256 -sign "$root_uri" -out "$out" "$tmp/bl_pk.bin"
    [ "$(stat -c%s "$out")" = 256 ]

    echo "wrote $out ($(stat -c%s "$out") bytes)."
    echo "commit it as sophgone/pkgs/fip-sign/bl_pk_sig.bin, then fip-sign"
    echo "will embed it (pass blPkSig = ./bl_pk_sig.bin)."
  '';
}
