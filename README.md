# F50 / MU300 firmware — automated ImmortalWrt + mainline kernel build

Builds the ZTE F50 (hardware MU300, Unisoc UMS9620/T760) firmware in GitHub Actions:
an **ImmortalWrt** root filesystem plus mainline **kernel bundles**, and publishes the
finished set as a release. It runs whenever something it depends on moves — a new
ImmortalWrt release, a new kernel.org point release, a new commit on the upstream port —
and can be started by hand at any time.

This repository contains **only the build**: no phone home, no device access, no flashing.

Every file in this repository, and everything a build produces, is described in
[FILES.md](FILES.md).

## What it produces

`dist/immortalwrt-<wrt>-k<stable>/assets/v<wrt>/` — the six files the portable installer
expects, with `SHA256SUMS`:

| file | how it is obtained |
|---|---|
| `mu300-kernel.tar.gz` | reused byte-for-byte from the upstream release (the vendor 5.4 kernel) |
| `mu300-kernel-<lts>.tar.gz` | **built here** from the kernel.org longterm source |
| `mu300-kernel-<stable>.tar.gz` | **built here** from the kernel.org stable source |
| `mu300-openwrt-rootfs.tar.gz` | **built here**: ImmortalWrt base + the port's overlays + customization |
| `mu300-update` | reused byte-for-byte from the upstream release |
| `SHA256SUMS` | generated here |

The image ships Chinese LuCI, Argon as the default theme with Aurora retained, and
Asia/Shanghai with `country=CN`. It contains **no** VPN engine, no vendor firmware, no
Android subset, no GPU blobs, no device credentials and no host keys; those stay on the
device and are added by the installer.

Every input is checked against a pinned digest (or kernel.org's / ImmortalWrt's own
`sha256sums`) before it is used, and the finished set must pass `scripts/verify-output.py`
plus its four regression tests — a build that fails either gate publishes nothing.

## Triggers

| trigger | behaviour |
|---|---|
| `schedule` (daily 03:00 UTC) | resolves the current versions and builds **only if one changed** since the last successful build |
| `workflow_dispatch` | manual; can force a rebuild or override the kernel / ImmortalWrt versions and the upstream commit |
| `push` to `main` | when `scripts/**`, `inputs/**` or the workflow itself changes |

The build record lives in `state/last-build.json`, so the daily run is a no-op until a
dependency actually moves. Override examples for a manual run: `kv_stable=7.3.1`,
`wrt_ver=25.12.3`, `upstream_ref=<commit>`.

## How it runs

`runs-on: ubuntu-24.04-arm` — an **aarch64** runner, so Nothing is emulated: the kernel,
the out-of-tree vendor modules (31 of them) and the rootfs assembly all run natively, and
no cross compiler is needed. The repository therefore has to be **public**: the free ARM64
runners are not available to private repositories.

An x86_64 host works as well (`scripts/ci-build.sh` detects the architecture and
cross-compiles); that path additionally needs qemu/binfmt for the rootfs assembler.

```bash
# locally, with Docker available
WORK=$PWD bash scripts/ci-build.sh
```

Useful environment variables: `KV_STABLE`, `KV_LTS`, `WRT_VER`, `MU300_UPSTREAM_REF`,
`MU300_BUILD_JOBS` (1..8), `MU300_BUILD_IMAGE`, `MU300_KERNEL_MIRRORS`.

## Requirements

- Docker, git, curl, python3 and the usual coreutils.
- Network access to kernel.org (a mirror is used as a fallback; the digest always comes
  from kernel.org), downloads.immortalwrt.org, and GitHub.
- For the rootfs assembly the host needs to run aarch64 containers (native ARM64 runner,
  or qemu/binfmt on x86_64).

## Credits and licensing

The port itself — kernel patches, out-of-tree drivers, overlays, installer — is
[dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux), MIT licensed. The
ImmortalWrt base is an OpenWrt fork and keeps its own licences. See `PROVENANCE.md` for
the exact sources, digests and what is rebuilt versus reused.

This repository is an independent build harness around that work; it is not affiliated
with ImmortalWrt, OpenWrt or the upstream author.
