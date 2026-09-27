# sophgone

https://sophg.one

## One file. Two architectures. Zero secure boot.

One **polyglot** `fip.bin` pwns *both* cores of the SG2000 at once.
The same file hijacks the aarch64 **A53** and the RISC-V **C906** mask
ROMs, then chainloads NixOS on whichever core the GPIO strap selects.

Both cores load one shared oversized BL2 whose first instruction is a dual-ISA trampoline:
the same bytes decode to a valid branch on aarch64 and on RISC-V with different
displacements. From there, each core relocates a small stub, reopens the SD card
through the ROM's own FatFs, loads a second image, and launches it, all before any
secure-boot verification runs.

Since this is a mask ROM vulnerability, there is no patch possible for these chips,
and they are broken until Sophgo ships a new silicon revision.

## The flaw

The mask ROM copies the FIP's `BL2` image using an attacker-controlled, unbounded
`BL2_IMG_SIZE` field **before** it decrypts or verifies BL2. This BL2 image ends
up overlapping with the mask ROM's stack prior to secure boot verification.
Drop the exploit fip.bin on the SD card and it will boot every time.

The size field lives in the FIP's `param1` header, which is protected only by a
CRC-16 checksum rather than a signature.

It defeats every secure-boot level the part supports:

- **SCS = 00.** Secure boot off.
- **SCS = 01.** RSA-2048 signature enforced. `VRK4.VBK.VCC.PE.BS.J.PWNED`. The
  key chain verifies, then control is taken before the BL2 signature is checked.
- **SCS = 02.** RSA plus AES image encryption enforced.
  `VRK4.VBK.DK4.VCC.PE.BS.J.PWNED`. The ROM even unwraps the image-encryption key
  first, then hands control to our plaintext bytes. Very nice of it!

No fuse setting changes where BL2 is loaded.

## Layout

- `pkgs/` has one directory per package (`<name>/package.nix` plus that package's
  own files), discovered by `packagesFromDirectoryRecursive`:
  - FIP generation: `fip/`, `fip-polyglot/`, `fsbl/`, `bl31-blob/`, `opensbi/`,
    `uboot-arm/`, `uboot-riscv/`, and the shared `uboot-common/` (board files,
    custom commands, and the U-Boot patches both cores apply).
  - `merge-bl2/`: the dual-core polyglot merge tool
  - `overflow-bl2/`: the overflow BL2, chainloader stubs (`sophgone-{aa,rv}.S`),
    and the RE map (`sophgone-map.json`); `chainload/`: the malicious FIP.
  - secure boot: `fip-sign/`, `graft-fip/`, `derive-fw-key/`, `fuse-map/`,
    `bl-pk-sig-ceremony/` (certs live with their primary consumer).
- `modules/`: the `nixpkcs` NixOS module declaring the SG1 secure-boot keypairs.
- `tests/`: offline unit tests for the map, stubs, merge tool, and FIPs.

## Usage

```
nix build .#chainload-fip   # place at SD:/fip.bin
nix build .#sophg1          # place at SD:/sophg.1  (the real FSBL it reopens)
```

Note that secure boot requires grafting of secure boot keys onto the new FIP.
This flake has an example for badge #1 which is fused. If you run into another
you'll probably need to write a derivation that black-boxes it.

As a flake input (this is how `badgeos` consumes it):

```nix
inputs.sophgone.url = "path:./sophgone";
inputs.sophgone.inputs.nixpkgs.follows = "nixpkgs";
# then, with your own pkgs:
sophgone.lib.fipPolyglot { inherit pkgs; }
sophgone.lib.chainloadFip { inherit pkgs; variant = "polyglot"; }
```

## Mask ROM RE

We dumped the 96 KiB mask ROM from inside BL2, the only context that can read it,
and reversed the FIP loader's verify sequence on both cores. They are identical:
`VRK, VBK, DK, VCC, VCP, load BL2, BL2 cksum, DB2, VB2`. The overrun happens at
*load BL2*, several steps before `DB2` (decrypt) and `VB2` (verify).

## How we found it

We found it after building a **polyglot FIP** for the
[Nix Badge](https://nix.vegas/blog/2026/badge)'s multi-architecture build.
We wanted one image both cores would accept, which meant working out how the SG2000's
FIP format actually works instead of how the documentation says it does.

## Timeline

- **2026-09-02:** proof of concept tested without secure boot
- **2026-09-08:** proof of concept verified with secure boot and boot encryption
- **2026-09-11:** writeup complete, Sophgo open source email contacted and CVE requested
- **2026-09-21:** another email sent to Sophgo (security@ bounced)
- **2026-09-27:** vendor unresponsive, released [at NixCon](https://talks.nixcon.org/nixcon-2026/me/submissions/LN8PXG/)

## Security advisory

- **Affected.** Sophgo SG2000 / SG200x and CV180x / CV181x family mask ROMs
  (Milk-V Duo S and relatives).
- **Impact.** Full pre-verification code execution at the highest privilege of
  each core (EL3 Secure World on the A53, M-mode on the C906), defeating signed and
  signed/encrypted secure boot. Local attacker with control of the boot
  media.
- **Mitigation.** None in the ROM. Don't let anyone overwrite /boot/fip.bin.

## Notes

- **What products are affected?** The NanoKVM (LicheeRV Nano) and similar products,
  including the Milk-V Duo Module 01 and Milk-V Duo S. Anything that uses a Sophgo SG200x will be affected.
- **What do I need to do?** If secure boot is important to your threat model, reassess your
  use of this part. If you wanted to mess with fusing secure boot without risk of bricking your dev board,
  maybe grab a LicheeRV Nano or similar device. They're neat little boards.
  You will likely never brick it with Sophgone unless you somehow lock out SD card boot via the fuses.
  Even if you do, you could probably still get around it with a modification to Sophgone.
- **What boot modes are affected?** eMMC, SPINAND, and other boot modes are equally affected but
  will require a different stack map in order to work since the affected function is at a different
  stack depth. This demo was made for an SD card (hence the SD/... in the mask ROM boot line).
