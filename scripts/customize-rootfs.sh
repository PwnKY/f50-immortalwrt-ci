#!/bin/sh
# Runs ONLY at the end of the upstream rootfs assembler, inside its ARM64 container.
set -eu
R=${1:?rootfs directory required}
[ "$R" = /build/root ] || exit 1
# apk executes from the ARM64 live container; only signed official repositories
# provide Chinese packages. Pinned third-party themes are the sole unsigned APKs.
apk --root "$R" update
apk --root "$R" add luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn
apk --root "$R" add --allow-untrusted /custom/themes/luci-theme-argon-2.4.7-r1.apk
[ -s "$R/www/luci-static/argon/cascade.css" ] || [ -s "$R/www/luci-static/argon/css/cascade.css" ]
[ -s "$R/www/luci-static/aurora/main.css" ]
# Upstream's best-effort multi-name deletion is atomic when owut is absent.
# Select ONLY installed names. Never force dependencies or edit the APK database.
DB="$R/lib/apk/db/installed"
LOG=/out/custom-package-removal
awk '/^P:/ { print substr($0, 3) }' "$DB" | sort > "$LOG.before.txt"
awk '$0 == "attendedsysupgrade-common" || $0 == "luci-app-attendedsysupgrade" ||
     /^luci-i18n-attendedsysupgrade-/ || $0 == "owut" || $0 == "procd-ujail"' \
    "$LOG.before.txt" > "$LOG.requested.txt"
# On this base procd-seccomp is a hard dependency of base-files. Keep it when
# APK cannot remove it normally; it is safe to retain for the rebuilt 6.18.
if grep -qx procd-seccomp "$LOG.before.txt"; then
    apk --root "$R" info -r procd-seccomp > "$LOG.seccomp-dependents.txt"
    apk --root "$R" --simulate del procd-seccomp > "$LOG.seccomp-simulation.txt" 2>&1
    if grep -q 'Purging procd-seccomp ' "$LOG.seccomp-simulation.txt"; then
        echo procd-seccomp >> "$LOG.requested.txt"
    else
        awk 'NR > 1 && NF { found=1 } END { exit !found }' "$LOG.seccomp-dependents.txt"
        echo 'Retaining procd-seccomp: hard reverse dependencies (see record).'
    fi
fi
sort -o "$LOG.requested.txt" "$LOG.requested.txt"
set -- $(cat "$LOG.requested.txt")
if [ "$#" -gt 0 ]; then
    apk --root "$R" --simulate del "$@" > "$LOG.simulation.txt" 2>&1
    cat "$LOG.simulation.txt"
    # Fail closed on ANY extra auto-removal or solver addition/upgrade. This
    # also refuses a solver that leaves any requested package installed.
    awk '$2 == "Purging" { print $3 }' "$LOG.simulation.txt" | sort > "$LOG.simulated.txt"
    cmp "$LOG.requested.txt" "$LOG.simulated.txt"
    if grep -Eq ' (Installing|Upgrading|Downgrading|Reinstalling) ' "$LOG.simulation.txt"; then
        echo 'Unexpected package solver additions/changes; refusing transaction.' >&2
        exit 1
    fi
    apk --root "$R" del "$@" > "$LOG.transaction.txt" 2>&1
    cat "$LOG.transaction.txt"
else
    echo 'No installed removal candidates.' > "$LOG.simulation.txt"
fi
awk '/^P:/ { print substr($0, 3) }' "$DB" | sort > "$LOG.after.txt"
awk 'FILENAME == ARGV[1] { removed[$0]=1; next } !($0 in removed)' \
    "$LOG.requested.txt" "$LOG.before.txt" > "$LOG.expected.txt"
cmp "$LOG.expected.txt" "$LOG.after.txt"
if grep -Eq '^(attendedsysupgrade-common|luci-app-attendedsysupgrade|luci-i18n-attendedsysupgrade-.*|owut|procd-ujail)$' "$LOG.after.txt"; then
    echo 'Forbidden package still installed after removal.' >&2
    exit 1
fi
for core in base-files luci luci-base luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system luci-app-firewall luci-app-package-manager firewall4 netifd procd rpcd uhttpd dnsmasq-full; do
    grep -qx "$core" "$LOG.after.txt"
done
# Keep the project's refusing wrapper, not the whole-disk armsr upgrader.
cmp "$R/sbin/sysupgrade" /in/overlay/usr/libexec/mu300-sysupgrade
unexpected=$(find "$R" \( -iname '*attendedsysupgrade*' -o -name owut -o -name 'owut.*' -o -name 11_upgrades.js -o -name ujail \) -print)
[ -z "$unexpected" ] || { echo "Forbidden online-upgrade/jail payload: $unexpected" >&2; exit 1; }
uci -c "$R/etc/config" set luci.main.lang=zh_cn
uci -c "$R/etc/config" set luci.main.mediaurlbase=/luci-static/argon
uci -c "$R/etc/config" set luci.main.resourcebase=/luci-static/resources
uci -c "$R/etc/config" set luci.languages.zh_cn='简体中文'
# armsr ships no system config until first boot. Seed only its generic defaults;
# do not run board_detect/config_generate against the builder hardware.
if ! uci -c "$R/etc/config" -q get system.@system[0] >/dev/null; then
    touch "$R/etc/config/system"
    uci -c "$R/etc/config" add system system >/dev/null
    uci -c "$R/etc/config" set system.@system[0].hostname=mu300
    uci -c "$R/etc/config" set system.@system[0].ttylogin=0
    uci -c "$R/etc/config" set system.@system[0].log_size=128
    uci -c "$R/etc/config" set system.@system[0].urandom_seed=0
    uci -c "$R/etc/config" set system.ntp=timeserver
    uci -c "$R/etc/config" set system.ntp.enabled=1
    uci -c "$R/etc/config" set system.ntp.enable_server=0
    for server in ntp.tencent.com ntp1.aliyun.com ntp.ntsc.ac.cn cn.ntp.org.cn; do
        uci -c "$R/etc/config" add_list system.ntp.server="$server"
    done
fi
uci -c "$R/etc/config" set system.@system[0].zonename=Asia/Shanghai
uci -c "$R/etc/config" set system.@system[0].timezone=CST-8
uci -c "$R/etc/config" commit luci
uci -c "$R/etc/config" commit system
# The upstream first-boot defaults must not revert the chosen timezone/theme.
sed -i -e 's@Europe/Istanbul@Asia/Shanghai@g' -e 's@<+03>-3@CST-8@g' "$R/etc/uci-defaults/90-mu300"
cat > "$R/etc/uci-defaults/99-mu300-immortal-localization" <<'EOF'
#!/bin/sh
uci set luci.main.lang='zh_cn'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit luci
uci commit system
exit 0
EOF
chmod 755 "$R/etc/uci-defaults/99-mu300-immortal-localization"
# Exact release identity and vermagic come from the distributed bundles, not guesses.
# Validate every module; copying does NOT relax upstream package/vermagic checks.
for input in /custom/modules-5.4 /custom/modules-6.18 /custom/modules-7.2; do
    krel=$(cat "$input/kernel.release")
    [ -n "$krel" ]
    case "$input:$krel" in
        /custom/modules-5.4:5.4.*|/custom/modules-6.18:6.18.*|/custom/modules-7.2:7.2.*) ;;
        *) echo "Unexpected kernel release: $input:$krel" >&2; exit 1 ;;
    esac
    mkdir -p "$R/lib/modules/$krel"
    for module in "$input"/modules/*.ko; do
        v=$(tr '\000' '\n' < "$module" | sed -n 's/^vermagic=\([^ ]*\) .*/\1/p')
        [ "$v" = "$krel" ] || { echo "vermagic mismatch: $module ($v != $krel)" >&2; exit 1; }
        cp "$module" "$R/lib/modules/$krel/"
    done
    for f in modules.builtin modules.builtin.modinfo; do
        [ ! -f "$input/$f" ] || cp "$input/$f" "$R/lib/modules/$krel/"
    done
done
# Generic distributable: no device imports or credentials. Upstream installers
# set local accounts later. Do not change mu300-update's network/apply behaviour.
rm -f "$R/etc/dropbear/"*key "$R/etc/ssh/ssh_host_"* "$R/etc/machine-id" "$R/var/lib/dbus/machine-id" "$R/.dockerenv"
rm -rf "$R/root/.ssh" "$R/opt/mu300/android"
awk -F: 'BEGIN { OFS=":" } { if ($1=="root") $2="!"; print }' "$R/etc/shadow" > "$R/etc/shadow.generic"
chmod 600 "$R/etc/shadow.generic"
mv "$R/etc/shadow.generic" "$R/etc/shadow"
for prohibited in sing-box xray hev-socks5-tunnel; do
    [ ! -e "$R/opt/mu300/bin/$prohibited" ] || { echo "Unrequested VPN binary present: $prohibited" >&2; exit 1; }
done
[ ! -d "$R/lib/firmware" ] || {
    # Only signed public regulatory data are permitted, no imported vendor blobs.
    unexpected=$(find "$R/lib/firmware" -type f ! -name regulatory.db ! -name regulatory.db.p7s -print)
    [ -z "$unexpected" ] || { echo "Unexpected firmware: $unexpected" >&2; exit 1; }
}
grep -q "DISTRIB_ARCH=.aarch64_generic." "$R/etc/openwrt_release"
grep -q "DISTRIB_RELEASE=.25.12.2." "$R/etc/openwrt_release"
apk --root "$R" info -v > /out/custom-packages.txt
: > /out/custom-repositories.txt
for repo in "$R/etc/apk/repositories" "$R/etc/apk/repositories.d/"*; do
    [ ! -f "$repo" ] || { printf '\n# %s\n' "$repo" >> /out/custom-repositories.txt; cat "$repo" >> /out/custom-repositories.txt; }
done
sha256sum "$R/etc/apk/keys/"* > /out/custom-apk-key-hashes.txt
