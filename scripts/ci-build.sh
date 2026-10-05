#!/usr/bin/env bash
# Build ImmortalWrt + mainline kernels for the ZTE F50 / MU300, in CI.
#
# Designed for an aarch64 runner (ubuntu-24.04-arm): the kernel, the out-of-tree
# vendor modules and the rootfs assembly all run native there, so no qemu/binfmt
# and no cross compiler are involved.
#
# Everything it needs comes from public sources and is checked against a pinned
# digest before it is used (inputs/pins.json + kernel.org's own sha256sums.asc).
# Nothing device-specific is used or produced: the vendor firmware, the Android
# subset and the GPU blobs are added by the installer on the device.
#
# Output: $WORK/dist/<release>/assets/<tag>/ with the six files and SHA256SUMS.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$PWD}
SRC=$WORK/src
KSRC=$WORK/kernel-src
IN=$WORK/inputs
OUT=$WORK/dist
JOBS=${MU300_BUILD_JOBS:-$(nproc)}
[[ "$JOBS" =~ ^[1-8]$ ]] || { echo "MU300_BUILD_JOBS must be 1..8" >&2; exit 1; }
# The runner is expected to be aarch64 (ubuntu-24.04-arm), where everything is native.
# An x86_64 host works too: the container then cross-compiles, which is how this was
# developed locally (it needs qemu/binfmt only for the rootfs assembler's arm64 steps).
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = aarch64 ]; then
    PLATFORM=()
    STATIC_CC=gcc
else
    PLATFORM=(--platform linux/amd64)
    STATIC_CC=aarch64-linux-gnu-gcc
fi
IMG=${MU300_BUILD_IMAGE:-mu300-mainline-build}

UPSTREAM_REPO=${MU300_UPSTREAM_REPO:-https://github.com/dikeckaan/mu300-linux}
UPSTREAM_REF=${MU300_UPSTREAM_REF:-}
# kernel.org is the source of truth for the digests even when a mirror is faster
KERNEL_BASE=https://cdn.kernel.org/pub/linux/kernel
KERNEL_MIRRORS=${MU300_KERNEL_MIRRORS:-https://mirrors.tuna.tsinghua.edu.cn/kernel}
IMM_BASE=https://downloads.immortalwrt.org/releases

say() { printf '\n==> %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is required"; }
# Transient network failures are normal on CI: retry instead of losing the whole run.
retry() { # retry TRIES COMMAND...
    local tries=$1 i=1; shift
    while :; do
        "$@" && return 0
        [ "$i" -ge "$tries" ] && return 1
        printf '  %s failed, retry %s/%s\n' "$1" "$i" "$tries" >&2
        i=$((i + 1)); sleep $((i * 5))
    done
}
for c in docker git curl python3 sha256sum tar; do need "$c"; done
# The rootfs assembler runs arm64 binaries (the base image it imports). On an aarch64 runner
# that is native; anywhere else qemu/binfmt has to be registered, and saying so here beats
# failing a hundred lines later inside the assembler. This needs the helpers above, so it
# sits after them.
if [ "$HOST_ARCH" != aarch64 ]; then
    if ! docker run --rm --platform linux/arm64 ubuntu:26.04 uname -m >/dev/null 2>&1; then
        die "this host cannot run arm64 containers; register qemu/binfmt first:
       docker run --privileged --rm tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0 --install arm64"
    fi
    say "arm64 execution is available on this $HOST_ARCH host"
fi

pin() { # pin <json path> -> value from inputs/pins.json
    python3 - "$HERE/inputs/pins.json" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    node = json.load(f)
for key in sys.argv[2].split('.'):
    node = node[key]
print(node)
PY
}

# ---------------------------------------------------------------- versions
say "resolving versions"
KJ=$WORK/kernel.org-releases.json
curl -fsSL --retry 3 https://www.kernel.org/releases.json -o "$KJ"
if [ -z "${KV_STABLE:-}" ]; then
    KV_STABLE=$(python3 - "$KJ" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["releases"]
print(next(x["version"] for x in r if x["moniker"]=="stable" and not x.get("iseol")))
PY
)
fi
if [ -z "${KV_LTS:-}" ]; then
    KV_LTS=$(python3 - "$KJ" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["releases"]
lt=[x["version"] for x in r if x["moniker"]=="longterm" and x["version"].startswith("6.18.")]
print(sorted(lt, key=lambda v: [int(p) for p in v.split(".")])[-1])
PY
)
fi
if [ -z "${WRT_VER:-}" ]; then
    WRT_VER=$(curl -fsSL --retry 3 "$IMM_BASE/" |
        sed -n 's/.*href="\(2[0-9]\.[0-9][0-9]\.[0-9][0-9]*\)\/".*/\1/p' |
        sort -V | tail -1)
fi
[ -n "$KV_STABLE" ] && [ -n "$KV_LTS" ] && [ -n "$WRT_VER" ] || die "could not resolve versions"
for v in "$KV_STABLE" "$KV_LTS" "$WRT_VER"; do
    case "$v" in *[!0-9.]*) die "unexpected version '$v'";; esac
done
KV_STABLE_SERIES=${KV_STABLE%.*}
KV_LTS_SERIES=${KV_LTS%.*}
[ "$KV_STABLE_SERIES" != "$KV_LTS_SERIES" ] || die "stable and LTS resolved to the same series"

if [ ! -d "$SRC/.git" ]; then
    say "cloning $UPSTREAM_REPO"
    retry 3 git clone --quiet "$UPSTREAM_REPO" "$SRC" || die "could not clone $UPSTREAM_REPO"
fi
retry 3 git -C "$SRC" fetch --quiet origin || die "could not fetch from $UPSTREAM_REPO"
UPSTREAM_REF=${UPSTREAM_REF:-$(pin upstream.commit)}
retry 3 git -C "$SRC" checkout --quiet --detach "$UPSTREAM_REF" || die "could not check out $UPSTREAM_REF"
# The build adaptations this harness needs: the parallelism cap, the customization mount and
# hook in the rootfs assembler, and the build-time IPv4 download wrapper. Kept as a patch so
# the upstream tree stays as published, and so a change on their side fails loudly here
# instead of silently producing an image without the customization.
PATCH=$HERE/scripts/local-adaptations.patch
if [ -f "$PATCH" ]; then
    if retry 3 git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
        retry 3 git -C "$SRC" apply "$PATCH" || die "could not apply $PATCH"
        say "local build adaptations applied"
    elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
        say "local build adaptations already applied"
    else
        die "$PATCH does not apply to $UPSTREAM_REF: the upstream files it touches changed.\n       Review the patch (scripts/local-adaptations.patch) against that commit."
    fi
fi
git -C "$SRC" rev-parse HEAD | grep -qx "$UPSTREAM_REF" || die "could not check out $UPSTREAM_REF"

REL=immortalwrt-$WRT_VER-k$KV_STABLE
ASSETS=$OUT/$REL/assets/v$WRT_VER
mkdir -p "$ASSETS" "$KSRC" "$IN/themes" "$IN/baseline"
MU300_VERSION=custom-immortalwrt-$WRT_VER-k$KV_STABLE-$(git -C "$SRC" rev-parse --short HEAD)
python3 - "$WORK/versions.json" <<PY
import json
json.dump({"immortalwrt": "$WRT_VER", "kernel_stable": "$KV_STABLE", "kernel_lts": "$KV_LTS",
           "upstream_commit": "$UPSTREAM_REF", "release": "$REL", "image_version": "$MU300_VERSION"},
          open("$WORK/versions.json", "w"), indent=2, sort_keys=True)
PY
cat "$WORK/versions.json"

# ---------------------------------------------------------------- container
say "build container ($IMG)"
docker build -q -t "$IMG" "$SRC/upstream" >/dev/null
# The upstream image carries gcc-aarch64-linux-gnu for the kernel, which needs no libc.
# The static helpers are normal user-space binaries, so a cross build also needs the arm64
# libc headers. A native aarch64 runner has them already.
if [ "$HOST_ARCH" != aarch64 ]; then
    cat > "$WORK/.ci-cross.Dockerfile" <<EOF
FROM $IMG
RUN apt-get update && apt-get install -y --no-install-recommends libc6-dev-arm64-cross \\
 && rm -rf /var/lib/apt/lists/*
EOF
    docker build -q -t "$IMG" -f "$WORK/.ci-cross.Dockerfile" "$WORK" >/dev/null
fi
docker run --rm "${PLATFORM[@]}" "$IMG" "$STATIC_CC" --version | head -1

# ---------------------------------------------------------------- inputs
fetch_checked() { # fetch_checked URL OUT SHA256
    local url=$1 out=$2 want=$3
    if [ -s "$out" ] && [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$want" ]; then
        echo "  cached $(basename "$out")"; return 0
    fi
    curl -fL --retry 3 -o "$out.part" "$url" || { rm -f "$out.part"; return 1; }
    local got; got=$(sha256sum "$out.part" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { rm -f "$out.part"; die "$(basename "$out"): sha256 $got, expected $want"; }
    mv "$out.part" "$out"
    echo "  fetched $(basename "$out")"
}

kernel_digest() { # kernel_digest VER -> digest from kernel.org (vX.x/sha256sums.asc)
    local v=$1 asc=$KSRC/sha256sums-${v%%.*}.x.asc
    [ -s "$asc" ] || curl -fsSL --retry 3 "$KERNEL_BASE/v${v%%.*}.x/sha256sums.asc" -o "$asc"
    awk -v f="linux-$v.tar.xz" '$2 == f {print $1}' "$asc"
}

fetch_kernel() { # fetch_kernel VER
    local v=$1 want
    want=$(kernel_digest "$v")
    [ -n "$want" ] || die "kernel.org has no digest for linux-$v.tar.xz"
    if [ ! -d "$KSRC/linux-$v" ]; then
        if ! fetch_checked "$KERNEL_BASE/v${v%%.*}.x/linux-$v.tar.xz" "$KSRC/linux-$v.tar.xz" "$want" 2>/dev/null; then
            echo "  kernel.org slow or unavailable, trying a mirror"
            local m ok=1
            for m in $KERNEL_MIRRORS; do
                fetch_checked "$m/v${v%%.*}.x/linux-$v.tar.xz" "$KSRC/linux-$v.tar.xz" "$want" && { ok=0; break; }
            done
            [ "$ok" = 0 ] || die "could not fetch linux-$v.tar.xz"
        fi
        tar -xJf "$KSRC/linux-$v.tar.xz" -C "$KSRC"
        rm -f "$KSRC/linux-$v.tar.xz"
    fi
    echo "  linux-$v ready"
}

say "kernel sources"
fetch_kernel "$KV_STABLE"
fetch_kernel "$KV_LTS"

say "firmware inputs"
UP_TAG=$(pin upstream.release)
# The ImmortalWrt digest comes from the release's own sha256sums (same trust model as
# kernel.org), so a new release builds without touching this file. The pinned digest is
# only used to warn when the release we validated has been republished.
IMM_SUMS=$WORK/immortalwrt-$WRT_VER-sha256sums
curl -fsSL --retry 3 "https://downloads.immortalwrt.org/releases/$WRT_VER/targets/armsr/armv8/sha256sums" -o "$IMM_SUMS" \
    || die "no sha256sums for ImmortalWrt $WRT_VER (is $WRT_VER a real release?)"
IMM_FILE=immortalwrt-$WRT_VER-armsr-armv8-rootfs.tar.gz
IMM_SHA=$(awk -v f="$IMM_FILE" '{n=$2; sub(/^\*/, "", n); if (n == f) print $1}' "$IMM_SUMS")
[ -n "$IMM_SHA" ] || die "$IMM_FILE is not in the ImmortalWrt sha256sums"
fetch_checked "https://downloads.immortalwrt.org/releases/$WRT_VER/targets/armsr/armv8/$IMM_FILE" \
    "$IN/$IMM_FILE" "$IMM_SHA"
fetch_checked "https://github.com/eamonxg/luci-theme-aurora/releases/download/$(pin themes.aurora.tag)/$(pin themes.aurora.file)" \
    "$IN/themes/$(pin themes.aurora.file)" "$(pin themes.aurora.sha256)"
fetch_checked "https://github.com/jerrykuku/luci-theme-argon/releases/download/$(pin themes.argon.tag)/$(pin themes.argon.file)" \
    "$IN/themes/$(pin themes.argon.file)" "$(pin themes.argon.sha256)"
# the 5.4 bundle and the updater are reused from the upstream release, not rebuilt:
# they carry the vendor 5.4 kernel the installer needs and the static busybox/logdw
fetch_checked "https://github.com/dikeckaan/mu300-linux/releases/download/$UP_TAG/mu300-kernel.tar.gz" \
    "$IN/baseline/mu300-kernel.tar.gz" "$(pin upstream.five4_bundle_sha256)"
fetch_checked "https://github.com/dikeckaan/mu300-linux/releases/download/$UP_TAG/mu300-update" \
    "$IN/baseline/mu300-update" "$(pin upstream.updater_sha256)"

# ---------------------------------------------------------------- static helpers
say "static helpers ($STATIC_CC)"
# Run as the invoking user: the container writes into the workspace, and files owned by
# root there would break the very next step (and would break a GitHub runner the same way).
docker run --rm "${PLATFORM[@]}" --user "$(id -u):$(id -g)" -v "$WORK":/w -w /w "$IMG" bash -eu -c "
    mkdir -p /w/inputs/tools/bt-init /w/inputs/tools/keys
    $STATIC_CC -O2 -static -o /w/inputs/tools/bt-init/mu300-bt-init /w/src/tools/bt-init/mu300-bt-init.c
    $STATIC_CC -O2 -static -o /w/inputs/tools/keys/mu300-keys /w/src/tools/keys/mu300-keys.c
    readelf -h /w/inputs/tools/bt-init/mu300-bt-init | grep -E 'Class|Machine' | sed 's/^/  bt-init /'
    readelf -h /w/inputs/tools/keys/mu300-keys | grep -E 'Class|Machine' | sed 's/^/  keys    /'"
# the 5.4 module set plus the static busybox and logdw come out of that bundle
tar -xzf "$IN/baseline/mu300-kernel.tar.gz" -C "$IN" ./modules ./busybox ./logdw
mkdir -p "$IN/out" "$IN/tools/logdw"
rm -rf "$IN/out/modules"
mv "$IN/modules" "$IN/out/modules"
mv "$IN/logdw" "$IN/tools/logdw/logdw"
chmod 755 "$IN/busybox" "$IN/tools/logdw/logdw"
# the 5.4 bundle carries no ./kernel.release: derive it from a module, as the verifier does
if [ ! -s "$IN/out/kernel.release" ]; then
    m=$(tar -tzf "$IN/baseline/mu300-kernel.tar.gz" | sed -n 's|^\./modules/\([^/]*\.ko\)$|\1|p' | head -1)
    [ -n "$m" ] || die "no modules in the 5.4 bundle"
    tar -xzOf "$IN/baseline/mu300-kernel.tar.gz" "./modules/$m" |
        tr '\0' '\n' | sed -n 's/^vermagic=\([^ ]*\) .*/\1/p' > "$IN/out/kernel.release"
fi
printf '  5.4 modules: %s, release: %s\n' "$(ls "$IN/out/modules"/*.ko | wc -l)" "$(cat "$IN/out/kernel.release")"

# ---------------------------------------------------------------- kernels
run_kernel() { # run_kernel KV OUTDIR SCRIPT
    local kv=$1 outdir=$2 script=$3
    local args=(-e "KV=$kv" -e "MU300_BUILD_JOBS=$JOBS")
    [ -z "$outdir" ] || args+=(-e "OUTDIR=$outdir")
    docker run --rm "${PLATFORM[@]}" --cpus "$JOBS" -v "$KSRC":/src -v "$SRC/upstream":/work "${args[@]}" "$IMG" bash "/work/$script"
}

say "kernel $KV_STABLE (primary, mainline stable series)"
run_kernel "$KV_STABLE" "out-$KV_STABLE" build.sh | tee "$WORK/log-kernel-$KV_STABLE-build.log"
run_kernel "$KV_STABLE" "out-$KV_STABLE" build-modules.sh | tee "$WORK/log-kernel-$KV_STABLE-modules.log"
say "kernel $KV_LTS (fallback, longterm series)"
run_kernel "$KV_LTS" "" build.sh | tee "$WORK/log-kernel-$KV_LTS-build.log"
run_kernel "$KV_LTS" "" build-modules.sh | tee "$WORK/log-kernel-$KV_LTS-modules.log"

# make-bundle.sh derives the checkout root from its own path ($0), so it is called through
# the path the repository is mounted at ($WORK/src/upstream), not through the bind mount
# of upstream/ alone: with /work/make-bundle.sh the root would resolve to / instead of /w/src.
say "kernel bundles"
docker run --rm "${PLATFORM[@]}" -e MU300_UPSTREAM_OUT=/w/src/upstream/out-$KV_STABLE -v "$WORK":/w "$IMG" \
    sh /w/src/upstream/make-bundle.sh "/w/dist/$REL/assets/v$WRT_VER/mu300-kernel-$KV_STABLE_SERIES.tar.gz" /w/inputs/baseline/mu300-kernel.tar.gz \
    | tee "$WORK/log-bundle-$KV_STABLE.log"
docker run --rm "${PLATFORM[@]}" -e MU300_UPSTREAM_OUT=/w/src/upstream/out -v "$WORK":/w "$IMG" \
    sh /w/src/upstream/make-bundle.sh "/w/dist/$REL/assets/v$WRT_VER/mu300-kernel-$KV_LTS_SERIES.tar.gz" /w/inputs/baseline/mu300-kernel.tar.gz \
    | tee "$WORK/log-bundle-$KV_LTS.log"
for pair in "$KV_STABLE:$KV_STABLE_SERIES" "$KV_LTS:$KV_LTS_SERIES"; do
    kv=${pair%%:*}; series=${pair##*:}
    tar -xzOf "$ASSETS/mu300-kernel-$series.tar.gz" ./kernel.release > "$WORK/kernel-$series.release"
    [ -s "$WORK/kernel-$series.release" ] || die "no kernel.release in the $series bundle"
    printf '  %s -> %s\n' "$series" "$(cat "$WORK/kernel-$series.release")"
done

# ---------------------------------------------------------------- rootfs
say "rootfs customization inputs"
C=$WORK/custom
rm -rf "$C"
mkdir -p "$C/themes" "$C/modules-5.4" "$C/modules-$KV_LTS_SERIES" "$C/modules-$KV_STABLE_SERIES"
cp "$HERE/scripts/customize-rootfs.sh" "$C/"
cp "$IN"/themes/*.apk "$C/themes/"
cp -a "$IN/out/." "$C/modules-5.4/"                                          # 5.4: reused modules
cp -a "$SRC/upstream/out/." "$C/modules-$KV_LTS_SERIES/"                     # LTS: fresh build
cp "$WORK/kernel-$KV_LTS_SERIES.release" "$C/modules-$KV_LTS_SERIES/kernel.release"
cp -a "$SRC/upstream/out-$KV_STABLE/." "$C/modules-$KV_STABLE_SERIES/"       # stable: fresh build
cp "$WORK/kernel-$KV_STABLE_SERIES.release" "$C/modules-$KV_STABLE_SERIES/kernel.release"
for d in "$C"/modules-*; do
    [ -s "$d/kernel.release" ] || die "missing kernel.release in $d"
    ls "$d"/modules/*.ko >/dev/null || die "no modules in $d"
    printf '  %-22s %s modules, release %s\n' "$(basename "$d")" "$(ls "$d"/modules/*.ko | wc -l)" "$(cat "$d/kernel.release")"
done

say "assembling the ImmortalWrt rootfs"
# build-rootfs.sh downloads the base itself into openwrt/ and verifies it against the base
# repository; pre-placing the file we already checked keeps that download from happening twice.
cp -f "$IN/$IMM_FILE" "$SRC/openwrt/$IMM_FILE"
MU300_INPUTS="$IN" MU300_MAINLINE_OUT="$SRC/upstream/out-$KV_STABLE" \
MU300_FLAVOUR=immortalwrt MU300_WRT_VER="$WRT_VER" \
MU300_LUCI_THEME_APK="$IN/themes/$(pin themes.aurora.file)" \
MU300_CUSTOMIZE_DIR="$C" MU300_VERSION="$MU300_VERSION" \
    "$SRC/openwrt/build-rootfs.sh" mu300-openwrt-rootfs.tar.gz | tee "$WORK/log-rootfs.log"
cp "$SRC/openwrt/mu300-openwrt-rootfs.tar.gz" "$ASSETS/"
cp "$IN/baseline/mu300-kernel.tar.gz" "$IN/baseline/mu300-update" "$ASSETS/"

# ---------------------------------------------------------------- verify
say "checksums and verification"
(cd "$ASSETS" && sha256sum mu300-kernel.tar.gz "mu300-kernel-$KV_LTS_SERIES.tar.gz" \
    "mu300-kernel-$KV_STABLE_SERIES.tar.gz" mu300-openwrt-rootfs.tar.gz mu300-update > SHA256SUMS)
(cd "$ASSETS" && sha256sum -c SHA256SUMS)
python3 "$HERE/scripts/verify-output.py" "$ASSETS" | tee "$WORK/log-output-validation.txt"
python3 "$HERE/scripts/test-verify-output.py" "$ASSETS" | tee "$WORK/log-verify-regression.txt"
grep -q '^PASS' "$WORK/log-output-validation.txt" || die "output verification failed"
[ "$(grep -c '^PASS' "$WORK/log-verify-regression.txt")" -ge 4 ] || die "regression tests failed"

say "build info"
B=$OUT/$REL/BUILDINFO
mkdir -p "$B"
cp "$WORK/versions.json" "$WORK"/log-*.log "$B/" 2>/dev/null || true
cp "$WORK"/kernel-*.release "$B/"
cp "$KJ" "$B/kernel.org-releases.json"
cp "$KSRC"/sha256sums-*.asc "$B/" 2>/dev/null || true
cp -a "$HERE/scripts" "$B/scripts"
docker image inspect "$IMG" > "$B/build-image.json"
(cd "$ASSETS" && cat SHA256SUMS) > "$B/final-assets.sha256"
git -C "$SRC" log -1 --format='%H %cd %s' --date=iso > "$B/upstream-commit.txt"

printf '\nBuilt and verified, NOT flashed: %s\n' "$OUT/$REL"
