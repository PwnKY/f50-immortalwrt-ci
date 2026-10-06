# What every file is

Two things are documented here: the files **in this repository** (what they do, and whether
a human or the build writes them) and the files a **build produces** (the release assets and
the build record). If you only want to flash the result, read the release table at the end.

## In the repository

| file | written by | what it is |
|---|---|---|
| `.github/workflows/build.yml` | hand | The whole automation: resolves the versions, decides whether anything moved, builds on an aarch64 runner, uploads the result as an artifact and publishes it as a release. Two jobs: `plan` (cheap, resolves and decides) and `build` (the run). |
| `scripts/ci-build.sh` | hand | The build itself, from an empty workspace: fetch and verify every input, compile both kernels and their 31 out-of-tree modules, package the bundles, assemble the rootfs, run the checks. Runs natively on aarch64 or cross on x86_64. Callable locally (`WORK=$PWD bash scripts/ci-build.sh`). |
| `scripts/customize-rootfs.sh` | hand | The image customization, run by the rootfs assembler inside the build container: Chinese LuCI, Argon as the default theme with Aurora retained, `Asia/Shanghai` / `CST-8`, and the transactional removal of the whole-image upgrade packages. |
| `scripts/verify-output.py` | hand | The gate. Takes the finished asset directory and refuses it unless exactly six files with five consistent digests are present, the reused files are unchanged, each of the three module sets matches its bundle byte for byte, the settings are right, no upgrade payload or VPN engine slipped in, and the core packages are there. |
| `scripts/test-verify-output.py` | hand | Runs the verifier against four deliberately broken copies (an installed `owut`, an orphan upgrade UI, a replaced `sysupgrade`, a missing core package) and requires each to be rejected. Runs after the verifier in every build. |
| `scripts/local-adaptations.patch` | hand | The three changes this harness needs on top of the upstream tree: a parallelism cap, the customization mount and hook in the rootfs assembler, and a build-time IPv4 download wrapper. Applied to the fresh clone; if upstream changes those files the patch stops applying and the build **fails loudly** instead of producing an image without the customization. |
| `inputs/pins.json` | hand | Every version and digest that is pinned: the source repository and commit the build checks out (our mirror of the port), the upstream release the reused 5.4 bundle and updater come from, those two digests, the theme APK digests, and the ImmortalWrt release this was last validated against. |
| `state/last-build.json` | the workflow | The record of the last successful build (`key`, `release`, timestamp). The daily run compares its own key against this and does nothing when they match; the build job commits it back. |
| `PROVENANCE.md` | hand | Where every input comes from and how it is verified, what is rebuilt versus reused, what is deliberately absent, and what the verification does and does not prove. |
| `README.md` | hand | What the project is, what it produces, how it is triggered, how to run it locally, and the limits. |
| `FILES.md` | hand | This file. |
| `.gitignore` | hand | Keeps the build workspace out of the repository: the cloned source, the kernel trees, the downloaded inputs (except `pins.json`), the staging directory, the outputs and the logs. |
| `.gitattributes` | hand | Forces LF everywhere, so the shell scripts, the patch and the workflow keep working on Linux. |

## Produced by a build (never committed)

| path | what it is |
|---|---|
| `src/` | The upstream checkout, fetched at the pinned commit with the adaptation patch applied. |
| `kernel-src/` | The kernel.org tarballs (cached), the extracted `linux-<version>/` trees, and kernel.org's own `sha256sums` lists. |
| `inputs/` | Everything downloaded and checked: the ImmortalWrt base rootfs, the two theme APKs, the reused `mu300-kernel.tar.gz` and `mu300-update`, the 5.4 module set extracted from that bundle (`out/modules/`, `out/kernel.release`), the static `busybox`/`logdw`, and the compiled `tools/` helpers. |
| `custom/` | The staging directory the assembler mounts as `/custom`: `modules-5.4`, `modules-<lts>`, `modules-<stable>`, `themes/` and a copy of `customize-rootfs.sh`. |
| `dist/<release>/assets/v<wrt>/` | The six files below, plus `SHA256SUMS`. |
| `dist/<release>/BUILDINFO/` | The build record: `versions.json`, per-stage logs (`log-*.log`), each bundle's `kernel-*.release`, `kernel.org-releases.json`, `sha256sums-*.asc`, a copy of `scripts/` as executed, `build-image.json`, `final-assets.sha256` and `upstream-commit.txt`. Uploaded as the workflow artifact, not published as a release asset. |
| `versions.json`, `kernel.org-releases.json`, `immortalwrt-*-sha256sums`, `kernel-*.release`, `log-*.log` | Working files of one run, also copied into `BUILDINFO/`. |

## Release assets

Six files, about 61 MB together. `SHA256SUMS` covers the other five.

| file | size | provenance | what it is |
|---|---|---|---|
| `mu300-kernel.tar.gz` | 26.9 MB | reused from the upstream release, byte for byte | The vendor 5.4 kernel bundle. Also carries the static `busybox`/`logdw` and the 5.4 module set that goes into the image. |
| `mu300-kernel-7.2.tar.gz` | 9.6 MB | **built here** | Kernel 7.2.9, its 31 out-of-tree vendor modules and the generic ramdisk. The primary kernel. |
| `mu300-kernel-6.18.tar.gz` | 9.4 MB | **built here** | Kernel 6.18.55 the same way. The fallback. |
| `mu300-openwrt-rootfs.tar.gz` | 24.8 MB | **assembled here** | ImmortalWrt 25.12.2 with the port's overlays: Chinese LuCI, Argon default with Aurora retained, `Asia/Shanghai`, `country=CN`, the MU300 dashboard/SMS/LED work, the three module sets, no VPN engine, root password locked. |
| `mu300-update` | 38 KB | reused from the upstream release, byte for byte | The standalone updater. |
| `SHA256SUMS` | 440 B | generated here | Digests of the five files above. |

The installer adds the device-specific parts (vendor firmware, Android subset, GPU blobs)
from the phone itself; they are deliberately not in any of these files.

## Changing the pinned upstream commit

`inputs/pins.json` holds it. The build reads the port from our own mirror
(`PwnKY/mu300-linux-pin`, a verbatim copy of the upstream tree minus `stock/`, kept because
upstream deleted the branch the pinned commit was the tip of), so moving forward means:

1. Pick the upstream commit you want and check that the LED work is still present
   (`openwrt/overlay/www/luci-static/resources/view/system/leds.js`) — it exists only on the
   deleted branch, so a state that lacks it would drop the LED fix this firmware depends on.
2. Refresh the mirror with that tree (same verbatim copy, `stock/` excluded, `NOTICE.md`
   updated with the new provenance).
3. Point `upstream.repo`, `upstream.commit` and `upstream.mirror_of_commit` at it.
4. Run the build. If `scripts/local-adaptations.patch` no longer applies the error says so —
   regenerate the patch against the new tree before continuing.
