#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034 # Literal assertions; globals are read by sourced functions.
# Regional allowlist (--geo-allow): APNIC parsing with integrity checks, nft
# rendering, in-place hooking of a managed ruleset, the SSH lockout guard and
# "a failed update keeps the previous list". On Linux as root it also loads the
# generated rules into a throwaway network namespace and sends real packets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
    [[ -z "${ns_srv:-}" ]] || ip netns del "$ns_srv" 2>/dev/null || true
    [[ -z "${ns_cli:-}" ]] || ip netns del "$ns_cli" 2>/dev/null || true
    rm -rf "${tmp}"
}
trap cleanup EXIT
fail() { echo "$1" >&2; exit 1; }

info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
routing_lock() { :; }
eval "$(awk '/^normalize_client_cidrs\(\)/,/^}/' "${root}/lib/common.sh")"
eval "$(awk '/^current_client_cidrs\(\)/,/^}/' "${root}/lib/common.sh")"
export PGW_GEO_CONF="${tmp}/geo-allow.conf" PGW_GEO_NFT="${tmp}/geo-allow.nft" \
    PGW_GEO_CACHE="${tmp}/geo-ranges.txt" PGW_GEO_UNIT_DIR="${tmp}/units" \
    PGW_NFT_CONF="${tmp}/nftables.conf"
# shellcheck source=lib/host-setup.sh
. "${root}/lib/host-setup.sh"
CLIENT_CIDRS_FILE="${tmp}/.client_cidrs"
DEFAULT_CLIENT_CIDRS="203.0.113.0/24"
echo "198.51.100.0/24" > "${CLIENT_CIDRS_FILE}"
unset CLIENT_CIDRS SSH_CONNECTION
BASE_DIR=/opt/simcard-dns

# Unit sections never touch the host firewall or systemd.
nft_log="${tmp}/nft.log"
nft() { echo "nft $*" >> "$nft_log"; return 0; }
systemctl() { echo "systemctl $*" >> "${tmp}/systemctl.log"; return 0; }
who() { :; }

# --- synthetic APNIC delegated file ------------------------------------------
src="${tmp}/apnic"
make_src() {
    cat > "$src" <<'EOF'
# comment lines are skipped
2|apnic|20261018|9|19830613|20261017|+1000
apnic|*|asn|*|1|summary
apnic|*|ipv4|*|6|summary
apnic|*|ipv6|*|2|summary
apnic|HK|asn|4515|1|20000101|allocated
apnic|HK|ipv4|1.36.0.0|65536|20000101|allocated
apnic|HK|ipv4|1.37.0.0|768|20000101|assigned
apnic|TW|ipv4|1.160.0.0|65536|20000101|allocated
apnic|MO|ipv4|60.246.0.0|65536|20000101|allocated
apnic|CN|ipv4|1.0.1.0|256|20000101|allocated
apnic|HK|ipv4|1.38.0.0|256|20000101|reserved
apnic|HK|ipv6|2400:8800::|32|20000101|allocated
apnic|JP|ipv6|2001:200::|32|20000101|allocated
EOF
    write_md5
}
write_md5() {
    local sum
    sum="$(python3 -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$src")"
    printf 'MD5 (delegated-apnic-latest) = %s\n' "$sum" > "${src}.md5"
}
make_src
GEO_SOURCE="file://${src}"

# --- fetch: parse, collapse, integrity checks ------------------------------------
out="$(geo_tool fetch "$GEO_SOURCE" "tw,hk,MO" "$GEO_CACHE")" || fail "valid APNIC data must be accepted"
[[ "$out" == $'20261018\t5\t1' ]] || fail "fetch must report date, v4 and v6 counts (got: $out)"
grep -qx '# countries=HK,MO,TW' "$GEO_CACHE" || fail "cache must record the sorted country list"
grep -qx '# date=20261018' "$GEO_CACHE" || fail "cache must record the APNIC serial date"
for net in 1.36.0.0/16 1.37.0.0/23 1.37.2.0/24 1.160.0.0/16 60.246.0.0/16 2400:8800::/32; do
    grep -qx "$net" "$GEO_CACHE" || fail "cache must contain ${net}"
done
grep -qE '^1\.0\.1\.0/|^2001:200::|^1\.38\.' "$GEO_CACHE" && fail "other countries and reserved space must be excluded"
cp "$GEO_CACHE" "${tmp}/good-cache"

# A truncated download (record count below the summary) is refused.
sed -i.bak '/^apnic|MO|ipv4/d' "$src" && write_md5
geo_tool fetch "$GEO_SOURCE" "HK,MO,TW" "$GEO_CACHE" >/dev/null 2>&1 && fail "record count mismatch must be refused"
cmp -s "$GEO_CACHE" "${tmp}/good-cache" || fail "a refused download must keep the previous cache"
make_src
# Checksum mismatch is refused.
echo 'MD5 (delegated-apnic-latest) = 00000000000000000000000000000000' > "${src}.md5"
geo_tool fetch "$GEO_SOURCE" "HK,MO,TW" "$GEO_CACHE" >/dev/null 2>&1 && fail "checksum mismatch must be refused"
make_src
# Missing download is refused.
geo_tool fetch "file://${tmp}/missing" "HK" "${tmp}/x" >/dev/null 2>&1 && fail "download failure must be refused"
[[ -e "${tmp}/x" ]] && fail "a failed download must not create a cache"
# A requested country with no space is refused.
geo_tool fetch "$GEO_SOURCE" "HK,XX" "${tmp}/x" >/dev/null 2>&1 && fail "a country without address space must be refused"
# A list shrinking to under half of the previous one is refused.
cat > "$src" <<'EOF'
2|apnic|20261019|3|19830613|20261018|+1000
apnic|*|ipv4|*|3|summary
apnic|*|ipv6|*|0|summary
apnic|HK|ipv4|1.36.0.0|256|20000101|allocated
apnic|TW|ipv4|1.160.0.0|256|20000101|allocated
apnic|MO|ipv4|60.246.0.0|256|20000101|allocated
EOF
write_md5
geo_tool fetch "$GEO_SOURCE" "HK,MO,TW" "$GEO_CACHE" >/dev/null 2>&1 && fail "a list shrinking under half must be refused"
cmp -s "$GEO_CACHE" "${tmp}/good-cache" || fail "a refused shrink must keep the previous cache"
geo_tool fetch "$GEO_SOURCE" "HK,MO,TW" "${tmp}/fresh" >/dev/null || fail "the same small list is fine without a previous cache"
cp "${tmp}/good-cache" "$GEO_CACHE"
make_src

# --- stats / check -------------------------------------------------------------
[[ "$(geo_tool stats "$GEO_CACHE")" == $'updated\t20261018\nv4\t5\nv6\t1' ]] || fail "stats must summarise the cache"
[[ -z "$(geo_tool check "$GEO_CACHE" "198.51.100.0/24" 1.36.4.5 198.51.100.7 ::ffff:1.160.0.1 2400:8800::1 15:23)" ]] \
    || fail "addresses inside the regions or the client networks must pass the lockout check"
[[ "$(geo_tool check "$GEO_CACHE" "198.51.100.0/24" 1.36.4.5 8.8.8.8 2001:200::1 | paste -sd' ' -)" == "8.8.8.8 2001:200::1" ]] \
    || fail "addresses outside must be reported"

# --- render ----------------------------------------------------------------------
r="${tmp}/render.nft"
geo_tool render "$GEO_CACHE" "198.51.100.0/24 1.36.0.0/24" "853,22,8111,22" on > "$r"
grep -q 'tcp dport != { 22, 853, 8111 } return' "$r" || fail "gated ports must be rendered sorted and unique"
grep -q 'meta l4proto != tcp return' "$r" || fail "non-TCP traffic (ICMP, QUIC) must pass the gate"
grep -q 'ip saddr @geo_allow4 return' "$r" || fail "IPv4 allowlist must return to the input chain"
grep -q 'ip6 saddr @geo_allow6 return' "$r" || fail "IPv6 allowlist must return to the input chain"
grep -q 'counter drop' "$r" || fail "everything else on gated ports must be dropped and counted"
grep -q '198.51.100.0/24' "$r" || fail "client networks must always be merged into the allowlist"
grep -q '1.36.0.0/24' "$r" && fail "overlapping client prefixes must be collapsed (interval sets reject overlaps)"
grep -q '2400:8800::/32' "$r" || fail "IPv6 country space must be rendered"
grep -q '^flush chain inet filter geo_gate' "$r" || fail "reloading must replace the gate atomically"
grep -q '^flush set inet filter geo_allow4' "$r" || fail "reloading must replace the set atomically"
[[ "$(grep -c '^table inet filter {' "$r")" == 2 ]] || fail "file must declare before flushing so it loads standalone"
geo_tool render "$GEO_CACHE" "198.51.100.0/24" "22,853" off > "$r"
grep -qE 'drop|@geo_allow|elements' "$r" && fail "off must render an empty gate and empty sets"
geo_tool render "$GEO_CACHE" "198.51.100.0/24" "22;rm" on >/dev/null 2>&1 && fail "invalid ports must be refused"
geo_tool render "$GEO_CACHE" "198.51.100.0/24" "" on >/dev/null 2>&1 && fail "an empty port list must be refused"
geo_tool render "${tmp}/nope" "198.51.100.0/24" "22" on >/dev/null 2>&1 && fail "on without a cache must be refused"

# --- managed ruleset hook ------------------------------------------------------------
managed_conf() {
    cat > "$PGW_NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 22, 8111 } accept
        tcp dport 853 accept
        ip saddr { 198.51.100.0/24 } tcp dport { 80, 443 } accept
    }
}

include "/etc/simcard-dns/pgw-exit.nft"
EOF
}
managed_conf
ensure_managed_geo_hook || fail "hooking a managed ruleset must succeed"
[[ "$(sed -n 3p "$PGW_NFT_CONF")" == "include \"${PGW_GEO_NFT}\"" ]] || fail "include must follow flush ruleset"
ct_line=$(grep -n 'ct state established,related accept' "$PGW_NFT_CONF" | cut -d: -f1)
jump_line=$(grep -n '^        jump geo_gate$' "$PGW_NFT_CONF" | cut -d: -f1)
ssh_line=$(grep -n 'tcp dport { 22, 8111 } accept' "$PGW_NFT_CONF" | cut -d: -f1)
[[ "$jump_line" == $((ct_line + 1)) && "$jump_line" -lt "$ssh_line" ]] || fail "jump must sit after established and before the port accepts"
grep -qx "nft -f ${PGW_NFT_CONF}" "$nft_log" || fail "hooked ruleset must be loaded"
cp "$PGW_NFT_CONF" "${tmp}/hooked"
: > "$nft_log"
ensure_managed_geo_hook || fail "hook must be idempotent"
cmp -s "$PGW_NFT_CONF" "${tmp}/hooked" || fail "a second hook must not change the file"
[[ ! -s "$nft_log" ]] || fail "an already hooked ruleset must not be reloaded"
printf 'flush ruleset\ntable inet filter { chain input { ct state established,related accept; } }\n' > "$PGW_NFT_CONF"
rc=0; ensure_managed_geo_hook || rc=$?
[[ "$rc" == 2 ]] || fail "a non-managed ruleset must be left alone (rc 2, got $rc)"
grep -q geo "$PGW_NFT_CONF" && fail "a non-managed ruleset must not be modified"

# --- on / off / update ------------------------------------------------------------------
managed_conf
rm -f "$GEO_CONF" "$GEO_CACHE"
SSH_CONNECTION="8.8.8.8 5000 192.0.2.10 22"
(PGW_GEO_PORTS=22,853,8111 geo_allow_on) 2>"${tmp}/err" && fail "on must refuse when the admin session would lose SSH"
grep -q 'Refusing: admin session(s) from 8.8.8.8' "${tmp}/err" || fail "the refusal must name the address"
[[ -f "$GEO_CONF" ]] && fail "a refused on must not save state"
grep -q geo "$PGW_NFT_CONF" && fail "a refused on must not touch the firewall"
[[ -s "$GEO_CACHE" ]] || fail "on must download the list on first use"
SSH_CONNECTION="1.36.9.9 5000 192.0.2.10 22"
(PGW_GEO_PORTS=22,853,8111 geo_allow_on) || fail "on must succeed from an allowed admin address"
[[ "$(geo_conf_get GEO_ALLOW)" == on && "$(geo_conf_get GEO_PORTS)" == 22,853,8111 ]] || fail "on must persist state and ports"
grep -q 'counter drop' "$PGW_GEO_NFT" || fail "on must render the active gate"
grep -q 'jump geo_gate' "$PGW_NFT_CONF" || fail "on must hook the managed ruleset"
grep -q 'ExecStart=/opt/simcard-dns/bin/simcard-dns --geo-allow update' "${PGW_GEO_UNIT_DIR}/simcard-dns-geo-update.service" \
    || fail "on must install the update service"
grep -q 'OnCalendar=' "${PGW_GEO_UNIT_DIR}/simcard-dns-geo-update.timer" || fail "on must install a periodic timer"
grep -q 'enable --now simcard-dns-geo-update.timer' "${tmp}/systemctl.log" || fail "on must enable the timer"
status="$(geo_allow_status)"
for want in $'state\ton' $'v4\t5' $'ports\t22,853,8111'; do
    grep -qx "$want" <<< "$status" || fail "status must be machine-readable (got: $status)"
done

# Client list changes reach the allowlist.
echo "192.0.2.0/24" > "${CLIENT_CIDRS_FILE}"
refresh_geo_allow_clients || fail "client refresh must succeed"
grep -q '192.0.2.0/24' "$PGW_GEO_NFT" || fail "new client networks must be merged into the allowlist"

# A failed update keeps the previous list and the loaded gate.
cp "$GEO_CACHE" "${tmp}/before" && cp "$PGW_GEO_NFT" "${tmp}/before.nft"
echo 'MD5 (x) = 0' > "${src}.md5"
(geo_allow_update) 2>/dev/null && fail "update must fail on a bad download"
cmp -s "$GEO_CACHE" "${tmp}/before" || fail "a failed update must keep the previous list"
cmp -s "$PGW_GEO_NFT" "${tmp}/before.nft" || fail "a failed update must keep the loaded rules"
make_src
(geo_allow_update) || fail "update must succeed with good data"

# If the new list cannot be loaded, the previous cache is restored.
# shellcheck disable=SC2317 # Called indirectly by the functions under test.
nft() { echo "nft $*" >> "$nft_log"; [[ "$1" != -c ]]; }
(geo_allow_update) 2>/dev/null && fail "update must fail when the new rules do not validate"
cmp -s "$GEO_CACHE" "${tmp}/before" || fail "an unloadable update must restore the previous cache"
nft() { echo "nft $*" >> "$nft_log"; return 0; }

(geo_allow_off) || fail "off must succeed"
[[ "$(geo_conf_get GEO_ALLOW)" == off ]] || fail "off must persist"
grep -q 'counter drop' "$PGW_GEO_NFT" && fail "off must empty the gate"
[[ -e "${PGW_GEO_UNIT_DIR}/simcard-dns-geo-update.timer" ]] && fail "off must remove the timer"
grep -q 'jump geo_gate' "$PGW_NFT_CONF" || fail "off keeps the (now empty) hook so on/off never reloads the whole ruleset"
(geo_allow_off) || fail "off twice must be a no-op"

# Not managed: on refuses without saving anything.
printf 'flush ruleset\n' > "$PGW_NFT_CONF"
rm -f "$GEO_CONF"
(geo_allow_on) 2>/dev/null && fail "on must refuse without the managed firewall"
[[ -f "$GEO_CONF" ]] && fail "a refused on must not save state"

# --- uninstall strips the hook --------------------------------------------------------------
cp "${tmp}/hooked" "$PGW_NFT_CONF"
(
    PGW_FW_MARK="${tmp}/mark" PGW_IPT_RULES="${tmp}/ipt" PGW_AUTO_ALLOW_SCRIPT="${tmp}/fw-allow.sh" \
        PGW_AUTO_ALLOW_UNIT="${tmp}/fw-allow.service" firewall_cleanup_on_uninstall
) || fail "uninstall cleanup must succeed"
grep -qE 'geo-allow|geo_gate|pgw-exit' "$PGW_NFT_CONF" && fail "uninstall must drop the geo include, the jump and the pgw-exit include"

# --- wiring ------------------------------------------------------------------------------------
grep -qF 'include "__GEO_NFT__"' "${root}/lib/host-setup.sh" || fail "fresh managed rulesets must include the gate"
grep -A8 'ct state established,related accept' "${root}/lib/host-setup.sh" | grep -q '^        jump geo_gate$' \
    || fail "fresh managed rulesets must jump to the gate"
grep -qF -- '--geo-allow)' "${root}/install.sh" || fail "--geo-allow must be dispatched"
grep -qF '/etc/simcard-dns/pgw-exit.nft "$GEO_NFT"' "${root}/install.sh" || fail "--upgrade must snapshot geo-allow.nft"
grep -qF 'refresh_geo_allow_clients' "${root}/lib/dns.sh" || fail "client list changes must refresh the allowlist"
grep -qF ',simcard-dns-geo-update,' "${root}/lib/uninstall.sh" || fail "uninstall must remove the timer units"

# --- real nftables in throwaway network namespaces (Linux, root) ---------------------------------
if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]] && command -v ip >/dev/null && type -P nft >/dev/null; then
    unset -f nft
    ns_srv="geo-srv-$$"; ns_cli="geo-cli-$$"
    ip netns add "$ns_srv"; ip netns add "$ns_cli"
    ip link add "gv$$a" type veth peer name "gv$$b"
    ip link set "gv$$a" netns "$ns_srv"; ip link set "gv$$b" netns "$ns_cli"
    ip -n "$ns_srv" addr add 10.99.0.1/24 dev "gv$$a"
    ip -n "$ns_srv" link set "gv$$a" up; ip -n "$ns_srv" link set lo up
    ip -n "$ns_cli" link set "gv$$b" up; ip -n "$ns_cli" link set lo up
    # Client source addresses: one inside HK space, one client network, one outside.
    for a in 1.36.0.2/32 198.51.100.2/32 44.0.0.2/32; do ip -n "$ns_cli" addr add "$a" dev "gv$$b"; done
    ip -n "$ns_cli" route add 10.99.0.0/24 dev "gv$$b"
    for a in 1.36.0.2 198.51.100.2 44.0.0.2; do ip -n "$ns_srv" route add "$a/32" dev "gv$$a"; done
    echo "198.51.100.0/24" > "${CLIENT_CIDRS_FILE}"
    geo_write_conf on 22,853 HK,MO,TW
    nft_real() { ip netns exec "$ns_srv" nft "$@"; }
    geo_tool render "$GEO_CACHE" "$(current_client_cidrs)" 22,853 on > "$PGW_GEO_NFT"
    managed_conf
    sed -i "s#include \"/etc/simcard-dns/pgw-exit.nft\"##" "$PGW_NFT_CONF"
    sed -i "s#^flush ruleset#flush ruleset\ninclude \"${PGW_GEO_NFT}\"#; s#ct state established,related accept#&\n        jump geo_gate#" "$PGW_NFT_CONF"
    nft_real -c -f "$PGW_GEO_NFT" || fail "rendered geo-allow.nft must validate standalone"
    nft_real -f "$PGW_NFT_CONF" || fail "managed ruleset with the gate must load"
    nft_real -f "$PGW_GEO_NFT" || fail "geo-allow.nft must reload on top of a live ruleset"
    ip netns exec "$ns_srv" python3 -c '
import socket, threading
for port in (22, 853, 8111):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("10.99.0.1", port)); s.listen(16)
    threading.Thread(target=lambda s=s: [s.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
threading.Event().wait(60)
' & listener=$!
    sleep 1
    probe() { ip netns exec "$ns_cli" python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(2); s.bind((sys.argv[1], 0))
try:
    s.connect(("10.99.0.1", int(sys.argv[2]))); print("open")
except OSError:
    print("blocked")' "$1" "$2"; }
    [[ "$(probe 1.36.0.2 22)" == open ]] || fail "HK source must reach SSH"
    [[ "$(probe 198.51.100.2 853)" == open ]] || fail "client network must reach DoT"
    [[ "$(probe 44.0.0.2 22)" == blocked ]] || fail "outside source must not reach SSH"
    [[ "$(probe 44.0.0.2 853)" == blocked ]] || fail "outside source must not reach DoT"
    [[ "$(probe 44.0.0.2 8111)" == open ]] || fail "ungated ports keep their own rules"
    gate="$(nft_real list chain inet filter geo_gate)"
    grep -qE 'counter packets [1-9]' <<< "$gate" || fail "drops must be counted"
    geo_write_conf off 22,853 HK,MO,TW
    geo_tool render "$GEO_CACHE" "$(current_client_cidrs)" 22,853 off > "$PGW_GEO_NFT"
    nft_real -f "$PGW_GEO_NFT" || fail "off must reload standalone"
    [[ "$(probe 44.0.0.2 22)" == open ]] || fail "off must reopen SSH to everyone"
    kill "$listener" 2>/dev/null || true
    echo "geo allow: netns packet test OK"
else
    echo "geo allow: netns packet test skipped (needs Linux + root + nft)"
fi

echo "geo allow policy OK"
