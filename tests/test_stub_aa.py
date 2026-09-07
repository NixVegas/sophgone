#!/usr/bin/env python3
# Verify the aarch64 chainloader stub assembles (against the generated
# .inc), place its dispatch tramp at 0x1DC (where the polyglot word's `b #444` lands),
# and contain explicit i-cache maintenance (`ic iallu`) before the launch jump.
# Requires aarch64-unknown-linux-gnu-{as,objdump} in PATH.
import subprocess, tempfile, pathlib

base = pathlib.Path(__file__).parent.parent / "pkgs" / "overflow-bl2"
inc = base / "sophgone-syms-aa.inc"
with open(inc, "w") as f:
    subprocess.run(["python3", str(base / "gen-syms.py"), str(base / "sophgone-map.json"), "aa"],
                   stdout=f, check=True)
with tempfile.TemporaryDirectory() as d:
    subprocess.run(["aarch64-unknown-linux-gnu-as", "-I", str(base), "-march=armv8-a",
                    str(base / "sophgone-aa.S"), "-o", f"{d}/o.o"], check=True)
    dis = subprocess.run(["aarch64-unknown-linux-gnu-objdump", "-d", f"{d}/o.o"],
                         capture_output=True, text=True).stdout
assert "iallu" in dis, "no i-cache maintenance (ic iallu) before launch"
assert "civac" in dis, "no d-cache clean (dc civac) of the loaded BL2"
assert "1dc <aa_tramp>" in dis, "arm stub tramp not at 0x1DC"
print("stub-aa OK")
