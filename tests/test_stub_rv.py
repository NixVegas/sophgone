#!/usr/bin/env python3
# Verify the riscv64 chainloader stub assembles (rv64, .option norvc),
# place its dispatch tramp at 0x160 (where the polyglot word's `j 320` lands), and end
# in a jump to the loaded BL2. No A53-style d-cache ROM helper (C906 needs none per the
# romexec). Requires riscv64-unknown-linux-gnu-{as,objdump} in PATH.
import subprocess, tempfile, pathlib

base = pathlib.Path(__file__).parent.parent / "pkgs" / "overflow-bl2"
inc = base / "sophgone-syms-rv.inc"
with open(inc, "w") as f:
    subprocess.run(["python3", str(base / "gen-syms.py"), str(base / "sophgone-map.json"), "rv"],
                   stdout=f, check=True)
with tempfile.TemporaryDirectory() as d:
    subprocess.run(["riscv64-unknown-linux-gnu-as", "-I", str(base), "-march=rv64imac",
                    str(base / "sophgone-rv.S"), "-o", f"{d}/o.o"], check=True)
    dis = subprocess.run(["riscv64-unknown-linux-gnu-objdump", "-d", f"{d}/o.o"],
                         capture_output=True, text=True).stdout
assert "160 <rv_tramp>" in dis, "rv stub tramp not at 0x160"
assert ("\tjr\t" in dis) or ("\tjalr\t" in dis), "no launch jump"
assert "lwu" in dis, "no header field reads"
print("stub-rv OK")
