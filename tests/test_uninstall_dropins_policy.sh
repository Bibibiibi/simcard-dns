#!/usr/bin/env bash
# --uninstall runs under `set -e`. Its unit-removal glob also matches drop-in
# directories (mosdns.service.d, quic-proxy.service.d); removing them with a
# plain `rm -f` failed and aborted the uninstall halfway, leaving /opt/simcard-dns
# (and its installed-commit marker) behind, so a reinstall reported "already
# current". The glob must remove files and drop-in dirs and keep going.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }

line="$(grep -E '^[[:space:]]*rm .*/etc/systemd/system/\{mosdns,' "${root}/lib/uninstall.sh")" \
    || fail "uninstall must remove the project units with one glob"
[[ "$line" == *'rm -rf '* ]] || fail "the unit glob must use rm -rf (it matches *.service.d dirs)"

sd="${tmp}/systemd"
mkdir -p "${sd}/mosdns.service.d" "${sd}/quic-proxy.service.d"
echo x > "${sd}/mosdns.service"; echo x > "${sd}/mosdns.service.d/override.conf"
echo x > "${sd}/quic-proxy.service"; echo x > "${sd}/quic-proxy.service.d/limits.conf"
echo x > "${sd}/simcard-dns-tgbot.service"; echo x > "${sd}/simcard-dns-ios-profile.socket"
echo x > "${sd}/unrelated.service"
(
    set -e
    eval "${line//\/etc\/systemd\/system/${sd}}"
    echo reached > "${tmp}/after"
) || fail "the unit glob must not fail when drop-in dirs exist"
[[ -f "${tmp}/after" ]] || fail "uninstall must continue past the unit glob"
for gone in mosdns.service mosdns.service.d quic-proxy.service quic-proxy.service.d \
    simcard-dns-tgbot.service simcard-dns-ios-profile.socket; do
    [[ ! -e "${sd}/${gone}" ]] || fail "uninstall must remove ${gone}"
done
[[ -f "${sd}/unrelated.service" ]] || fail "uninstall must not touch other units"

# Running it again on an already-clean host must also succeed.
( set -e; eval "${line//\/etc\/systemd\/system/${sd}}" ) || fail "a second uninstall must not fail"

echo "uninstall drop-in policy OK"
