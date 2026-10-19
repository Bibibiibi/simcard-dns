#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${PGW_MOSDNS_DIR:-/etc/mosdns}"
GFWLIST_URL="https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt"
CHINALIST_URL="https://github.com/felixonmars/dnsmasq-china-list/raw/master/accelerated-domains.china.conf"
GFWLIST_RAW="${BASE_DIR}/gfwlist.raw"
CHINALIST_RAW="${BASE_DIR}/chinalist.raw"
GFWLIST_FILE="${BASE_DIR}/gfwlist.txt"
CHINALIST_FILE="${BASE_DIR}/chinalist.txt"
GFWLIST_EXTRA_FILE="${BASE_DIR}/gfwlist-extra-local.txt"
DEFAULT_RULES_FILE="${PGW_DEFAULT_RULES_FILE:-/etc/simcard-dns/rules-default.conf}"
USER_RULES_FILE="${PGW_RULES_FILE:-/etc/simcard-dns/rules.conf}"
POLICY_MAP_FILE="${PGW_POLICY_MAP:-/etc/simcard-dns/policy-map.conf}"
MOSDNS_TEMPLATE="${BASE_DIR}/config.yaml.template"
MOSDNS_CONF="${BASE_DIR}/config.yaml"
DEFAULT_REMOTE_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_LOCAL_DNS=("101.226.4.6" "218.30.118.6" "180.76.76.76" "119.29.29.29")

normalize_domain() {
    local domain="${1:-}"
    domain="${domain%%#*}"
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    domain="${domain%.}"
    domain="${domain#www.}"
    printf '%s' "$domain"
}

valid_domain() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}

# mosdns domain_set accepts a bare label as a suffix (for example, `cn` or
# `xn--fiqs8s`). Keep the stricter dotted-domain validator for user-facing
# overrides and local extras; only the upstream ChinaList cache gets this form.
valid_chinalist_domain() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)*$ ]]
}

append_local_gfwlist_extras() {
    [[ -f "$GFWLIST_EXTRA_FILE" ]] || return 0
    local domain
    while IFS= read -r domain || [[ -n "$domain" ]]; do
        domain=$(normalize_domain "$domain")
        [[ -z "$domain" ]] && continue
        if valid_domain "$domain"; then
            printf '%s\n' "$domain"
        else
            echo "[!] Skipping invalid local GFWList extra domain: $domain" >&2
        fi
    done < "$GFWLIST_EXTRA_FILE" >> "$GFWLIST_FILE"
}

# Routing rules decide what reaches the gateway at all: only domains named by
# a smart-routing rule (built-in defaults + user rules, including remote
# rule-sets and GEOSITE) are answered with the server IP for client networks;
# everything else resolves normally so phones connect directly. Rules whose
# target resolves to direct are left alone, block targets are refused in DNS.
# Remote lists are cached; --render-only never touches the network.
build_rule_domains() {
    python3 - "$DEFAULT_RULES_FILE" "$USER_RULES_FILE" "$POLICY_MAP_FILE" \
        "$RULE_DOMAIN_CACHE" "${mode:-}" "$BASE_DIR/rule-domains.txt" "$BASE_DIR/rule-block.txt" <<'PY'
import hashlib, os, re, sys, urllib.request

default_rules, user_rules, policy_file, cache_dir, mode, out_proxy, out_block = sys.argv[1:8]
GEOSITE = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/%s.list"
LABEL = re.compile(r"^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?$")
policy = {}
try:
    for raw in open(policy_file, encoding="utf-8"):
        key, sep, value = raw.strip().partition("=")
        if sep and not key.startswith("#"):
            policy[key.strip()] = value.strip()
except OSError:
    pass

def action(target):
    resolved = policy.get(target.strip(), target.strip()).lower()
    if resolved in ("direct", "dir", "direct-out"):
        return None
    return "block" if resolved in ("block", "reject", "reject-drop") else "proxy"

def valid(name):
    labels = name.split(".")
    return len(labels) >= 1 and all(LABEL.match(x) for x in labels) and len(name) <= 253

def entry(kind, value):
    value = value.strip().strip("'\"").lower().rstrip(".")
    if kind == "keyword":
        return "keyword:" + value if value and "\n" not in value else None
    for prefix in ("+.", "*.", "."):
        if value.startswith(prefix):
            value, kind = value[len(prefix):], "domain"
    return "%s:%s" % (kind, value) if value and valid(value) else None

def parse_list(text):
    """Domain-set (plain = exact, +./. = suffix) and classical lists, text or YAML."""
    found = set()
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.lower().startswith("payload") or line[:1] in "!;":
            continue
        line = line.lstrip("- ").strip().strip("'\"")
        parts = [p.strip().strip("'\"") for p in line.split(",")]
        kind = parts[0].upper()
        if len(parts) > 1:
            mapped = {"DOMAIN": "full", "HOST": "full", "DOMAIN-SUFFIX": "domain",
                      "HOST-SUFFIX": "domain", "DOMAIN-KEYWORD": "keyword"}.get(kind)
            item = entry(mapped, parts[1]) if mapped else None
        else:
            item = entry("full", line)
        if item:
            found.add(item)
    return found

def fetch(url):
    """Remote list text: refreshed unless --render-only, falling back to cache."""
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, hashlib.sha256(url.encode()).hexdigest()[:24] + ".txt")
    if mode != "--render-only":
        try:
            with urllib.request.urlopen(url, timeout=15) as resp:
                text = resp.read().decode("utf-8", "ignore")
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.replace(tmp, path)
            return text
        except Exception as exc:
            print("[!] rule list fetch failed (%s): %s; using cache" % (url, exc), file=sys.stderr)
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        print("[!] rule list not cached and not fetched, skipped for DNS: %s" % url, file=sys.stderr)
        return ""

def ruleset_text(source):
    source = source.split("#", 1)[0]
    if source.startswith(("http://", "https://")):
        if source.lower().split("?", 1)[0].endswith(".mrs"):
            # Binary mihomo format: use the plain list published next to it
            # (MetaCubeX meta-rules-dat ships .list beside every .mrs).
            return fetch(re.sub(r"\.mrs(\?|$)", r".list\1", source, count=1))
        return fetch(source)
    if source.lower().endswith(".mrs"):
        print("[!] local .mrs rule-set cannot be read for DNS: %s" % source, file=sys.stderr)
        return ""
    try:
        return open(source, encoding="utf-8").read()
    except OSError:
        return ""

result = {"proxy": set(), "block": set()}
for path in (default_rules, user_rules):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        continue
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        parts = [p.strip() for p in line.split(",")]
        kind = parts[0].upper().replace("_", "-")
        if len(parts) < 3 or kind in ("FINAL", "IP-CIDR", "IP-CIDR6", "GEOIP"):
            continue
        act = action(parts[-1])
        if act is None:
            continue
        if kind in ("DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"):
            item = entry({"DOMAIN": "full", "DOMAIN-SUFFIX": "domain", "DOMAIN-KEYWORD": "keyword"}[kind], parts[1])
            if item:
                result[act].add(item)
        elif kind == "GEOSITE":
            result[act] |= parse_list(fetch(GEOSITE % parts[1].lower()))
        elif kind in ("RULE-SET", "RULESET"):
            result[act] |= parse_list(ruleset_text(parts[1]))
for key, out in (("proxy", out_proxy), ("block", out_block)):
    with open(out, "w", encoding="utf-8") as handle:
        handle.write("".join(x + "\n" for x in sorted(result[key])))
print("[OK] Routing-rule domains for DNS: %d proxied, %d blocked" % (len(result["proxy"]), len(result["block"])))
PY
}

parse_gfwlist() {
    local decoded
    decoded=$(mktemp "${BASE_DIR}/gfwlist.decoded.XXXXXX")
    if ! base64 -d "$GFWLIST_RAW" > "$decoded" 2>/dev/null; then
        base64 -d -i "$GFWLIST_RAW" > "$decoded" 2>/dev/null || true
    fi
    python3 - "$decoded" > "$GFWLIST_FILE" <<'PY'
import re
import sys
from urllib.parse import urlsplit

domain_re = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$")
domains = set()
with open(sys.argv[1], encoding="utf-8", errors="ignore") as source:
    for raw in source:
        line = raw.strip()
        if not line or line[0] in "!@[":
            continue
        if line.startswith("||"):
            domain = line[2:].split("^", 1)[0].split("/", 1)[0]
        elif line.startswith("|http://") or line.startswith("|https://"):
            domain = urlsplit(line[1:]).hostname or ""
        elif line.startswith("*."):
            domain = line[2:].split("/", 1)[0]
        else:
            domain = line.split("/", 1)[0].split("^", 1)[0]
        domain = domain.lstrip(".").removeprefix("www.").rstrip(".")
        if domain_re.match(domain):
            domains.add(domain)
for domain in sorted(domains):
    print(domain)
PY
    rm -f "$decoded"
}

parse_chinalist() {
    sed -n 's#^[[:space:]]*server=/\([^/]*\)/.*#\1#p' "$CHINALIST_RAW" | sort -u > "$CHINALIST_FILE"
}

yaml_upstreams() {
    local input="${1:-}" fallback="${2:-}" mode="${3:-primary}"
    local protocol="${4:-udp}"
    python3 - "$input" "$fallback" "$mode" "$protocol" <<'PY'
import ipaddress
import sys

items = list(dict.fromkeys(sys.argv[1].replace(",", " ").split()))
fallbacks = sys.argv[2].split()
mode = sys.argv[3]
protocol = sys.argv[4] if len(sys.argv) > 4 else "udp"
if mode == "primary":
    selected = items[:1] if items else fallbacks[:1]
elif mode == "secondary":
    selected = items[1:] if len(items) > 1 else [next((item for item in fallbacks if item != items[0]), fallbacks[0])] if items else fallbacks[1:]
elif mode == "all":
    # Use all items (for China DNS 4-server race).
    selected = items if items else fallbacks
else:
    selected = items if items else fallbacks
if not selected:
    selected = fallbacks
for item in selected:
    # If it is already a scheme URL, emit as-is.
    if "://" in item:
        print(f"        - addr: {item}")
        continue
    if item.count(":") > 1:
        try:
            ipaddress.ip_address(item)
            item = f"{protocol}://[{item}]:53"
        except ValueError:
            pass
    elif ":" not in item:
        item = f"{protocol}://{item}:53"
    else:
        # Already has host:port, prepend protocol.
        item = f"{protocol}://{item}"
    print(f"        - addr: {item}")
PY
}

render_config() {
    local server_ip remote_dns local_dns cache_size client_cidrs
    local remote_primary remote_secondary local_primary local_secondary
    server_ip=$(cat "$BASE_DIR/.public_ip" 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n1 || true)
    [[ -n "$server_ip" ]] || server_ip="127.0.0.1"
    remote_dns=$(cat "$BASE_DIR/.remote_dns" 2>/dev/null || printf '%s ' "${DEFAULT_REMOTE_DNS[@]}")
    local_dns=$(cat "$BASE_DIR/.local_dns" 2>/dev/null || printf '%s ' "${DEFAULT_LOCAL_DNS[@]}")
    client_cidrs=$(cat "$BASE_DIR/.client_cidrs" 2>/dev/null || true)
    # No client networks yet (added later in the bot): match nobody.
    [[ -n "${client_cidrs//[[:space:]]/}" ]] || client_cidrs="0.0.0.0/32"
    cache_size=$(cat "$BASE_DIR/.cache_size" 2>/dev/null || echo 500000)
    [[ "$cache_size" =~ ^[0-9]+$ ]] || cache_size=500000
    remote_primary=$(yaml_upstreams "$remote_dns" "1.1.1.1 8.8.8.8 9.9.9.9" primary udp)
    remote_secondary=$(yaml_upstreams "$remote_dns" "9.9.9.9 1.0.0.1" secondary udp)
    local_primary=$(yaml_upstreams "$local_dns" "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29" all udp)
    local_secondary=$(yaml_upstreams "$local_dns" "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29" all tcp)

    python3 - "$MOSDNS_TEMPLATE" "$MOSDNS_CONF.tmp" "$server_ip" "$cache_size" \
        "$remote_primary" "$remote_secondary" "$local_primary" "$local_secondary" "$client_cidrs" <<'PY'
import ipaddress, sys

template, output, server_ip, cache_size = sys.argv[1:5]
nets = list(ipaddress.collapse_addresses(
    ipaddress.IPv4Network(x, strict=False) for x in sys.argv[9].replace(",", " ").split()))
if not nets or any(n.prefixlen == 0 for n in nets):
    sys.exit("Invalid client CIDR list (empty or 0.0.0.0/0): " + sys.argv[9])
client_cidrs = " ".join(str(n) for n in nets)
with open(template, encoding="utf-8") as source:
    content = source.read()
replacements = {
    "__SERVER_IP__": server_ip,
    "__CLIENT_CIDRS__": client_cidrs,
    "__CACHE_SIZE__": cache_size,
    "__REMOTE_PRIMARY_UPSTREAMS__": sys.argv[5],
    "__REMOTE_SECONDARY_UPSTREAMS__": sys.argv[6],
    "__LOCAL_PRIMARY_UPSTREAMS__": sys.argv[7],
    "__LOCAL_SECONDARY_UPSTREAMS__": sys.argv[8],
}
for marker, value in replacements.items():
    content = content.replace(marker, value)
with open(output, "w", encoding="utf-8") as target:
    target.write(content)
PY

    # Templates contain canonical paths; staging validation must read the
    # complete candidate snapshot, never a mix of old and new domain sets.
    python3 - "$MOSDNS_CONF.tmp" "$BASE_DIR" <<'PYPATH'
import sys
p, base = sys.argv[1:]
s = open(p, encoding="utf-8").read().replace("/etc/mosdns/", base + "/")
open(p, "w", encoding="utf-8").write(s)
PYPATH
    if command -v mosdns >/dev/null 2>&1; then
        local validate_conf validate_log rc=0
        validate_conf=$(mktemp "${BASE_DIR}/config.validate.XXXXXX.yaml")
        validate_log=$(mktemp "${BASE_DIR}/config.validate.XXXXXX.log")
        sed -e 's/"127.0.0.1:8853"/"127.0.0.1:0"/g' "$MOSDNS_CONF.tmp" > "$validate_conf"
        timeout 2 mosdns start -c "$validate_conf" > "$validate_log" 2>&1 || rc=$?
        if [[ $rc -ne 0 && $rc -ne 124 ]]; then
            cat "$validate_log" >&2
            rm -f "$validate_conf" "$validate_log" "$MOSDNS_CONF.tmp"
            echo "[!] Generated mosdns configuration failed validation; running config unchanged." >&2
            return 1
        fi
        rm -f "$validate_conf" "$validate_log"
    fi
    chmod 0644 "$MOSDNS_CONF.tmp"
    mv -f "$MOSDNS_CONF.tmp" "$MOSDNS_CONF"
}

# Validate both newly parsed sets and fallback caches; empty/HTML-only data is not usable.
valid_domain_cache() {
    [[ -s "$1" ]] || return 1
    local file="$1" validator="${2:-valid_domain}" line line_number=0 count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if ! "$validator" "$line"; then
            echo "[!] Invalid domain cache entry at line ${line_number}" >&2
            return 1
        fi
        count=$((count + 1))
    done < "$file"
    (( count > 0 ))
}

update_domain_cache() {
    local label="$1" url="$2" raw_var="$3" file_var="$4" parser="$5" validator="${6:-valid_domain}"
    local raw="${!raw_var}" file="${!file_var}" work
    work=$(mktemp -d "${file}.update.XXXXXX") || return 1
    # A subshell redirects parser globals without touching live caches.
    if wget -qO "$work/raw" "$url" 2>/dev/null && (
        set -e
        printf -v "$raw_var" '%s' "$work/raw"
        printf -v "$file_var" '%s' "$work/domains"
        "$parser"
    ) && valid_domain_cache "$work/domains" "$validator"; then
        mv -f "$work/domains" "$file" || { rm -rf "$work"; return 1; }
        mv -f "$work/raw" "$raw" || { rm -rf "$work"; return 1; }
        rm -rf "$work"
        return 0
    fi
    rm -rf "$work"
    if valid_domain_cache "$file" "$validator"; then
        echo "[!] $label download/parse failed; keeping valid previous domain set" >&2
        return 0
    fi
    echo "[!] $label download/parse failed and no valid cache exists; refusing service restart" >&2
    return 1
}

# A single inherited flock serializes CLI mutations and timer updates.
lock_file="${PGW_ROUTING_LOCK_FILE:-/run/lock/simcard-dns-routing.lock}"
if [[ "${PGW_ROUTING_LOCK_FD:-}" != 9 || "$(readlink /proc/$BASHPID/fd/9 2>/dev/null || true)" != "$lock_file" ]]; then
    mkdir -p "$(dirname "$lock_file")"
    exec 9>"$lock_file"
    flock -x 9
    export PGW_ROUTING_LOCK_FD=9
fi
mode="${1:-}"
case "$mode" in ""|--offline|--render-only) ;; *) echo "Unknown update mode: $mode" >&2; exit 1;; esac
mkdir -p "$BASE_DIR"
live="$BASE_DIR"
stage="$(mktemp -d "$live/.rules-stage.XXXXXX")"
backup="$(mktemp -d "$live/.rules-backup.XXXXXX")"
files=(gfwlist.txt chinalist.txt gfwlist.raw chinalist.raw override-direct.txt override-proxy.txt override-block.txt rule-domains.txt rule-block.txt config.yaml)
was_active=0
systemctl is-active --quiet mosdns && was_active=1
published=0
finish_update() {
    local rc=$? file
    if (( rc != 0 )); then
        echo "[!] DNS snapshot failed: stage=${dns_stage:-prepare} exit=$rc; live inputs retained unless publication rollback is reported below" >&2
    fi
    trap - EXIT HUP INT TERM
    if (( rc != 0 && published )); then
        for file in "${files[@]}"; do
            if [[ -e "$backup/$file" ]]; then cp -a "$backup/$file" "$live/$file"; else rm -f "$live/$file"; fi
        done
        if (( was_active )) && [[ "$mode" != --render-only ]]; then
            systemctl restart mosdns || echo "[!] Previous files restored but mosdns recovery failed" >&2
        fi
        echo "[!] Rule update failed; previous snapshot restored" >&2
    fi
    rm -rf "$stage" "$backup"
    exit "$rc"
}
trap finish_update EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
for file in "${files[@]}"; do
    [[ ! -e "$live/$file" ]] || { cp -a "$live/$file" "$backup/$file"; cp -a "$live/$file" "$stage/$file"; }
done
for file in .remote_dns .local_dns .public_ip .cache_size .client_cidrs config.yaml.template gfwlist-extra-local.txt domain-overrides.conf; do
    [[ ! -e "$live/$file" ]] || cp -a "$live/$file" "$stage/$file"
done
# Certificates are read-only input for validation, never part of publication.
[[ ! -d "$live/certs" ]] || ln -s "$live/certs" "$stage/certs"
BASE_DIR="$stage"
GFWLIST_RAW="$stage/gfwlist.raw"; CHINALIST_RAW="$stage/chinalist.raw"
GFWLIST_FILE="$stage/gfwlist.txt"; CHINALIST_FILE="$stage/chinalist.txt"
GFWLIST_EXTRA_FILE="$stage/gfwlist-extra-local.txt"
MOSDNS_TEMPLATE="$stage/config.yaml.template"; MOSDNS_CONF="$stage/config.yaml"
dns_stage="domain-cache"
if [[ -z "$mode" ]]; then
    update_domain_cache GFWList "$GFWLIST_URL" GFWLIST_RAW GFWLIST_FILE parse_gfwlist
    update_domain_cache ChinaList "$CHINALIST_URL" CHINALIST_RAW CHINALIST_FILE parse_chinalist valid_chinalist_domain
else
    if ! valid_domain_cache "$GFWLIST_FILE"; then
        echo "[!] Offline GFWList cache is missing or invalid: $live/gfwlist.txt" >&2
        exit 1
    fi
    if ! valid_domain_cache "$CHINALIST_FILE" valid_chinalist_domain; then
        echo "[!] Offline ChinaList cache is missing or invalid: $live/chinalist.txt" >&2
        exit 1
    fi
fi
dns_stage="rule-domains"
RULE_DOMAIN_CACHE="$live/rule-domain-cache"
build_rule_domains
dns_stage="local-extras"
append_local_gfwlist_extras
sort -u -o "$GFWLIST_FILE" "$GFWLIST_FILE"
dns_stage="domain-overrides"
python3 - "$stage" <<'PYOVERRIDE'
import pathlib, re, sys
base = pathlib.Path(sys.argv[1])
sets = {key: set() for key in ("direct", "proxy", "block")}
p = base / "domain-overrides.conf"
if p.exists():
    for raw in p.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        domain, sep, action = raw.strip().partition("=")
        if not sep or action not in sets or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+", domain):
            raise SystemExit("Invalid domain override: " + raw)
        sets[action].add(domain)
for action, domains in sets.items():
    (base / ("override-" + action + ".txt")).write_text("".join(x + "\n" for x in sorted(domains)))
PYOVERRIDE
dns_stage="render-validation"
render_config
# Publish only after all candidate files and config have been validated.
python3 - "$MOSDNS_CONF" "$stage" "$live" <<'PYPUBLISH'
import sys
p, stage, live = sys.argv[1:]
s = open(p, encoding="utf-8").read().replace(stage + "/", live + "/")
open(p, "w", encoding="utf-8").write(s)
PYPUBLISH
dns_stage="publish"
published=1
for file in "${files[@]}"; do
    if [[ -f "$stage/$file" ]]; then
        chmod 0644 "$stage/$file"
        mv -f "$stage/$file" "$live/$file"
    fi
done
dns_stage="restart"
if (( was_active )) && [[ "$mode" != --render-only ]]; then
    systemctl restart mosdns
    systemctl is-active --quiet mosdns
fi
echo "[OK] Complete mosdns snapshot published; stopped services remain stopped"
