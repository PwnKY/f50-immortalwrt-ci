# Provenance

Every input, where it comes from, and what is rebuilt rather than reused. Digests are
checked before use; a mismatch stops the build.

## Sources

| input | source | verification |
|---|---|---|
| port source (patches, drivers, overlays, tooling) | `github.com/dikeckaan/mu300-linux` @ the commit in `inputs/pins.json` | the commit is checked out by hash |
| Linux stable (primary kernel) | `cdn.kernel.org` (mirror fallback) | the release's own `sha256sums.asc` |
| Linux longterm (fallback kernel) | `cdn.kernel.org` (mirror fallback) | the release's own `sha256sums.asc` |
| ImmortalWrt base rootfs (`armsr/armv8`) | `downloads.immortalwrt.org/releases/<ver>/` | the release's own `sha256sums` |
| Aurora theme APK | `github.com/eamonxg/luci-theme-aurora` release | pinned digest in `inputs/pins.json` |
| Argon theme APK | `github.com/jerrykuku/luci-theme-argon` release | pinned digest in `inputs/pins.json` |
| 5.4 kernel bundle (`mu300-kernel.tar.gz`) | `github.com/dikeckaan/mu300-linux` release | pinned digest in `inputs/pins.json` |
| installer updater (`mu300-update`) | `github.com/dikeckaan/mu300-linux` release | pinned digest in `inputs/pins.json` |

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
- `mu300-update` — the standalone updater, byte-for-byte from the same release.

They are re-published in this repository's releases for convenience so the asset set is
complete and can be flashed directly; they are the upstream author's binaries and are not
modified here. The Wi-Fi/BT, SIPA and other vendor modules in the root filesystem for these
kernels come from the same bundles, so each kernel bundle and its module set stay in step.

## Not included

Vendor firmware, the Android vendor subset, the GPU user-space blobs, IMEI/NV data, any
password or SSH host key: the installer extracts and adds those from the device itself.
No VPN engine is bundled. The generic image carries a locked root password until an
installer sets one.

## Verification

`scripts/verify-output.py` checks the finished set: exactly six filenames, five distinct
digests consistent with `SHA256SUMS`, the reused files unchanged, each of the three module
sets byte-identical to the matching bundle (with vermagic agreement), the Chinese
translation files, the theme and timezone settings, the absence of upgrade payloads and of
any VPN engine, and the required core packages. `scripts/test-verify-output.py` then
re-runs the verifier against four deliberately broken copies and requires each to be
rejected. The release is only published when both pass.

Limits worth knowing: the build is auditable but not bit-for-bit reproducible — package
feeds and mirrors keep moving, so an identical rerun is not promised. Offline verification
is not a boot or radio test.
