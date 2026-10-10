#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
EXITS_DIR="$tmp/exits"; WG_DIR="$tmp/wg"; CONF_DIR="$tmp/conf"; RULES_FILE="$CONF_DIR/rules.conf"; POLICY_MAP="$CONF_DIR/policy-map.conf"
mkdir -p "$EXITS_DIR" "$WG_DIR" "$CONF_DIR"
printf 'socks\n' > "$EXITS_DIR/us.type"
printf 'DOMAIN-SUFFIX,example.com,us\n' > "$RULES_FILE"
printf 'AI=us\n' > "$POLICY_MAP"
err() { printf '%s\n' "$*" >&2; }
warn() { :; }
ok() { :; }
exit_exists() { [[ -f "$EXITS_DIR/$1.type" || -f "$WG_DIR/pgw-$1.conf" ]]; }
exit_type_file() { printf '%s/%s.type\n' "$EXITS_DIR" "$1"; }
exit_conf_path() { printf '%s/pgw-%s.conf\n' "$WG_DIR" "$1"; }
exit_mihomo_conf() { printf '%s/%s.yaml\n' "$EXITS_DIR" "$1"; }
exit_down() { :; }
set_exit() { :; }
# Load only del_exit from the production module.
eval "$(awk '/^del_exit\(\) \{/{copy=1} copy{if ($0 ~ /^rename_exit\(\) \{/) exit; print}' "$root/lib/exits.sh")"
if (del_exit us) >/dev/null 2>&1; then
    echo "deleting an exit referenced by rules/policy must fail" >&2
    exit 1
fi
[[ -f "$EXITS_DIR/us.type" ]] || { echo "referenced exit was deleted" >&2; exit 1; }
printf '\n' > "$RULES_FILE"
if (del_exit us) >/dev/null 2>&1; then
    echo "deleting an exit referenced by policy map must fail" >&2
    exit 1
fi
[[ -f "$EXITS_DIR/us.type" ]] || { echo "policy-referenced exit was deleted" >&2; exit 1; }
printf 'delete exit reference guard OK\n'
