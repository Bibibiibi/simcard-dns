#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Literal assertions; globals are read by eval-loaded functions.
# Client networks are public source ranges (for example a mobile carrier's
# egress pool); there is no built-in default, the operator sets them.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }

info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
eval "$(awk '/^normalize_client_cidrs\(\)/,/^}/' "${root}/lib/common.sh")"
eval "$(awk '/^current_client_cidrs\(\)/,/^}/' "${root}/lib/common.sh")"
eval "$(awk '/^self_ipv4_addrs\(\)/,/^}/' "${root}/lib/common.sh")"
# The nft heredoc has its own column-0 "}", so cut at the next function.
eval "$(sed -n '/^write_pgw_exit_nft()/,/^apply_pgw_exit_rules()/p' "${root}/lib/host-setup.sh" | sed '$d')"
CLIENT_CIDRS_FILE="${tmp}/.client_cidrs"
unset CLIENT_CIDRS

# --- normalisation ------------------------------------------------------------
[[ "$(normalize_client_cidrs '103.143.92.0/23, 203.0.113.7/20 203.0.113.0/24')" == "103.143.92.0/23 203.0.112.0/20" ]] \
    || fail "CIDRs must be canonicalised and collapsed"
[[ "$(normalize_client_cidrs '198.51.100.9')" == "198.51.100.9/32" ]] || fail "bare IPs must become /32"
normalize_client_cidrs 'not-a-cidr' 2>/dev/null && fail "invalid CIDRs must be rejected"
normalize_client_cidrs '0.0.0.0/0' 2>/dev/null && fail "0.0.0.0/0 must be rejected (open proxy)"
normalize_client_cidrs '0.0.0.0/1 128.0.0.0/1' 2>/dev/null && fail "halves that collapse to 0.0.0.0/0 must be rejected too"
normalize_client_cidrs '' 2>/dev/null && fail "empty list must be rejected"

# --- precedence: env > file; no built-in default ---------------------------------
grep -q 'DEFAULT_CLIENT_CIDRS' "${root}/install.sh" "${root}/lib/"*.sh && fail "no carrier may be built in as the default client network"
[[ -z "$(current_client_cidrs)" ]] || fail "without a configured list there must be no client networks (added later in the bot)"
echo "103.143.92.0/23 203.0.113.0/24" > "${CLIENT_CIDRS_FILE}"
[[ "$(current_client_cidrs)" == "103.143.92.0/23 203.0.113.0/24" ]] || fail "persisted list must be used"
[[ "$(CLIENT_CIDRS=198.51.100.0/24 current_client_cidrs)" == "198.51.100.0/24" ]] || fail "CLIENT_CIDRS env must win"

# --- proxy replies to clients are never marked into the exit tunnel ----------
PGW_EXIT_NFT="${tmp}/pgw-exit.nft"
PUBLIC_IP=192.0.2.10 write_pgw_exit_nft
# A Host/SNI naming this server must not be proxied back to itself (loop/DoS).
grep -F 'meta skuid "pxout" ip daddr {' "${PGW_EXIT_NFT}" | grep -F 'tcp dport { 80, 443 } reject with tcp reset' \
    | grep -qF '192.0.2.10' || fail "proxy connections to this host's own 80/443 must be rejected"
grep -F 'udp dport 443 reject' "${PGW_EXIT_NFT}" | grep -qF '127.0.0.0/8' || fail "QUIC self-loop must be rejected"
# Replies to clients must never be marked into the tunnel, for every source
# network, not only the configured ones: match by conntrack direction.
grep -qF 'ct direction reply return' "${PGW_EXIT_NFT}" \
    || fail "reply-direction packets must be excluded from egress marking"
reply_line=$(grep -n 'ct direction reply return' "${PGW_EXIT_NFT}" | cut -d: -f1)
mark_line=$(grep -n 'meta mark set 0x1' "${PGW_EXIT_NFT}" | cut -d: -f1)
[[ "$reply_line" -lt "$mark_line" ]] || fail "reply exclusion must precede the mark rule"
grep -qF 'meta skuid "pxout" meta mark set 0x1' "${PGW_EXIT_NFT}" || fail "egress marking must remain"

# The managed nft template gets a set that matches nobody when the list is empty.
grep -qF 'local nft_clients="${client_nets:-$CLIENT_NONE}"' "${root}/lib/host-setup.sh" \
    || fail "an empty client list must not produce an invalid nft set"

# --- mosdns rendering uses the stored list -------------------------------------
mosdns_dir="${tmp}/mosdns"
mkdir -p "${mosdns_dir}"
cp "${root}/lib/mosdns.yaml.template" "${mosdns_dir}/config.yaml.template"
echo 192.0.2.1 > "${mosdns_dir}/.public_ip"
render() {
    (
        eval "$(sed -n '/^DEFAULT_REMOTE_DNS=/p;/^DEFAULT_LOCAL_DNS=/p' "${root}/lib/update-rules.sh")"
        eval "$(awk '/^yaml_upstreams\(\)/,/^}/' "${root}/lib/update-rules.sh")"
        eval "$(sed -n '/^render_config()/,/^valid_domain_cache()/p' "${root}/lib/update-rules.sh" | sed '$d')"
        BASE_DIR="${mosdns_dir}"
        MOSDNS_TEMPLATE="${mosdns_dir}/config.yaml.template"
        MOSDNS_CONF="${mosdns_dir}/config.yaml"
        PATH="/usr/bin:/bin" render_config
    )
}
render || fail "a missing client list must still render (nobody is a client yet)"
grep -qF 'client_ip 0.0.0.0/32' "${mosdns_dir}/config.yaml" || fail "no client networks must match nobody (0.0.0.0/32)"
echo "203.0.113.0/24,103.143.92.0/23" > "${mosdns_dir}/.client_cidrs"
render
grep -qF 'client_ip 103.143.92.0/23 203.0.113.0/24' "${mosdns_dir}/config.yaml" \
    || fail "stored client networks must reach the mosdns client_ip matcher"
grep -qF '__CLIENT_CIDRS__' "${mosdns_dir}/config.yaml" && fail "placeholder must be substituted"
echo "0.0.0.0/0" > "${mosdns_dir}/.client_cidrs"
render 2>/dev/null && fail "renderer must refuse an open-proxy client list"
echo "0.0.0.0/1 128.0.0.0/1" > "${mosdns_dir}/.client_cidrs"
render 2>/dev/null && fail "renderer must refuse halves that collapse to 0.0.0.0/0"

# --- CLI wiring ----------------------------------------------------------------
grep -qF -- '--set-client-cidrs)' "${root}/install.sh" || fail "--set-client-cidrs must be dispatched"
grep -qF 'apply_pgw_exit_rules' "${root}/install.sh" || fail "--upgrade must regenerate the egress table (self-loop guard)"
grep -qF '/etc/simcard-dns/pgw-exit.nft' "${root}/install.sh" || fail "--upgrade must snapshot pgw-exit.nft for rollback"
grep -qF '.client_cidrs config.yaml.template' "${root}/lib/update-rules.sh" \
    || fail "staged renders must see the stored client list"

echo "client CIDR policy OK"
