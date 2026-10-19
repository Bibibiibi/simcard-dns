#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Extracted functions consume globals dynamically via eval.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "$1" >&2; exit 1; }
info() { :; }
warn() { :; }
err() { echo "$*" >&2; }
DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_LOCAL_DNS=("223.5.5.5" "119.29.29.29")
CONF_DIR="${tmp}/conf"
MOSDNS_DIR="$CONF_DIR"
mkdir -p "$CONF_DIR"

eval "$(sed -n '/^normalize_dns_upstreams() {/,/^}/p' "${root}/lib/dns.sh")"
eval "$(sed -n '/^configure_dns_upstreams() {/,/^}/p' "${root}/lib/dns.sh")"

# 1. Empty config -> use defaults (2 China servers, 3 overseas).
unset REMOTE_DNS LOCAL_DNS DNS_UPSTREAMS OVERSEAS_DNS PRIVATE_OVERSEAS_DNS SNIPROXY_DNS
configure_dns_upstreams </dev/null
[[ "$REMOTE_DNS" == "1.1.1.1 8.8.8.8 9.9.9.9" ]] \
    || fail "default international pool was not applied (got: $REMOTE_DNS)"
[[ "$LOCAL_DNS" == "223.5.5.5 119.29.29.29" ]] \
    || fail "default domestic pool was not applied (got: $LOCAL_DNS)"

# 2. Saved config from previous install should be preserved.
printf '9.9.9.9 1.0.0.1\n' > "${CONF_DIR}/.remote_dns"
printf '223.5.5.5 119.29.29.29\n' > "${CONF_DIR}/.local_dns"
unset REMOTE_DNS LOCAL_DNS DNS_UPSTREAMS OVERSEAS_DNS PRIVATE_OVERSEAS_DNS SNIPROXY_DNS
configure_dns_upstreams </dev/null
[[ "$REMOTE_DNS" == "9.9.9.9 1.0.0.1" ]] || fail "saved remote DNS was changed"
[[ "$LOCAL_DNS" == "223.5.5.5 119.29.29.29" ]] || fail "saved local DNS was changed"

# 3. Explicit user override takes priority.
REMOTE_DNS="1.0.0.1 8.8.4.4"
LOCAL_DNS="180.76.76.76 114.114.114.114"
configure_dns_upstreams </dev/null
[[ "$REMOTE_DNS" == "1.0.0.1 8.8.4.4" ]] || fail "explicit international DNS was changed"
[[ "$LOCAL_DNS" == "180.76.76.76 114.114.114.114" ]] || fail "explicit domestic DNS was changed"

# 4. All consumers use plain IP/UDP DNS; encrypted schemes fail before writes.
if (normalize_dns_upstreams "https://1.1.1.1/dns-query") >/dev/null 2>&1; then
    fail "unsupported DoH URL was accepted"
fi
if (normalize_dns_upstreams "tls://1.1.1.1") >/dev/null 2>&1; then
    fail "unsupported DoT URL was accepted"
fi
if (normalize_dns_upstreams "1.1.1.1:5353") >/dev/null 2>&1; then
    fail "unsupported custom DNS port was accepted"
fi

# 5. Malformed URLs must fail closed.
if (normalize_dns_upstreams "https://example.com/not-dns-query") >/dev/null 2>&1; then
    fail "invalid DoH URL was accepted"
fi

echo "DNS upstream configuration and URL validation OK"
