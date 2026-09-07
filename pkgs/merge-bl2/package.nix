# Build the polyglot BL2: assemble both per-ISA relocating stubs, then
# merge them with the two FSBL bodies into one image whose first word is the
# dual-ISA entry 0x1400006F. See merge_bl2.py for the layout and
# docs/superpowers/plans/2026-09-01-sg2000-polyglot-fip.md for the design.
#
# arm  = primary   FSBL (reads MONITOR / LOADER_2ND slots, unpatched)
# riscv = secondary FSBL (reads BLCP_2ND / LOADER_2ND_B; slot="secondary")
{
  callPackage,
  lib,
  pkgsCross,
  python3,
  runCommand,
  writeTextFile,
  secureBoot ? false,
}:
let
  armFsbl = callPackage ../fsbl/package.nix {
    core = "arm";
    inherit secureBoot;
  };
  riscvFsbl = callPackage ../fsbl/package.nix {
    core = "riscv";
    slot = "secondary";
    inherit secureBoot;
  };
  armCC = pkgsCross.aarch64-embedded.stdenv.cc;
  riscvCC = pkgsCross.riscv64-embedded.stdenv.cc;
  armPfx = armCC.targetPrefix; # aarch64-none-elf-
  riscvPfx = riscvCC.targetPrefix; # riscv64-none-elf-

  # Sanity: entry word at OFFSET 0x20 (the ROM's BL2 jump target, past the
  # 8-word bl2_head), head zero, within the BL2 slot budget. Executable, run on $out.
  checkBl2 = writeTextFile {
    name = "check-polyglot-bl2.py";
    executable = true;
    text = ''
      #!${python3.interpreter}
      import struct, sys
      d = open(sys.argv[1], "rb").read()
      assert d[0:0x20] == b"\x00" * 0x20, "bl2_head (0..0x20) not zero"
      assert struct.unpack_from("<I", d, 0x20)[0] == 0x1400006F, "entry word missing at 0x20"
      assert len(d) <= 0x37000, f"polyglot BL2 {len(d):#x} exceeds BL2_SIZE"
      print(f"polyglot BL2 ok: {len(d):#x} bytes, entry 0x1400006F @ 0x20")
    '';
  };
in
runCommand "polyglot-bl2.bin" { nativeBuildInputs = [ python3 ]; } ''
  # aarch64 stub: default march/abi are fine (integer asm, no float). Link before
  # objcopy: `_start` is .globl, so `adr x9, _start` carries a relocation and the bare
  # .o would objcopy to `adr x9, #0` (off by 0x14). ld resolves it.
  ${armCC}/bin/${armPfx}gcc -c -o arm.o ${./stub-arm.S}
  ${armCC}/bin/${armPfx}ld -Ttext=0 -e _start -o arm.elf arm.o
  ${armCC}/bin/${armPfx}objcopy -O binary arm.elf arm-stub.bin

  # riscv stub: -mabi=lp64 avoids the toolchain's default D requirement; the stub is
  # .option norvc, and fence.i needs zifencei. Link before objcopy: riscv GAS emits
  # PCREL_HI20/LO12 relocations for `lla` even to local labels, so the unlinked .o leaves
  # every lla as `auipc rd,0; addi rd,rd,0` (address of itself). ld resolves the pcrel
  # pairs; --no-relax keeps every instruction 4 bytes so the pool stays at the stub's tail.
  # lla is auipc-relative, so the linked blob stays position-independent.
  ${riscvCC}/bin/${riscvPfx}gcc -march=rv64imac_zifencei -mabi=lp64 ${lib.optionalString secureBoot "-DPOLYGLOT_SCRATCH_ADDR=0x0C00F000"} -c -o rv.o ${./stub-riscv.S}
  ${riscvCC}/bin/${riscvPfx}ld --no-relax -Ttext=0 -e _start -o rv.elf rv.o
  ${riscvCC}/bin/${riscvPfx}objcopy -O binary rv.elf rv-stub.bin

  python3 -P ${./merge_bl2.py} \
    ${armFsbl}/bl2.bin ${riscvFsbl}/bl2.bin arm-stub.bin rv-stub.bin "$out"

  # (ROM jumps to bl2_entrypoint_real @ 0x20, not byte 0; C906 JTAG: mepc=0x20.)
  ${checkBl2} "$out"
''
