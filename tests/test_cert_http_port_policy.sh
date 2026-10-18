#!/usr/bin/env bash
# shellcheck disable=SC2016 # Mock bodies are literal scripts, expanded when the mock runs.
# open_cert_http_port must not abort certificate issuance on a host that has
# no firewall at all (nftables installed but no ruleset, no iptables): TCP/80
# is already reachable there. It must still fail when an unknown nftables
# input chain could be filtering and no supported way to open the port exists.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }
info() { :; }; warn() { :; }
eval "$(awk '/^open_cert_http_port\(\)/,/^}/' "${root}/lib/host-setup.sh")"

mock() { printf '#!/bin/bash\n%s\n' "$2" > "${tmp}/bin/$1"; chmod +x "${tmp}/bin/$1"; }
reset_bin() { rm -rf "${tmp:?}/bin"; mkdir -p "${tmp}/bin"; }
run() { PATH="${tmp}/bin:/usr/bin:/bin" open_cert_http_port; }

# 1. Fresh host: nft present, empty ruleset, no iptables -> succeed, no-op.
reset_bin
mock nft 'case "$1 $2" in "list table") exit 1;; "list ruleset") exit 0;; *) exit 9;; esac'
# PATH excludes /usr/sbin, so a real iptables on the test host stays hidden;
# skip the no-iptables cases where a distro ships it in /usr/bin anyway.
PATH="${tmp}/bin:/usr/bin:/bin" command -v iptables >/dev/null 2>&1 && iptables_real=1 || iptables_real=0
if [[ "$iptables_real" == 0 ]]; then
    run || fail "fresh host without any firewall must not abort certbot"
fi

# 2. nft has the project's inet filter table -> insert the temporary rule.
reset_bin
mock nft 'echo "$*" >> '"${tmp}"'/nft.log; exit 0'
run || fail "inet filter present: opening TCP/80 must succeed"
grep -q 'insert rule inet filter input tcp dport 80 accept' "${tmp}/nft.log" || fail "must insert the temporary nft rule"

# 3. Unknown nft input chain, no inet filter, no iptables -> refuse.
reset_bin
mock nft 'case "$1 $2" in "list table") exit 1;; "list ruleset") echo "chain input { type filter hook input priority 0; policy drop; }";; esac'
if [[ "$iptables_real" == 0 ]]; then
    run && fail "an unmanaged nft input chain must not be assumed open"
fi

echo "cert HTTP-01 port policy OK"
