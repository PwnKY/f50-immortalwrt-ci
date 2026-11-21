# Provenance

Every input, where it comes from, and what is rebuilt rather than reused. Digests are
checked before use; a mismatch stops the build.

## Sources

| input | source | verification |
|---|---|---|
| port source (patches, drivers, overlays, tooling) | our mirror `github.com/PwnKY/mu300-linux-pin` @ the commit in `inputs/pins.json` — a verbatim copy of `dikeckaan/mu300-linux` at `35a1c550…`, minus `stock/` | the commit is checked out by hash; the mirror exists because upstream deleted the branch that commit was the tip of |
| reused 5.4 bundle and updater | the upstream release named in `inputs/pins.json` (`release_repo`) | pinned digest in `inputs/pins.json` |
| Linux stable (primary kernel) | `cdn.kernel.org` (mirror fallback) | the release's own `sha256sums.asc` |
| Linux longterm (fallback kernel) | `cdn.kernel.org` (mirror fallback) | the release's own `sha256sums.asc` |
| ImmortalWrt base rootfs (`armsr/armv8`) | `downloads.immortalwrt.org/releases/<ver>/` | the release's own `sha256sums` |
| Aurora theme APK | `github.com/eamonxg/luci-theme-aurora` release | pinned digest in `inputs/pins.json` |
| Argon theme APK | `github.com/jerrykuku/luci-theme-argon` release | pinned digest in `inputs/pins.json` |
| 5.4 kernel bundle (`mu300-kernel.tar.gz`) | `github.com/dikeckaan/mu300-linux` release | pinned digest in `inputs/pins.json` |
| installer updater (`mu300-update`) | the pinned tree (`rootfs/overlay/opt/mu300/bin/mu300-update`) + `scripts/local-adaptations.patch` | pinned commit in `inputs/pins.json`; checked by `scripts/verify-output.py` |

The ImmortalWrt and kernel versions follow the newest release automatically, so their
digests are not pinned: they are taken from the publisher's own checksum list, which is the
same trust model as pinning. The theme APKs and the two reused binaries are pinned because
they are attached to fixed releases that do not move.

## Rebuilt here

- The mainline kernels: `Image`, DTB, `modules.builtin*` and all 31 out-of-tree vendor
  modules (Wi-Fi/BT `sprd_wlan_combo` and `wcn_bsp`, the SIPA/IPA stack, Trusty, Mali, …),
  built from the kernel.org source with the port's patches and config.
- Both kernel bundles (`make-bundle.sh`: `Image`, a generic ramdisk, the modules and the
  release marker).
- The static helpers `mu300-bt-init` and `mu300-keys`, compiled from the port's own
  `tools/*.c` sources.
- The root filesystem: the ImmortalWrt base plus the port's overlays, the theme APKs, the
  Chinese localisation and the `scripts/customize-rootfs.sh` customization
  (language `zh_cn`, Argon as default with Aurora retained, `Asia/Shanghai` / `CST-8`,
  `country=CN`, the three kernel module sets, and the transactional removal of the
  whole-image upgrade packages).

## Reused, not rebuilt

- `mu300-kernel.tar.gz` — the vendor 5.4 kernel bundle, taken byte-for-byte from the
  upstream release. It also supplies the static `busybox` and `logdw` used by the generic
  ramdisk, and the 5.4 module set that goes into the root filesystem.

It is re-published in this repository's releases for convenience so the asset set is
complete and can be flashed directly; it is the upstream author's file and is not modified
here.

`mu300-update` is **not** taken from that release: the release's copy is older than the
pinned tree's own updater (it writes `boot_b` only, without the Linux slot detection), and a
device replaces its updater with the release's one before it updates. The build publishes
the tree's `rootfs/overlay/opt/mu300/bin/mu300-update` with the local adaptations (the 7.3
kernel choice) — the same file the root filesystem carries, and what upstream's own
`tools/make-release.sh` publishes. The Wi-Fi/BT, SIPA and other vendor modules in the root filesystem for these
kernels come from the same bundles, so each kernel bundle and its module set stay in step.

## Not included

Vendor firmware, the Android vendor subset, the GPU user-space blobs, IMEI/NV data, any
password or SSH host key: the installer extracts and adds those from the device itself.
No VPN engine is bundled. The generic image carries a locked root password until an
installer sets one.

## Verification

`scripts/verify-output.py` checks the finished set: the expected filenames (one bundle per
kernel series), digests consistent with `SHA256SUMS`, the reused 5.4 bundle unchanged, the
updater (parses, Linux slot, offers every shipped series, identical to the rootfs copy), each
module set byte-identical to the matching bundle (with vermagic agreement), the Chinese
translation files, the theme and timezone settings, the absence of upgrade payloads and of
any VPN engine, and the required core packages. `scripts/test-verify-output.py` then
re-runs the verifier against seven deliberately broken copies and requires each to be
rejected. The release is only published when both pass.

Limits worth knowing: the build is auditable but not bit-for-bit reproducible — package
feeds and mirrors keep moving, so an identical rerun is not promised. Offline verification
is not a boot or radio test.
