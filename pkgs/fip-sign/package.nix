# Sign a FIP: sg1-sb signs the images on the TPM via the autopen
# daemon. fipsign shells out to `openssl dgst -sha256 -sign <pkcs11: URI>`; the
# wrapped OpenSSL resolves that URI through pkcs11-provider and the autopen shim.
#
# Emits a signed fip.bin (ROOT_PK / BL_PK / BL_PK_SIG / image sigs, FIP_FLAGS SCS
# bit set) plus KPUB_HASH = SHA256(ROOT_PK[:256]) for the efuse root-key slot. On
# SCS=0 the sig is ignored; on a burned SCS=1 part the ROM enforces it.
#
# Requires the build host to run the autopen daemon serving sg1-sb and expose
# /run/autopen to the sandbox (services.autopen).
{
  lib,
  fetchFromGitHub,
  runCommand,
  writeText,
  python3,
  openssl,
  autopen,
  gnupatch,

  fip,
  # sg1-sb / sg1-root public certs (in-repo), the committed cold BL_PK_SIG, and
  # sg1-sb's autopen remote signing key (built from the cert by default — pure,
  # no token access; pass one from a system config to reuse its exact handle).
  blCert ? ./sg1-sb.crt,
  # SRI content hash of sg1-sb's autopen verification key (deterministic per
  # cert). Makes fromCertificate a fixed-output derivation so the remote handle
  # needs no IFD. Recompute if blCert changes: `nix hash file` on the output of
  # `verificationKey.fromCertificate blCert`.
  blCertHash ? "sha256-X6M0hLzEKdFYp+wfiZSCsfBEyecjga8WpWAErw17HK0=",
  rootCert ? ./sg1-root.crt,
  # The cold sg1-root signature over bl_pk, from the offline ceremony
  # (bl-pk-sig-ceremony) and committed in-repo. Verified: it's a valid
  # SHA-256/PKCS#1 v1.5 sg1-root signature over sg1-sb's modulus.
  blPkSig ? ./bl_pk_sig.bin,
  blSigningKey ? autopen.lib.signingKey.remote {
    name = "sg1-sb";
    verificationKey = autopen.lib.verificationKey.fromCertificate {
      source = blCert;
      hash = blCertHash;
    };
    socketPath = "/run/autopen/socket";
  },

  # Encrypted-boot mode: sign, then AES-128-CBC encrypt the images with bl_ek and
  # wrap bl_ek under ldr_ek into BL_EK (FIP_FLAGS_ENCRYPTED). ldrEk/blEk are raw
  # 16-byte key files, normally from derive-fw-key.nix (deterministic, per-serial).
  encrypt ? false,
  ldrEk ? null,
  blEk ? null,
}:

assert encrypt -> (ldrEk != null && blEk != null);

let
  fsblSrc = fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  # sg1-sb as a plain RFC 7512 store URI. openssl's OSSL_STORE resolves it through
  # pkcs11-provider + the autopen module (module-path pins the shim); the daemon
  # does the actual RSA sign. `object=sg1-sb` matches the AUTOPEN_LABEL set below.
  blUri = "pkcs11:object=sg1-sb;type=private?module-path=${autopen.pkcs11Module.path}";

  subcmd = if encrypt then "sign-enc" else "sign";
  # bl_ek is the per-IMAGE content key; it is derived below from this build's own
  # $out, so the file handed to fipsign is bl_ek.bin, not the base key. ldr_ek is
  # the FUSED loader KEK and must stay exactly as burned, so it is passed as-is.
  encArgs = lib.optionalString encrypt "--ldr-ek ${ldrEk} --bl-ek bl_ek.bin";

  # Bind bl_ek to the output store path: the image key is HKDF-SHA256(base_bl_ek,
  # info = "SG1-FWENC-OUT-v1\0" || $out), so every signed-enc output gets a
  # distinct content key. bl_ek only ever reaches the chip wrapped under ldr_ek in
  # BL_EK and the ROM unwraps whatever the image carries, so fuses stay valid
  # across rebuilds.
  #
  # Not circular: $out is fixed by the .drv (a hash of the declared inputs) while
  # the key is computed during the build from $out, so the key is never an input
  # to the derivation that produces it. Same inputs -> same $out -> same key.
  # HKDF matches derive-fw-key.nix (SHA-256, base key as IKM, domain as info);
  # length comes from the base key so AES-256 would also work.
  mkBlEk = writeText "bl-ek-bind-out.py" ''
    import sys
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    base = open(sys.argv[1], "rb").read()
    out_path, dest = sys.argv[2], sys.argv[3]
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=len(base),
        salt=None,
        info=b"SG1-FWENC-OUT-v1\0" + out_path.encode(),
    ).derive(base)
    open(dest, "wb").write(key)
  '';

  # Standalone, content-addressed copy of the cert. The shim reads AUTOPEN_CERT at
  # sign time; builtins.path pins it to one stable store path (a bare flake
  # self-subpath is not reliably in this build's closure and churns with the snapshot).
  blCertFile = builtins.path {
    path = blCert;
    name = "sg1-sb.crt";
  };

  # openssl wrapped so its libcrypto loads pkcs11-provider with the autopen module
  # + AUTOPEN_REMOTE_KEY/CERT/LABEL. fipsign shells out to this `openssl dgst
  # -sign`, so every image sig goes token -> daemon. The wrapper carries the env
  # into fipsign's subprocess even though fipsign itself runs under a plain python.
  opensslProvider = openssl.withPkcs11Module {
    pkcs11Module = autopen.pkcs11Module;
    moduleEnv = {
      remoteKey = blSigningKey;
      cert = blCertFile;
      label = "sg1-sb";
    };
  };

  # Plain python (pyca) used only to pull a cert's 256-byte big-endian RSA modulus
  # (ROOT_PK from sg1-root, BL_PK from sg1-sb) — no token/provider access.
  py = python3.withPackages (p: [ p.cryptography ]);
  extractModulus = writeText "extract-modulus.py" ''
    import sys
    from cryptography import x509
    n = x509.load_pem_x509_certificate(open(sys.argv[1], "rb").read()).public_key().public_numbers().n
    assert n.bit_length() <= 2048, n.bit_length()
    open(sys.argv[2], "wb").write(n.to_bytes(256, "big"))
  '';
in
runCommand "sg2000-fip-signed${lib.optionalString encrypt "-enc"}"
  {
    # opensslProvider must be the `openssl` on PATH: fipsign's subprocess picks it
    # up (with the provider env baked into the wrapper) to resolve the store URI.
    nativeBuildInputs = [
      gnupatch
      opensslProvider
      py
    ];
    # The signing step must run on the host with the autopen socket. preferLocalBuild
    # is only a preference (under `--max-jobs 0` it is overridden and the build is
    # offloaded to a builder with no TPM, dying in openssl). requiredSystemFeatures
    # makes it a hard constraint: only a builder advertising the `autopen` feature
    # is eligible, so an offloading deploy refuses to schedule it elsewhere.
    preferLocalBuild = true;
    requiredSystemFeatures = [ "autopen" ];
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    cp ${fsblSrc}/plat/cv181x/fiptool.py ${fsblSrc}/plat/cv181x/fipsign.py .
    chmod +w fipsign.py
    patch -p1 < ${./fipsign.patch}

    python3 -P ${extractModulus} ${rootCert}   root_pk.bin
    python3 -P ${extractModulus} ${blCertFile} bl_pk.bin
    ${lib.optionalString encrypt ''
      # Bind the image key to this output: bl_ek.bin = HKDF(base_bl_ek, info=$out).
      # See mkBlEk above for why reading $out here is deterministic and not circular.
      python3 -P ${mkBlEk} ${blEk} "$out" bl_ek.bin
    ''}
    # sg1-sb signs the images through the daemon; ROOT_PK / BL_PK / BL_PK_SIG are
    # committed. `openssl` on PATH is the provider-wrapped one resolving blUri.
    # In encrypt mode, fipsign also AES-encrypts the images with bl_ek (the
    # out-bound key derived just above) and wraps it under ldr_ek into BL_EK.
    python3 fipsign.py ${subcmd} \
      --bl-uri '${blUri}' \
      --root-pk root_pk.bin --bl-pk bl_pk.bin --bl-pk-sig ${blPkSig} \
      ${encArgs} \
      ${fip} $out/fip.bin 2>&1 | tee $out/sign.log

    # Fail the build if any image's recorded checksum no longer describes the bytes
    # it ships. The FSBL checks these before it decrypts, so a stale cksum is
    # invisible to every key check and just makes the owning core reject the image
    # (has regressed on LOADER_2ND_B before). No `| tee` here: a pipeline reports
    # the last stage's status, so tee would swallow the verifier's nonzero exit.
    python3 -P ${./verify-fip-cksums.py} $out/fip.bin > $out/cksums.log
    cat $out/cksums.log

    # KPUB_HASH = SHA256(ROOT_PK[:256]): the efuse root-key-slot value.
    sha256sum root_pk.bin | cut -d' ' -f1 > $out/kpub_hash.txt
    echo "signed fip: $out/fip.bin"
    echo "KPUB_HASH:  $(cat $out/kpub_hash.txt)"
''
