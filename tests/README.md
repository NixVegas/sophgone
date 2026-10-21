# tests

Offline unit tests for the map, stubs, merge tool, and FIPs (Python; run
individually, e.g. `python3 tests/test_chainload_fip.py <fip>`).

`hush-rauc-walk.sh` is a sandbox HUSH control-flow test for the `nixbadge_*`
env strings in `pkgs/uboot-common/nixbadge.env` (it resolves the file's
preprocessor lines itself and converts it with the build's `env2string.awk`,
so the test and the product cannot drift). Run it against a U-Boot sandbox
binary built from the same pinned vendor tree:

```bash
sh tests/make-fit-fixtures.sh   # signed FIT fixtures + sandbox control DTB, into tests/fixtures/fit/out/
sh tests/hush-rauc-walk.sh "$(nix build --no-link --print-out-paths --max-jobs 0 .#uboot-sandbox)/bin/u-boot"
```

`make-fit-fixtures.sh` generates its own scratch signing keys at test time (never
committed) and signs `tests/fixtures/fit/{vbmeta,boot}.its` with them; the
sandbox runs the FIT cases with a control DTB that trusts that key.

It prints `PASS` on success, or `FAIL <n>: <output>` and a nonzero
exit on the first failing case. A second, optional argument is the
core `NIXBADGE_CORE` stands for (default `arm`); run it once more with
`riscv`. The test takes `core` from the converted file and uses it in
the expected `sysboot` and FIT paths, so the riscv run really exercises
`core=riscv`. The sandbox's `btnsel` is compiled with the arm extlinux
directory, so both runs expect `/arm/...` for the profile confs.

Each `u-boot -c` invocation takes a few seconds (the sandbox has 2304 MiB of
RAM so the product's real load addresses fit); a full run is about 100
seconds per core.

The sandbox's `part`, `sysboot`, `load` and `btnsel` are driven by env vars
the test sets (`sb_parts`, `sb_files`, `sb_dir`, `sb_btn`, `sb_user`,
`sb_show`); the script header and `pkgs/uboot-sandbox/package.nix` describe
them. The cases cover the slot walk, envpick, a legacy ext4-mbr card, gpt
cards booting each slot's signed FIT (with fallbacks), the signed-FIT
failure modes, including the secure build's env ending in `nixbadge_halt`, and
the `nixbadge_fuseonce` step: the real `nixbadge_fuse`, `devek`, `trng` and
`strapsel` code over a fake eFuse, TRNG and core-select latch (`sb_core`,
`sb_switch`, `sb_fused`, `sb_devek`, `sb_efuse`, `sb_efuser`, `sb_lock`,
`sb_trng`), with `reset` printing `RESET`.
