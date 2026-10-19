#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # Globals/mocks are used by eval-loaded functions.
# ASN allowlist: adding an ASN unions its announced IPv4 prefixes into the
# client list; deleting subtracts them again while keeping other ASNs and
# hand-set CIDRs. No carrier is built in; the operator adds ASNs in the bot.
set -euo pipefail
exec </dev/null  # install-time questions must never wait for a terminal here

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }
info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
for fn in normalize_client_cidrs current_client_cidrs; do
    eval "$(awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/common.sh")"
done
for fn in client_asn_tool normalize_asn client_asn_bootstrap client_asn_prefixes list_client_asns lookup_client_asn add_client_asn del_client_asn; do
    eval "$(awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/dns.sh")"
done
BASE_CIDRS="74.119.64.0/21 103.143.92.0/23"
CLIENT_CIDRS_FILE="${tmp}/client_cidrs"
CLIENT_ASN_DIR="${tmp}/asns"
routing_lock() { :; }
check_root() { :; }
# The real set_client_cidrs re-renders DNS/firewall; here it only records.
set_client_cidrs() { normalize_client_cidrs "$1" > "$CLIENT_CIDRS_FILE"; }
export PGW_RIPESTAT_DIR="${tmp}/ripe"; mkdir -p "$PGW_RIPESTAT_DIR"
mock_asn() { # asn holder prefixes...
    local asn="$1" holder="$2"; shift 2
    python3 - "$PGW_RIPESTAT_DIR" "$asn" "$holder" "$@" <<'PY'
import json, sys
d, asn, holder, *prefixes = sys.argv[1:]
json.dump({"data": {"prefixes": [{"prefix": p} for p in prefixes] + [{"prefix": "2001:db8::/32"}]}},
          open("%s/announced-prefixes-%s.json" % (d, asn), "w"))
json.dump({"data": {"holder": holder}}, open("%s/as-overview-%s.json" % (d, asn), "w"))
PY
}
mock_asn AS63527 "CTGL-AS - China Telecom Global Limited" 63.140.1.0/24 63.140.2.0/24 203.12.88.0/24 203.12.89.0/24
mock_asn AS64500 "OVERLAP-NET" 203.12.88.0/24 198.51.100.0/24
mock_asn AS64501 "IPV6-ONLY"

# normalize_asn
[[ "$(normalize_asn as063527)" == AS63527 && "$(normalize_asn 63527)" == AS63527 ]] || fail "ASN forms must normalize"
normalize_asn AS0 >/dev/null && fail "AS0 is invalid"
normalize_asn 'AS1;rm' >/dev/null && fail "garbage must be rejected"

# No carrier is built in: hand-set CIDRs are "other", nothing is registered.
echo "$BASE_CIDRS 192.0.2.0/24" > "$CLIENT_CIDRS_FILE"
out="$(list_client_asns)"
grep -q '^AS' <<< "$out" && fail "no ASN may be registered by default: $out"
grep -q $'^OTHER\t' <<< "$out" || fail "hand-set CIDRs must be listed as OTHER: $out"

# Lookup is read-only and IPv4 only.
[[ "$(lookup_client_asn 63527)" == $'AS63527\tCTGL-AS - China Telecom Global Limited\t3\t1024' ]] \
    || fail "lookup must report holder, collapsed IPv4 prefix count and addresses"
( lookup_client_asn AS64501 ) 2>/dev/null && fail "an ASN without IPv4 prefixes must be refused"

# Add unions; duplicates refused.
add_client_asn AS63527
python3 - "$CLIENT_CIDRS_FILE" <<'PY' || fail "AS63527 prefixes must be allowlisted"
import ipaddress, sys
have = [ipaddress.ip_network(x) for x in open(sys.argv[1]).read().split()]
for want in ("63.140.1.0/24", "63.140.2.0/24", "203.12.88.0/23", "103.143.92.0/23", "192.0.2.0/24"):
    assert any(ipaddress.ip_network(want).subnet_of(h) for h in have), want
PY
[[ -f "${CLIENT_ASN_DIR}/AS63527.txt" ]] || fail "added ASN must be recorded"
( add_client_asn AS63527 ) 2>/dev/null && fail "adding the same ASN twice must be refused"
add_client_asn AS64500

# Delete subtracts only that ASN; an overlapping prefix owned by another ASN stays.
del_client_asn AS63527
python3 - "$CLIENT_CIDRS_FILE" <<'PY' || fail "delete must keep other ASNs, overlaps and manual CIDRs"
import ipaddress, sys
have = [ipaddress.ip_network(x) for x in open(sys.argv[1]).read().split()]
cov = lambda w: any(ipaddress.ip_network(w).subnet_of(h) for h in have)
for keep in ("203.12.88.0/24", "198.51.100.0/24", "103.143.92.0/23", "192.0.2.0/24"):
    assert cov(keep), "lost " + keep
for gone in ("63.140.1.0/24", "63.140.2.0/24", "203.12.89.0/24"):
    assert not cov(gone), "kept " + gone
PY
[[ ! -f "${CLIENT_ASN_DIR}/AS63527.txt" ]] || fail "deleted ASN record must be removed"
( del_client_asn AS63527 ) 2>/dev/null && fail "deleting an absent ASN must fail"

# Never allow an empty allowlist.
rm -rf "$CLIENT_ASN_DIR"; echo "203.12.88.0/24 198.51.100.0/24" > "$CLIENT_CIDRS_FILE"
add_client_asn AS64500 >/dev/null
( del_client_asn AS64500 ) 2>/dev/null && fail "removing the last allowlisted network must be refused"
[[ "$(cat "$CLIENT_CIDRS_FILE")" == "198.51.100.0/24 203.12.88.0/24" ]] || fail "refused delete must not change the list"

# --- no built-in carrier: an empty list is "not set yet" --------------------------
grep -q 'collect_client_networks' "${root}/install.sh" && fail "the installer must not ask; client networks are added in the bot"
rm -f "$CLIENT_CIDRS_FILE"
[[ -z "$(current_client_cidrs)" ]] || fail "with nothing configured there must be no client networks"
rm -rf "$CLIENT_ASN_DIR"
add_client_asn AS63527 >/dev/null || fail "the first ASN must be addable to an empty list (the bot flow)"
[[ "$(cat "$CLIENT_CIDRS_FILE")" == "63.140.1.0/24 63.140.2.0/24 203.12.88.0/23" ]] || fail "first ASN must become the whole list"

# Managed firewall: only the two client source sets are rewritten in place.
eval "$(awk '/^refresh_managed_client_rules\(\)/,/^}/' "${root}/lib/host-setup.sh")"
mkdir -p "${tmp}/bin"; printf '#!/bin/sh\nexit 0\n' > "${tmp}/bin/nft"; chmod +x "${tmp}/bin/nft"
cat > "${tmp}/nftables.conf" <<'NFT'
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        tcp dport { 22, 8111 } accept
        ip saddr { 10.9.9.0/24 } tcp dport { 22 } accept
        ip saddr { 74.119.64.0/21, 103.143.92.0/23 } tcp dport { 80, 443 } accept
        ip saddr { 74.119.64.0/21, 103.143.92.0/23 } udp dport 443 accept
    }
}
include "/etc/simcard-dns/pgw-exit.nft"
NFT
PATH="${tmp}/bin:$PATH" PGW_NFT_CONF="${tmp}/nftables.conf" refresh_managed_client_rules "63.140.1.0/24 103.143.92.0/23" \
    || fail "managed client rules must be refreshable"
[[ "$(grep -c 'ip saddr { 63.140.1.0/24, 103.143.92.0/23 }' "${tmp}/nftables.conf")" -eq 2 ]] || fail "both client lines must be rewritten"
grep -q 'ip saddr { 10.9.9.0/24 } tcp dport { 22 } accept' "${tmp}/nftables.conf" || fail "unrelated rules must stay untouched"
printf 'table inet filter {}\n' > "${tmp}/plain.conf"
rc=0; PATH="${tmp}/bin:$PATH" PGW_NFT_CONF="${tmp}/plain.conf" refresh_managed_client_rules "1.2.3.0/24" || rc=$?
[[ "$rc" -eq 2 ]] || fail "a non-managed ruleset must be reported as untouched (rc 2), got $rc"

echo "client ASN allowlist policy OK"
