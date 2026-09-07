# Deterministic firmware key derivation for the SG2000 encrypted-boot chain.
#
#   key = HKDF-SHA256( TPM_sign_pkcs1v15(sg1-enc, domain || 0x00 || serial) )[:keyBytes]
#
# Output is a raw keyBytes-long key file. See fip-sign.nix (encrypt = true).
{
  runCommand,
  writeText,
  python3,
  openssl,
  autopen,

  domain,
  serial,
  name ? "sg1-fw-key",
  keyBytes ? 16, # AES-128
  encCert ? ./sg1-enc.crt,
  # SRI content hash of sg1-enc's autopen verification key (deterministic per
  # cert). Makes fromCertificate a fixed-output derivation so the remote handle
  # needs no IFD. Recompute if encCert changes: `nix hash file` on the output of
  # `verificationKey.fromCertificate encCert`.
  encCertHash ? "sha256-0MkAE/7ImX2Z+o/4zDEozhemdYeilwuO8pHrj3TPkv0=",
  encSigningKey ? autopen.lib.signingKey.remote {
    name = "sg1-enc";
    verificationKey = autopen.lib.verificationKey.fromCertificate {
      source = encCert;
      hash = encCertHash;
    };
    socketPath = "/run/autopen/socket";
  },
}:

let
  encUri = "pkcs11:object=sg1-enc;type=private?module-path=${autopen.pkcs11Module.path}";

  # Standalone cert copy for the shim's AUTOPEN_CERT (see fip-sign.nix rationale).
  encCertFile = builtins.path {
    path = encCert;
    name = "sg1-enc.crt";
  };

  opensslProvider = openssl.withPkcs11Module {
    pkcs11Module = autopen.pkcs11Module;
    moduleEnv = {
      remoteKey = encSigningKey;
      cert = encCertFile;
      label = "sg1-enc";
    };
  };

  py = python3.withPackages (p: [ p.cryptography ]);

  mkMsg = writeText "fw-key-msg.py" ''
    import sys
    domain, serial, out = sys.argv[1], sys.argv[2], sys.argv[3]
    # domain-separated, serial-keyed PRF input: domain || 0x00 || serial
    open(out, "wb").write(domain.encode() + b"\0" + serial.encode())
  '';

  mkHkdf = writeText "fw-key-hkdf.py" ''
    import sys
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    sig = open(sys.argv[1], "rb").read()
    domain, n, out = sys.argv[2], int(sys.argv[3]), sys.argv[4]
    key = HKDF(algorithm=hashes.SHA256(), length=n, salt=None, info=domain.encode()).derive(sig)
    open(out, "wb").write(key)
  '';
in
runCommand name
  {
    nativeBuildInputs = [ opensslProvider py ];
    preferLocalBuild = true;
    allowSubstitutes = false;
    requiredSystemFeatures = [ "autopen" ];
    passthru = { inherit domain serial keyBytes; };
  }
  ''
    python3 -P ${mkMsg} '${domain}' '${serial}' msg.bin
    openssl dgst -sha256 -sign '${encUri}' -out sig.bin msg.bin
    python3 -P ${mkHkdf} sig.bin '${domain}' ${toString keyBytes} $out
  ''
