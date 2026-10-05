#!/usr/bin/env python3
"""Offline regression mutations of a temporary release copy, never the assets."""
import hashlib
import io
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile

assets = Path(sys.argv[1]).resolve()
verifier = Path(__file__).with_name('verify-output.py')
subprocess.run([sys.executable, str(verifier), str(assets)], check=True)
cases = (
    ('installed owut', 'Unsafe installed packages', 'package'),
    ('orphan upgrade status UI', '11_upgrades.js', 'file'),
    ('replaced sysupgrade', 'Project sysupgrade wrapper changed', 'wrapper'),
    ('missing core status package', 'Missing core packages', 'core'),
)
for label, expected_error, mutation in cases:
    with tempfile.TemporaryDirectory(prefix='verify-output-regression-') as directory:
        dest = Path(directory)
        # Non-rootfs assets remain read-only inputs to the test; copy their bytes.
        for source in assets.iterdir():
            if source.name not in ('mu300-openwrt-rootfs.tar.gz', 'SHA256SUMS'):
                (dest / source.name).write_bytes(source.read_bytes())
        with tarfile.open(assets / 'mu300-openwrt-rootfs.tar.gz', 'r:gz') as source, \
                tarfile.open(dest / 'mu300-openwrt-rootfs.tar.gz', 'w:gz', compresslevel=1) as target:
            for member in source.getmembers():
                path = str(PurePosixPath(member.name))
                data = source.extractfile(member).read() if member.isfile() else None
                if path == 'lib/apk/db/installed':
                    if mutation == 'package':
                        data += b'\nP:owut\nV:1\n\n'
                    elif mutation == 'core':
                        data = data.replace(b'P:luci-mod-status\n', b'P:removed-status\n')
                elif path == 'sbin/sysupgrade' and mutation == 'wrapper':
                    data += b'\n# changed wrapper\n'
                if data is not None:
                    member.size = len(data)
                target.addfile(member, io.BytesIO(data) if data is not None else None)
            if mutation == 'file':
                member = tarfile.TarInfo('www/luci-static/resources/view/status/include/11_upgrades.js')
                payload = b'// orphan attended-upgrade UI\n'
                member.size = len(payload)
                target.addfile(member, io.BytesIO(payload))
        sums = []
        for path in sorted(dest.iterdir()):
            with path.open('rb') as stream:
                sums.append(f'{hashlib.file_digest(stream, "sha256").hexdigest()}  {path.name}\n')
        (dest / 'SHA256SUMS').write_text(''.join(sums))
        result = subprocess.run([sys.executable, str(verifier), str(dest)], text=True, capture_output=True)
        assert result.returncode != 0 and expected_error in result.stderr, (label, result.stdout, result.stderr)
        print(f'PASS: rejects {label} with fresh valid hashes')
