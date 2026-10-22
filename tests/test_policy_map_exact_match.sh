#!/usr/bin/env bash
# The smart router must never be offered or accepted as a policy target, and
# --set-policy must replace exactly one category (AI= used to also drop
# OpenAI= through a substring filter).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "$1" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
export EXITS_DIR="${tmp}/exits" WG_DIR="${tmp}/wg"
POLICY_MAP="${tmp}/policy-map.conf"
RULES_DEFAULT="${tmp}/rules-default.conf"
RULES_FILE="${tmp}/rules.conf"
mkdir -p "${EXITS_DIR}" "${WG_DIR}"
: > "${RULES_DEFAULT}"

# Function bodies straight from the modules (none of these contain heredocs).
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\)" {copy=1} copy {print} copy && /^}/ {exit}' "$2"; }
for fn in exit_conf_path exit_type_file exit_mihomo_conf exit_type exit_exists list_exit_names list_routable_exit_names; do
    eval "$(extract "$fn" "${root}/lib/exits.sh")"
done
for fn in init_policy_map set_policy; do
    eval "$(extract "$fn" "${root}/lib/rules.sh")"
done
routing_lock() { :; }
regen_smart() { :; }
err()  { printf 'ERR %s\n' "$*" >&2; }
ok()   { :; }
info() { :; }

# A smart router plus one real exit whose name sorts after "smart" in C locale.
printf 'router\n' > "${EXITS_DIR}/smart.type"
printf '{"proxies":[]}\n' > "${EXITS_DIR}/smart.yaml"
printf 'shadowsocks\n' > "${EXITS_DIR}/台湾.type"
printf '{"proxies":[{"name":"x","type":"ss","server":"192.0.2.1","port":1}]}\n' > "${EXITS_DIR}/台湾.yaml"

listed="$(list_exit_names | tr '\n' ' ')"
[[ "$listed" == *smart* ]] || fail "list_exit_names still lists the router for --set-exit (got: $listed)"
routable="$(list_routable_exit_names | tr '\n' ' ')"
[[ "$routable" == "台湾 " ]] || fail "list_routable_exit_names must exclude the router (got: $routable)"

printf 'DOMAIN-SUFFIX,openai.com,OpenAI\nDOMAIN-SUFFIX,anthropic.com,AI\nFINAL,AI\n' > "${RULES_FILE}"
init_policy_map
grep -q '=smart$' "${POLICY_MAP}" && fail "init_policy_map must never default a category to the router: $(cat "${POLICY_MAP}")"
grep -qx 'AI=台湾' "${POLICY_MAP}" || fail "default target must be the real exit: $(cat "${POLICY_MAP}")"

printf 'AI=台湾\nOpenAI=台湾\n' > "${POLICY_MAP}"
(set_policy AI direct) || fail "set_policy AI direct must succeed"
grep -qx 'AI=direct' "${POLICY_MAP}" || fail "AI must be remapped: $(cat "${POLICY_MAP}")"
grep -qx 'OpenAI=台湾' "${POLICY_MAP}" || fail "OpenAI must survive a change to AI: $(cat "${POLICY_MAP}")"
[[ "$(grep -c '^AI=' "${POLICY_MAP}")" == 1 ]] || fail "AI must appear exactly once: $(cat "${POLICY_MAP}")"

if (set_policy OpenAI smart) 2>"${tmp}/err"; then
    fail "set_policy must reject the smart router as a target"
fi
grep -q 'smart router itself' "${tmp}/err" || fail "rejection must explain why: $(cat "${tmp}/err")"
grep -qx 'OpenAI=台湾' "${POLICY_MAP}" || fail "a rejected target must leave the map untouched: $(cat "${POLICY_MAP}")"

echo "policy map exact-match / no-router-target OK"
