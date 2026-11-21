#!/usr/bin/env python3
"""Offline release invariants; not a substitute for device runtime tests."""
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile

A = Path(sys.argv[1])
# The release: the vendor 5.4 bundle, one mainline bundle per kernel series (the 6.18 LTS, the
# primary 7.2 and any opt-in series such as 7.3), the rootfs, the updater and SHA256SUMS.
BASE = {'mu300-kernel.tar.gz', 'mu300-openwrt-rootfs.tar.gz', 'mu300-update', 'SHA256SUMS'}
REQUIRED_SERIES = {'6.18', '7.2'}
names = {p.name for p in A.iterdir()}
series_of = {}
for name in names - BASE:
    m = re.fullmatch(r'mu300-kernel-([0-9]+\.[0-9]+)\.tar\.gz', name)
    assert m, f'Unexpected file in the release: {name}'
    series_of[name] = m.group(1)
assert BASE <= names, f'Missing release files: {sorted(BASE - names)}'
assert REQUIRED_SERIES <= set(series_of.values()), \
    f'Missing kernel bundles: {sorted(REQUIRED_SERIES - set(series_of.values()))}'
FILES = BASE | set(series_of)
checked = set()
for line in (A / 'SHA256SUMS').read_text().splitlines():
    sha, name = line.split()
    assert name in FILES - {'SHA256SUMS'} and name not in checked
    checked.add(name)
    with (A / name).open('rb') as f:
        assert hashlib.file_digest(f, 'sha256').hexdigest() == sha, name
assert checked == FILES - {'SHA256SUMS'}
# Byte-identical reuse from the verified portable release: the 5.4 reference bundle is never
# rebuilt. The mainline bundles are built from the published kernel tarballs, so no digest is
# pinned for them; SHA256SUMS covers their bytes and their modules are compared with the rootfs
# below.
reused = {
    'mu300-kernel.tar.gz': 'e7de479fb54624473fa26445f400ffd50631d47be8ae622a5e33aab685e8a686',
}
for name, sha in reused.items():
    with (A / name).open('rb') as f:
        assert hashlib.file_digest(f, 'sha256').hexdigest() == sha, 'Reused input changed: ' + name
bundles = {}
# The file name states which kernel series the flasher installs, so the release
# inside has to agree with it. The patch level is never written down here: it is
# read from each bundle (kernel.release, or the vermagic of the verified original
# 5.4 bundle, which carries no release marker).
for name, series in [('mu300-kernel.tar.gz', '5.4.')] + sorted((n, s + '.') for n, s in series_of.items()):
    with tarfile.open(A / name, 'r:gz') as tf:
        members = {str(PurePosixPath(m.name)): m for m in tf.getmembers()}
        if 'kernel.release' in members:
            release = tf.extractfile(members['kernel.release']).read().decode().strip()
        else:
            # Verified original 5.4 bundle has no release marker.
            first = next(m for p, m in members.items() if p.startswith('modules/') and p.endswith('.ko'))
            release = re.search(rb'(?:^|\x00)vermagic=([^ \x00]+) ', tf.extractfile(first).read()).group(1).decode()
        modules = {}
        for path, member in members.items():
            if path.startswith('modules/') and path.endswith('.ko'):
                data = tf.extractfile(member).read()
                assert re.search(rb'vermagic=' + re.escape(release.encode()) + rb' ', data), path
                modules[Path(path).name] = hashlib.sha256(data).hexdigest()
        assert modules, name
        assert release.startswith(series), f'{name} carries kernel release {release}, not {series}*'
        bundles[release] = modules
assert len(bundles) == 1 + len(series_of), f'Bundles must carry distinct kernel releases: {sorted(bundles)}'
# The updater is the pinned tree's own (with the local adaptations), not the older one of the
# upstream release: devices replace their updater with this file before they update, so it has
# to parse, know the Linux slot, and offer every kernel series this release ships.
updater = (A / 'mu300-update').read_text()
assert subprocess.run(['sh', '-n', str(A / 'mu300-update')]).returncode == 0, 'mu300-update does not parse'
assert 'BOOT_PART=boot_$LINUX_SLOT' in updater, 'mu300-update is an old one without the Linux slot'
offered = re.search(r'^KERNELS="([^"]*)"$', updater, re.M)
assert offered, 'mu300-update has no KERNELS list'
offered = set(offered.group(1).split())
assert {'5.4'} | set(series_of.values()) <= offered, \
    f'mu300-update does not offer kernel {sorted(({"5.4"} | set(series_of.values())) - offered)}'
with tarfile.open(A / 'mu300-openwrt-rootfs.tar.gz', 'r:gz') as tf:
    members = {}
    for member in tf.getmembers():
        assert not member.name.startswith('/') and '..' not in PurePosixPath(member.name).parts, member.name
        members[str(PurePosixPath(member.name))] = member
    def text(name):
        return tf.extractfile(members[name]).read().decode()
    assert re.search(r"DISTRIB_ARCH=['\"]aarch64_generic['\"]", text('etc/openwrt_release'))
    assert re.search(r"DISTRIB_RELEASE=['\"]25\.12\.2['\"]", text('etc/openwrt_release'))
    assert 'ImmortalWrt' in text('etc/openwrt_release')
    # The image version names the primary kernel of this release, which must be a
    # kernel a bundle in this directory actually ships; the versions themselves
    # come from the bundles, not from this script.
    version = text('etc/mu300/image-version').strip()
    primary = re.match(r'custom-immortalwrt-25\.12\.2-k([0-9][^-]*)-', version)
    assert primary, f'Unexpected image-version: {version!r}'
    named = primary.group(1)
    assert any(r == named or r.startswith(named + '.') or r.startswith(named + '-') for r in bundles), \
        f'image-version names kernel {named}, which no bundle carries: {sorted(bundles)}'
    # Check the actual installed database, not just a potentially stale inventory.
    packages = set(re.findall(r'^P:(.+)$', text('lib/apk/db/installed'), re.M))
    assert packages, 'Missing/empty APK installed database'
    forbidden = {'attendedsysupgrade-common', 'luci-app-attendedsysupgrade', 'owut', 'procd-ujail'}
    forbidden |= {p for p in packages if p.startswith('luci-i18n-attendedsysupgrade-')}
    assert not packages & forbidden, f'Unsafe installed packages: {packages & forbidden}'
    core = {'base-files', 'luci', 'luci-base', 'luci-mod-admin-full', 'luci-mod-network',
            'luci-mod-status', 'luci-mod-system', 'luci-app-firewall', 'luci-app-package-manager',
            'firewall4', 'netifd', 'procd', 'rpcd', 'uhttpd', 'dnsmasq-full'}
    assert core <= packages, f'Missing core packages: {core - packages}'
    assert tf.extractfile(members['opt/mu300/bin/mu300-update']).read() == (A / 'mu300-update').read_bytes(), \
        'The rootfs carries another mu300-update than the release'
    assert members['sbin/sysupgrade'].isfile(), 'Project sysupgrade must be a regular file'
    assert hashlib.sha256(tf.extractfile(members['sbin/sysupgrade']).read()).hexdigest() == \
        '5d4447aebed92bec11979b7754195c7b03783bec7e73b5e5176f89aa870a5388', 'Project sysupgrade wrapper changed'
    assert 'sbin/sysupgrade.openwrt' in members, 'Backup-only original sysupgrade missing'
    for required in ('www/luci-static/resources/view/status/index.js',
                     'www/luci-static/resources/view/network/interfaces.js',
                     'www/luci-static/resources/view/firewall/zones.js',
                     'usr/share/luci/menu.d/luci-mod-status.json',
                     'usr/share/luci/menu.d/luci-app-mu300.json'):
        assert required in members, required
    actual = {path for path in members if path.startswith('lib/modules/') and path.endswith('.ko')}
    expected = {f'lib/modules/{release}/{name}' for release, modules in bundles.items() for name in modules}
    assert actual == expected, f'Unexpected/missing rootfs modules: {actual ^ expected}'
    for release, modules in bundles.items():
        for name, sha in modules.items():
            path = f'lib/modules/{release}/{name}'
            assert hashlib.sha256(tf.extractfile(members[path]).read()).hexdigest() == sha, path
    for required in ('opt/mu300/bin/mu300-next-boot', 'opt/mu300/bin/mobile-data', 'opt/mu300/bin/led-status', 'opt/mu300/bin/mu300-sms', 'www/luci-static/resources/view/mu300/home.js', 'www/luci-static/aurora/main.css'):
        assert required in members, required
    assert any(path in members for path in ('www/luci-static/argon/cascade.css', 'www/luci-static/argon/css/cascade.css')), 'Argon CSS missing'
    for translation in ('base', 'firewall', 'package-manager'):
        assert f'usr/lib/lua/luci/i18n/{translation}.zh-cn.lmo' in members, translation
    assert members['usr/bin/wget'].issym() and members['usr/bin/wget'].linkname == '/bin/uclient-fetch', 'Build-only wget wrapper leaked'
    assert '/luci-static/argon' in text('etc/config/luci') and 'zh_cn' in text('etc/config/luci')
    assert 'Asia/Shanghai' in text('etc/config/system') and 'CST-8' in text('etc/config/system')
    for path in members:
        filename = PurePosixPath(path).name
        assert 'attendedsysupgrade' not in path.lower(), path
        assert filename not in ('owut', 'ujail', '11_upgrades.js') and not filename.startswith('owut.'), path
        assert not path.startswith(('opt/mu300/android/', 'root/.ssh/')), path
        assert 'ssh_host_' not in path, path
        assert not re.match(r'etc/dropbear/.*key$', path), path
        assert path not in ('opt/mu300/bin/sing-box', 'opt/mu300/bin/xray', 'opt/mu300/bin/hev-socks5-tunnel'), path
        if path.startswith('lib/firmware/') and members[path].isfile():
            assert Path(path).name in ('regulatory.db', 'regulatory.db.p7s'), path
    root = next(line for line in text('etc/shadow').splitlines() if line.startswith('root:'))
    assert root.split(':')[1] == '!', 'Generic root account must not contain a password/hash'
print(f'PASS: {len(FILES)} filenames, {len(FILES) - 1} hashes, reused 5.4 identity, the updater (parses, Linux slot, offers {" ".join(sorted(offered))}), all {len(bundles)} matching module sets, release/UI settings, safe upgrade package/file exclusions, core LuCI and sysupgrade wrapper, generic payload checks')
