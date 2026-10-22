#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are read by the eval-loaded function.
# Only domains named by smart-routing rules are sent to the gateway by DNS.
# build_rule_domains turns the rules (incl. category mappings, rule-sets and
# GEOSITE) into mosdns domain lists; direct targets stay off the list, block
# targets get their own list, IP rules are ignored, and --render-only never
# touches the network (cache only).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }
eval "$(awk '/^build_rule_domains\(\)/,/^}$/' "${root}/lib/update-rules.sh")"

BASE_DIR="${tmp}/dns"; mkdir -p "$BASE_DIR"
RULE_DOMAIN_CACHE="${tmp}/cache"; mkdir -p "$RULE_DOMAIN_CACHE"
DEFAULT_RULES_FILE="${tmp}/rules-default.conf"
USER_RULES_FILE="${tmp}/rules.conf"
POLICY_MAP_FILE="${tmp}/policy-map.conf"
cache() { # url -> pre-seeded cache file, as the updater would have stored it
    local key
    key="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:24])' "$1")"
    printf '%s' "$2" > "${RULE_DOMAIN_CACHE}/${key}.txt"
}

printf 'payload:\n  - "+.speed.example"\n  - exact-speed.example\n' > "${tmp}/speed.yaml"
printf 'RULE-SET,%s,Speedtest\n' "${tmp}/speed.yaml" > "$DEFAULT_RULES_FILE"
printf 'payload:\n  - "+.cdn.example"\n  - dl.cdn.example\n  - "+.video.example"\n  - DOMAIN-SUFFIX,tracker.example\n  - DOMAIN,direct.exact.example\n' > "${tmp}/video.yaml"
printf 'payload:\n  - "+.shop.example"\n' > "${tmp}/shop.yaml"
cat > "$USER_RULES_FILE" <<RULES
DOMAIN-SUFFIX,openai.com,tw
DOMAIN,exact.example,tw
DOMAIN-KEYWORD,claude,local
DOMAIN-SUFFIX,youtube.com,direct
DOMAIN-SUFFIX,ads.example,block
DOMAIN-SUFFIX,cat-direct.example,Domestic
DOMAIN-SUFFIX,cat-proxy.example,AI
IP-CIDR,1.2.3.0/24,tw
GEOIP,cn,direct
GEOSITE,Gemini,tw
RULE-SET,https://example.invalid/rules/grok.mrs,AI
DOMAIN-SUFFIX,grok.com,direct
RULE-SET,https://example.invalid/uncached.yaml,tw
DOMAIN-SUFFIX,cdn.example,direct
DOMAIN-KEYWORD,tracker,direct
DOMAIN,direct.exact.example,direct
RULE-SET,${tmp}/shop.yaml,Domestic
RULE-SET,${tmp}/video.yaml,local
DOMAIN-SUFFIX,api.shop.example,tw
DOMAIN-SUFFIX,ads.cdn.example,block
FINAL,tw
RULES
printf 'Speedtest=local\nDomestic=direct\nAI=tw\n' > "$POLICY_MAP_FILE"
cache "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/gemini.list" $'gemini.google.com\n+.bard.google.com\n'
cache "https://example.invalid/rules/grok.list" $'payload:\n  - DOMAIN-SUFFIX,grok.com\n  - DOMAIN-KEYWORD,xai\n  - IP-CIDR,9.9.9.0/24\n'

mode=--render-only
build_rule_domains 2> "${tmp}/err" >/dev/null || fail "rule-domain build must not fail on an uncached rule-set"

# A direct rule shadows the same names in every later rule (mihomo takes the
# first match): cdn.example, tracker*, direct.exact.example and shop.example
# stay off the lists even though later rule-sets name them, while grok.com
# stays on because its direct rule comes after the rule-set.
expected_proxy='domain:bard.google.com
domain:cat-proxy.example
domain:grok.com
domain:openai.com
domain:speed.example
domain:video.example
full:exact-speed.example
full:exact.example
full:gemini.google.com
keyword:claude
keyword:xai'
[[ "$(cat "${BASE_DIR}/rule-domains.txt")" == "$expected_proxy" ]] \
    || { diff <(echo "$expected_proxy") "${BASE_DIR}/rule-domains.txt" >&2; fail "proxied rule domains are wrong"; }
[[ "$(cat "${BASE_DIR}/rule-block.txt")" == "domain:ads.example" ]] || fail "block targets must be listed for DNS refusal (and direct must shadow later block rules)"
grep -q 'not cached' "${tmp}/err" || fail "an uncached remote rule-set must be reported, not fetched, in --render-only"

# The two lists must exist (empty) even without any rules.
rm -f "$DEFAULT_RULES_FILE" "$USER_RULES_FILE" "${BASE_DIR}"/rule-*.txt
build_rule_domains >/dev/null 2>&1
[[ -f "${BASE_DIR}/rule-domains.txt" && ! -s "${BASE_DIR}/rule-domains.txt" ]] || fail "empty rule list must still be written"
[[ -f "${BASE_DIR}/rule-block.txt" ]] || fail "empty block list must still be written"

echo "rule-domain DNS policy OK"
