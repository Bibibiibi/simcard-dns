#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Literal assertions; globals are read by sourced functions.
# A host installed under the old 5GPN-X names (/opt/5gpn, /etc/5gpn, 5gpn-*
# units) is moved to the simcard-dns layout by --upgrade: paths, unit names,
# enablement links, certbot hooks and every reference inside project files.
# The Let's Encrypt lineage keeps its name, and a failure restores the old tree.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }

# --- static wiring (any OS) ------------------------------------------------------
grep -qF 'migrate_legacy_layout ||' "${root}/install.sh" || fail "--upgrade must migrate the old layout first"
awk '/^main_upgrade\(\)/,/^}/' "${root}/install.sh" | head -5 | grep -q migrate_legacy_layout \
    || fail "migration must run before the installation sanity checks"
grep -qF -- '-f "${LEGACY_RUNTIME_DIR}/bin/5gpn-ctl"' "${root}/install.sh" || fail "the one-line installer must treat an old layout as an upgrade"
grep -qE 'for _mod in .* migrate; do' "${root}/install.sh" || fail "install.sh must source lib/migrate.sh"
grep -qF 'lib/migrate.sh' "${root}/install.sh" || fail "bootstrap must require lib/migrate.sh"

# Wildcard lineage: new installs get the new name, migrated hosts keep theirs.
lineage() { (PGW_LE_LIVE="$1"; eval "$(sed -n '/^LE_LIVE_DIR=/,/^fi$/p' "${root}/lib/cert.sh")"; echo "$CF_CERT_NAME"); }
mkdir -p "${tmp}/live-new" "${tmp}/live-old/5gpn-wildcard"
[[ "$(lineage "${tmp}/live-new")" == simcard-dns-wildcard ]] || fail "fresh hosts must issue simcard-dns-wildcard"
[[ "$(lineage "${tmp}/live-old")" == 5gpn-wildcard ]] || fail "migrated hosts must keep renewing 5gpn-wildcard"

if [[ "$(uname -s)" != Linux ]]; then
    echo "migrate legacy layout: filesystem test skipped (needs GNU coreutils)"
    echo "migrate legacy layout policy OK"
    exit 0
fi

info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
# shellcheck source=lib/migrate.sh
. "${root}/lib/migrate.sh"

log="${tmp}/systemctl.log"
systemctl() {
    echo "$*" >> "$log"
    case "$1" in
        list-units) printf '5gpn-tgbot.service loaded active running x\ndot-gate.service loaded active running x\n5gpn-mihomo@smart.service loaded active running x\n' ;;
        start) [[ ! -f "${tmp}/fail-start" || "$2" != simcard-dns-tgbot.service ]] ;;
    esac
}
nft() { echo "nft $*" >> "${tmp}/nft.log"; }

build_legacy() {
    R="${tmp}/root"; rm -rf "$R"; mkdir -p "$R"
    local sd="$R/etc/systemd/system"
    mkdir -p "$R/opt/5gpn/bin" "$R/opt/5gpn/etc" "$R/opt/5gpn/www" "$R/etc/5gpn/exits" \
        "$sd/multi-user.target.wants" "$sd/timers.target.wants" "$sd/5gpn-tgbot.service.d" \
        "$R/etc/letsencrypt/renewal" "$R/etc/letsencrypt/renewal-hooks/pre" "$R/etc/letsencrypt/live/5gpn-wildcard" \
        "$R/usr/local/bin" "$R/etc/security" "$R/etc/sysctl.d" "$R/var/lib/5gpn" "$R/var/lib/5gpn-quic" \
        "$R/var/backups/5gpn/upgrade.abc" "$R/etc/mosdns" "$R/opt/simcard-dns"
    printf '#!/bin/bash\nBASE_DIR=/opt/5gpn\n' > "$R/opt/5gpn/bin/5gpn-ctl"
    echo 'RULES_PATH = "/etc/5gpn/rules.conf"' > "$R/opt/5gpn/bin/tgbot.py"
    printf '\x00\x01/opt/5gpn binary' > "$R/opt/5gpn/bin/mihomo"
    echo d.example.net > "$R/opt/5gpn/etc/.domain"
    echo old-commit > "$R/opt/5gpn/.installed-commit"
    printf 'TG_BOT_TOKEN=x\nMGMT=/opt/5gpn/bin/5gpn-ctl\n' > "$R/opt/5gpn/etc/tgbot.env"
    echo '<string>com.5gpn.d.example.net</string>' > "$R/opt/5gpn/www/ios-dot.mobileconfig"
    echo 'path: /etc/5gpn/rulesets/x.mrs' > "$R/etc/5gpn/exits/smart.yaml"
    echo 'dns_cloudflare_api_token = secret' > "$R/etc/5gpn/cloudflare.ini"
    echo 'table inet pgw_exit {}' > "$R/etc/5gpn/pgw-exit.nft"
    printf 'flush ruleset\ninclude "/etc/5gpn/geo-allow.nft"\ninclude "/etc/5gpn/pgw-exit.nft"\n' > "$R/etc/nftables.conf"
    printf '[Service]\nEnvironmentFile=/opt/5gpn/etc/tgbot.env\nExecStart=/usr/bin/python3 /opt/5gpn/bin/tgbot.py\n' > "$sd/5gpn-tgbot.service"
    printf '[Service]\nNice=5\n' > "$sd/5gpn-tgbot.service.d/override.conf"
    printf '[Service]\nWorkingDirectory=/opt/5gpn/etc/mihomo/%%i\n' > "$sd/5gpn-mihomo@.service"
    printf '[Service]\nExecStart=/opt/5gpn/bin/5gpn-ctl --geo-allow update\n' > "$sd/5gpn-geo-update.service"
    printf '[Timer]\nOnCalendar=daily\n' > "$sd/5gpn-geo-update.timer"
    printf '[Service]\nExecStart=/usr/bin/python3 /opt/5gpn/bin/dot-gate.py\n' > "$sd/dot-gate.service"
    printf '[Service]\nExecStart=/opt/5gpn/bin/quic-proxy -dns-file /var/lib/5gpn-quic/remote-dns\n' > "$sd/quic-proxy.service"
    ln -s /etc/systemd/system/5gpn-tgbot.service "$sd/multi-user.target.wants/5gpn-tgbot.service"
    ln -s /etc/systemd/system/5gpn-geo-update.timer "$sd/timers.target.wants/5gpn-geo-update.timer"
    ln -s /etc/systemd/system/dot-gate.service "$sd/multi-user.target.wants/dot-gate.service"
    printf 'archive_dir = /etc/letsencrypt/archive/5gpn-wildcard\ncert = /etc/letsencrypt/live/5gpn-wildcard/cert.pem\ndns_cloudflare_credentials = /etc/5gpn/cloudflare.ini\npre_hook = /usr/local/bin/5gpn-open-cert-http.sh\n' \
        > "$R/etc/letsencrypt/renewal/5gpn-wildcard.conf"
    echo '/usr/local/bin/5gpn-open-cert-http.sh' > "$R/etc/letsencrypt/renewal-hooks/pre/10-5gpn-open-http.sh"
    printf '#!/bin/sh\nnft insert rule inet filter input tcp dport 80 accept comment "5gpn-cert-http"\n' > "$R/usr/local/bin/5gpn-open-cert-http.sh"
    printf '#!/bin/sh\ncat /opt/5gpn/etc/current-exit\nsystemctl start 5gpn-mihomo@smart\n' > "$R/usr/local/bin/5gpn-apply-exit.sh"
    echo 'echo /opt/5gpn' > "$R/usr/local/bin/unrelated-tool"
    printf '# 5gpn-limits\n* soft nofile 65535\n' > "$R/etc/security/limits.conf"
    echo 'net.ipv4.ip_forward=1' > "$R/etc/sysctl.d/99-5gpn.conf"
    echo '{"offset": 1}' > "$R/var/lib/5gpn/tgbot-state.json"
    echo 8.8.8.8 > "$R/var/lib/5gpn-quic/remote-dns"
    echo keep > "$R/var/backups/5gpn/upgrade.abc/config-code.tar.gz"
    echo 'attempt' > "$R/opt/simcard-dns/.install-attempt"
    export PGW_MIGRATE_ROOT="$R"
}

# --- happy path ------------------------------------------------------------------------
build_legacy
: > "$log"
migrate_legacy_layout || fail "migration must succeed"
sd="$R/etc/systemd/system"
for gone in opt/5gpn etc/5gpn var/lib/5gpn var/lib/5gpn-quic var/backups/5gpn etc/sysctl.d/99-5gpn.conf \
    usr/local/bin/5gpn-apply-exit.sh etc/systemd/system/5gpn-tgbot.service etc/letsencrypt/renewal-hooks/pre/10-5gpn-open-http.sh; do
    [[ ! -e "$R/$gone" && ! -L "$R/$gone" ]] || fail "old path must be gone: $gone"
done
[[ ! -e "$R/opt/simcard-dns/bin/5gpn-ctl" ]] || fail "the old CLI name must be gone"
grep -qx 'BASE_DIR=/opt/simcard-dns' "$R/opt/simcard-dns/bin/simcard-dns" || fail "the old CLI must keep working under the new name"
grep -q '/etc/simcard-dns/rules.conf' "$R/opt/simcard-dns/bin/tgbot.py" || fail "old programs restarted before the upgrade must use new paths"
grep -q '/opt/5gpn binary' "$R/opt/simcard-dns/bin/mihomo" || fail "binaries must not be rewritten"
for there in opt/simcard-dns/bin/simcard-dns opt/simcard-dns/etc/.domain etc/simcard-dns/cloudflare.ini var/lib/simcard-dns/tgbot-state.json \
    var/lib/simcard-dns-quic/remote-dns var/backups/simcard-dns/upgrade.abc/config-code.tar.gz etc/sysctl.d/99-simcard-dns.conf \
    usr/local/bin/simcard-dns-apply-exit.sh usr/local/bin/simcard-dns-open-cert-http.sh \
    etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh etc/systemd/system/simcard-dns-tgbot.service.d/override.conf \
    etc/systemd/system/simcard-dns-mihomo@.service etc/systemd/system/simcard-dns-geo-update.timer; do
    [[ -e "$R/$there" ]] || fail "new path must exist: $there"
done
[[ "$(cat "$R/opt/simcard-dns/.install-attempt")" == attempt ]] || fail "the bootstrap attempt marker must survive"
[[ "$(cat "$R/opt/simcard-dns/.installed-commit")" == old-commit ]] || fail "the installed-commit marker must move along"
grep -qx 'MGMT=/opt/simcard-dns/bin/simcard-dns' "$R/opt/simcard-dns/etc/tgbot.env" || fail "the bot must call the new CLI"
grep -q 'com.simcard-dns.d.example.net' "$R/opt/simcard-dns/www/ios-dot.mobileconfig" || fail "the iOS profile identifier must change"
grep -q '/etc/simcard-dns/rulesets/x.mrs' "$R/etc/simcard-dns/exits/smart.yaml" || fail "smart config paths must follow"
grep -q 'include "/etc/simcard-dns/pgw-exit.nft"' "$R/etc/nftables.conf" || fail "nftables includes must follow"
grep -q 'include "/etc/simcard-dns/geo-allow.nft"' "$R/etc/nftables.conf" || fail "geo include must follow"
grep -q 'ExecStart=/opt/simcard-dns/bin/simcard-dns --geo-allow update' "$sd/simcard-dns-geo-update.service" || fail "timer service must call the new CLI"
grep -q '/opt/simcard-dns/bin/dot-gate.py' "$sd/dot-gate.service" || fail "units not named 5gpn must have their paths rewritten"
grep -q '/var/lib/simcard-dns-quic/remote-dns' "$sd/quic-proxy.service" || fail "quic state path must follow"
renewal="$R/etc/letsencrypt/renewal/5gpn-wildcard.conf"
[[ -f "$renewal" && -d "$R/etc/letsencrypt/live/5gpn-wildcard" ]] || fail "the certificate lineage must keep its name"
grep -q 'archive/5gpn-wildcard' "$renewal" || fail "lineage archive path must stay"
grep -q 'live/5gpn-wildcard/cert.pem' "$renewal" || fail "lineage live path must stay"
grep -q 'dns_cloudflare_credentials = /etc/simcard-dns/cloudflare.ini' "$renewal" || fail "renewal must find the moved Cloudflare token"
grep -q 'pre_hook = /usr/local/bin/simcard-dns-open-cert-http.sh' "$renewal" || fail "renewal hooks must follow"
grep -q 'simcard-dns-cert-http' "$R/usr/local/bin/simcard-dns-open-cert-http.sh" || fail "helper scripts must be rewritten"
grep -q 'simcard-dns-mihomo@smart' "$R/usr/local/bin/simcard-dns-apply-exit.sh" || fail "exit script must start the renamed unit"
grep -q '# simcard-dns-limits' "$R/etc/security/limits.conf" || fail "limits marker must follow (no duplicate block later)"
grep -q /opt/5gpn "$R/usr/local/bin/unrelated-tool" || fail "files the project did not write must be left alone"
link="$sd/multi-user.target.wants/simcard-dns-tgbot.service"
[[ -L "$link" && "$(readlink "$link")" == /etc/systemd/system/simcard-dns-tgbot.service ]] || fail "enablement must follow the renamed unit"
[[ -L "$sd/timers.target.wants/simcard-dns-geo-update.timer" ]] || fail "timer enablement must follow"
[[ "$(readlink "$sd/multi-user.target.wants/dot-gate.service")" == /etc/systemd/system/dot-gate.service ]] || fail "other links stay"
[[ -z "$(find "$sd" -name '*5gpn*')" ]] || fail "no 5gpn unit names may remain"
leftover="$(grep -rlI 5gpn "$R/opt/simcard-dns" "$R/etc/simcard-dns" "$sd" "$R/etc/nftables.conf" "$R/usr/local/bin"/simcard-dns-* || true)"
[[ -z "$leftover" ]] || fail "old names must not remain in project files: $leftover"
for u in simcard-dns-tgbot.service dot-gate.service simcard-dns-mihomo@smart.service; do
    grep -qx "start $u" "$log" || fail "previously active $u must be started under its new name"
done
grep -qx 'stop 5gpn-tgbot.service' "$log" || fail "old units must be stopped before moving"
ls "$R"/var/backups/simcard-dns/migrate.*/legacy.tar.gz >/dev/null || fail "the old layout must be archived"
listing="$(tar -tzf "$R"/var/backups/simcard-dns/migrate.*/legacy.tar.gz)"
grep -q '^opt/5gpn/etc/tgbot.env' <<< "$listing" || fail "archive must hold the old runtime"
migrate_legacy_layout || fail "a second run on a migrated host must be a no-op"

# --- failure restores the old layout -----------------------------------------------------
build_legacy
: > "$log"; touch "${tmp}/fail-start"
migrate_legacy_layout 2>/dev/null && fail "a unit that fails to start must fail the migration"
rm -f "${tmp}/fail-start"
[[ -f "$R/opt/5gpn/etc/tgbot.env" && -f "$R/etc/5gpn/cloudflare.ini" && -f "$R/etc/systemd/system/5gpn-tgbot.service" ]] \
    || fail "failure must restore the old files"
grep -qx 'MGMT=/opt/5gpn/bin/5gpn-ctl' "$R/opt/5gpn/etc/tgbot.env" || fail "restored files must have their old contents"
[[ -L "$R/etc/systemd/system/multi-user.target.wants/5gpn-tgbot.service" ]] || fail "old enablement must be restored"
[[ ! -e "$R/opt/simcard-dns/etc" && ! -e "$R/etc/simcard-dns" ]] || fail "half-moved new paths must be removed"
[[ -z "$(find "$R/etc/systemd/system" -name '*simcard-dns*')" ]] || fail "renamed units must be removed on failure"
grep -qx 'start 5gpn-tgbot.service' "$log" || fail "old units must be restarted after a failed migration"

# --- a bare /opt/5gpn (attempt marker only) is not an old install ---------------------------
R="${tmp}/bare"; rm -rf "$R"; mkdir -p "$R/opt/5gpn" "$R/opt/simcard-dns/etc"
echo attempt > "$R/opt/5gpn/.install-attempt"
PGW_MIGRATE_ROOT="$R" migrate_legacy_layout || fail "a bare /opt/5gpn must not block upgrades of a new install"
[[ -f "$R/opt/5gpn/.install-attempt" && -d "$R/opt/simcard-dns/etc" ]] || fail "a bare /opt/5gpn must be left alone"

# --- both layouts present: refuse ----------------------------------------------------------
build_legacy
mkdir -p "$R/opt/simcard-dns/etc"
migrate_legacy_layout 2>/dev/null && fail "must refuse when both layouts exist"
[[ -d "$R/opt/5gpn/etc" ]] || fail "a refused migration must not touch anything"

echo "migrate legacy layout policy OK"
