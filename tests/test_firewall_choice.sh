#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # Globals/mocks are used by eval-loaded functions.
# A fresh install asks up front whether simcard-dns should manage the host
# firewall (a host without one would expose the 80/443 proxy to everyone), and
# `simcard-dns --set-firewall managed` switches an existing install later; the
# regional allowlist points there when the firewall is not managed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }
info() { :; }; ok() { echo "OK $*"; }; err() { echo "ERR $*" >&2; }
warn() { echo "WARN $*" >> "${tmp}/warn"; }
eval "$(awk '/^collect_firewall_choice\(\)/,/^}/' "${root}/lib/host-setup.sh")"
eval "$(awk '/^set_firewall_mode\(\)/,/^}/' "${root}/lib/host-setup.sh")"

# --- install flow wiring -----------------------------------------------------------
main_body="$(awk '/^main_install\(\)/,/^}/' "${root}/install.sh")"
choice_line="$(grep -n 'collect_firewall_choice' <<< "$main_body" | head -1 | cut -d: -f1)"
deps_line="$(grep -n '安装系统依赖' <<< "$main_body" | head -1 | cut -d: -f1)"
[[ -n "$choice_line" && "$choice_line" -lt "$deps_line" ]] || fail "the firewall question must be asked before the long install"
grep -qF -- '    --set-firewall)' "${root}/install.sh" || fail "--set-firewall must be dispatched"
grep -qF -- '--set-firewall managed' "${root}/install.sh" || fail "--set-firewall must be documented in --help"
grep -qF 'switch first with: simcard-dns --set-firewall managed' "${root}/lib/host-setup.sh" \
    || fail "the regional allowlist must say how to switch to the managed firewall"

# --- collect_firewall_choice ------------------------------------------------------
ufw() { return 1; }; firewall-cmd() { return 1; }
FIREWALL_MODE=auto
collect_firewall_choice </dev/null
[[ "$FIREWALL_MODE" == auto ]] || fail "an explicit FIREWALL_MODE must be kept without asking"
unset FIREWALL_MODE
collect_firewall_choice </dev/null
[[ -z "${FIREWALL_MODE:-}" ]] || fail "a non-interactive install must not take over the firewall on its own"
grep -q 'TCP 80/443 is open to everyone' "${tmp}/warn" || fail "a non-interactive install must warn about an unmanaged firewall"

# --- set_firewall_mode --------------------------------------------------------------
routing_lock() { :; }
detect_ssh_ports() { echo 22; }
setup_firewall() { echo "setup_firewall mode=${FIREWALL_MODE:-}" >> "${tmp}/calls"; }
(set_firewall_mode preserve) 2>/dev/null && fail "only 'managed' may be requested"
(set_firewall_mode) 2>/dev/null && fail "a mode argument is required"
out="$(set_firewall_mode managed)" || fail "--set-firewall managed must succeed"
grep -qx 'setup_firewall mode=managed' "${tmp}/calls" || fail "--set-firewall managed must apply the managed firewall"
[[ "$out" == *"SSH (22)"* ]] || fail "the result must say which SSH ports stay open"
setup_firewall() { return 1; }
(set_firewall_mode managed) 2>/dev/null && fail "a failed firewall apply must be reported"

echo "firewall choice policy OK"
