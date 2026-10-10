#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export PGW_MOSDNS_DIR="$tmp/dns" PGW_ROUTING_LOCK_FILE="$tmp/lock" PGW_RULES_UPDATER="$tmp/updater"
RULES_FILE="$tmp/rules"
mkdir -p "$PGW_MOSDNS_DIR"
printf 'DOMAIN,original.example,direct\n' > "$RULES_FILE"
printf 'keep.example\n' > "$PGW_MOSDNS_DIR/gfwlist-extra-local.txt"
printf '%s\n' '#!/bin/sh' "exit \"\${FAIL_DNS:-0}\"" > "$PGW_RULES_UPDATER"; chmod +x "$PGW_RULES_UPDATER"
source "$root/lib/rules.sh"
regen_smart() { [[ "${FAIL_SMART:-0}" != 1 ]]; }
exit_exists() { [[ "$1" == us ]]; }
err() { echo "$*" >&2; }
ok() { :; }
export FAIL_SMART=1
# Invoke unconditionally in a child shell so errexit is not disabled by if.
export -f proxy_domain regen_smart exit_exists err ok
export RULES_FILE
if bash -c 'proxy_domain example.com us'; then echo 'expected smart failure' >&2; exit 1; fi
[[ "$(cat "$RULES_FILE")" == DOMAIN,original.example,direct ]]
[[ ! -f "$PGW_MOSDNS_DIR/domain-overrides.conf" ]]
unset FAIL_SMART
export FAIL_DNS=1
if bash -c 'proxy_domain example.com us'; then echo 'expected DNS failure' >&2; exit 1; fi
[[ "$(cat "$RULES_FILE")" == DOMAIN,original.example,direct ]]
[[ ! -f "$PGW_MOSDNS_DIR/domain-overrides.conf" ]]
unset FAIL_DNS
bash -c 'proxy_domain example.com us'
grep -qxF 'example.com=proxy' "$PGW_MOSDNS_DIR/domain-overrides.conf"
bash -c 'proxy_domain example.com direct'
grep -qxF 'example.com=direct' "$PGW_MOSDNS_DIR/domain-overrides.conf"
if grep -qxF example.com "$PGW_MOSDNS_DIR/gfwlist-extra-local.txt"; then exit 1; fi
grep -qxF keep.example "$PGW_MOSDNS_DIR/gfwlist-extra-local.txt"
echo 'proxy-domain rollback and overrides OK'
