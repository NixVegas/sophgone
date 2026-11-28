#!/usr/bin/env python3
"""Run the real core-transfer environment in U-Boot's HUSH sandbox.

The sandbox models SD files and the request command; this tests control flow,
not MMIO, watchdog hardware, or execution on another CPU.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]


def environment(*defined):
    """nixbadge.env as the build converts it with these symbols defined."""
    source = (root / "pkgs/uboot-common/nixbadge.env").read_text()
    keep, lines = [True], []
    for line in re.sub(r'/\*.*?\*/', '', source, flags=re.S).splitlines():
        if line.startswith('#ifdef '):
            keep.append(keep[-1] and line.split()[1] in defined)
        elif line == '#else':
            keep[-1] = keep[-2] and not keep[-1]
        elif line == '#endif':
            keep.pop()
        else:
            assert not line.startswith('#'), line
            if keep[-1]:
                lines.append(line)
    converted = subprocess.check_output([
        "awk", "-f", str(root / "pkgs/uboot-common/env2string.awk")],
        input='\n'.join(lines) + '\n', text=True)
    text = converted.removeprefix('#define CONFIG_EXTRA_ENV_TEXT "').strip().removesuffix('"')
    return dict(item.split('=', 1) for item in text.replace(r'\"', '"').split(r'\0') if item)


env = environment('CONFIG_CMD_SYSBOOT', 'NIXBADGE_CORE_TRANSFER')
script = env['nixbadge_coreswap']
assert "'" not in script
# The three lines a coreTransfer build adds (nixbadge_boot, nixbadge_try,
# nixbadge_legacy), and none of them otherwise.
assert 'sdready; fi; run nixbadge_coreswap; run nixbadge_fuseonce;' in env['nixbadge_boot']
assert env['nixbadge_try'].endswith('btnsel; coreswap report; run nixbadge_fit')
assert '; btnsel; coreswap report; if test' in env['nixbadge_legacy']
assert 'coreswap' not in str(environment('CONFIG_CMD_SYSBOOT'))
# The mailbox the script reads is the one the FSBL and its entry stub write.
memmap = {name: int(value, 16) for name, value in re.findall(
    r'^#define CORESWAP_(\w+) +(0x[0-9a-f]+)', (root / "pkgs/fsbl/coreswap-memmap.h").read_text(), re.M)}
status = memmap['MAILBOX_ADDR'] + memmap['MAILBOX_STATUS']
entry = memmap['MAILBOX_ADDR'] + memmap['MAILBOX_ENTRY']
assert (f"itest.l *{status:#x} == {memmap['RUN']:x} && itest.l *{entry:#x} == {memmap['ENTRY_ADDR']:x}"
        f" && itest.l *{entry + 4:#x} == 0") in script

with tempfile.TemporaryDirectory(prefix="coreswap-hush-") as directory:
    fixture = pathlib.Path(directory) / 'coreswap.request'
    pre = (f"setenv nixbadge_coreswap '{script}'; setenv core arm; "
           "setenv bootmedium 1; setenv mmcdev 0; "
           f"setenv sb_dir {directory}; setenv sb_files /coreswap.request; "
           "setenv sb_show 'nixbadge_coreswap_result sb_pending'; "
           "mw.l 84000000 0 10; mw.b 86002008 a5; ")

    def check(name, setup='', content=b'riscv\n', result='disabled', write=False,
              request=False, reset=False, ack=False):
        fixture.write_bytes(content)
        setup = setup.strip().rstrip(';').strip()
        run = pre + (setup + '; ' if setup else '') + 'run nixbadge_coreswap; printenv nixbadge_coreswap_result; if itest.b *0x86002008 == a5; then echo CORESWAP-SENTINEL-OK; fi'
        proc = subprocess.run([sys.argv[1], '-c', run], text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        out = proc.stdout.replace('\r', '')
        expected = {
            f'nixbadge_coreswap_result={result}': True,
            'CORESWAP-WRITE /coreswap.pending 6': write,
            'CORESWAP-WRITE /coreswap.pending 4': ack,
            'CORESWAP-REQUEST': request,
            'RESET\n': reset,
            'CORESWAP-SENTINEL-OK': not reset,
        }
        assert proc.returncode == 0, (name, proc.returncode, out)
        for value, present in expected.items():
            assert (value in out) == present, (name, value, present, out)
        assert 'Unknown command' not in out and 'syntax error' not in out, (name, out)
        print('PASS', name, flush=True)

    check('no request', 'setenv sb_files')
    check('eMMC excluded', 'setenv bootmedium 0')
    check('wrong SD index', 'setenv mmcdev 1')
    check('fuse provisioning excluded', 'setenv nixbadge_fuse_serial pending')
    check('wrong target', content=b'arm\n')
    check('missing newline', content=b'riscv')
    check('trailing data', content=b'riscv\nx')
    check('oversized request is bounded', content=b'riscv\n' + b'x' * 1048576)
    check('pending prevents retry', 'setenv sb_pending 1', result='timeout')
    pending = fixture.with_name('coreswap.pending')
    previous = 'setenv sb_files "/coreswap.request /coreswap.pending"; setenv sb_pending 1'
    pending.write_bytes(b'1WSC')
    check('ordinary ARM reboot after accepted transfer', previous, result='retained')
    pending.write_bytes(b'1WSCx')
    check('trailing bytes cannot acknowledge a request', previous, result='timeout')
    check('failed write prevents request', 'setenv sb_write_failure 1',
          result='timeout', write=True)
    check('request refusal prevents reset', 'setenv sb_request_failure 1',
          result='timeout', write=True, request=True)
    check('valid request resets once', result='timeout', write=True, request=True, reset=True)
    rv = 'setenv core riscv; mw.l 84000000 43535731; mw.l 84000010 84001000; '
    check('confirmed RISC-V entry', rv, result='ok')
    check('C906 loader acknowledges pending transfer', rv + 'setenv sb_pending 1', result='ok', ack=True)
    check('wrong heartbeat', rv + 'mw.l 84000000 43534531')
    check('wrong entry address', rv + 'mw.l 84000010 84001004')
    check('nonzero entry upper word', rv + 'mw.l 84000014 1')
