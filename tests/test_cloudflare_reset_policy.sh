#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # Globals/mocks are used by eval-loaded functions.
# Cloudflare one-click domain reset, against a local mock of the Cloudflare
# API: zone discovery, wildcard certificate request, new random record (DNS
# only), switching the DoT name, deleting only the old name's record that
# points at this server, and a full rollback when the switch fails.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
fail() { echo "$1" >&2; exit 1; }
info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
for fn in cf_api cf_conf cf_configured cf_json cf_random_label cf_create_a_record cf_dot_records cf_retire_dot_records \
    cf_wait_record issue_wildcard_cert setup_cloudflare apply_wildcard_dot_domain reset_dot_domain; do
    eval "$(awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/cert.sh")"
done

# --- mock Cloudflare API ------------------------------------------------------
cat > "${tmp}/cf.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
records = [
    {"id": "old1", "type": "A", "name": "c6p1old.dns.example.net", "content": "203.0.113.10", "comment": "5gpn-x DoT"},
    {"id": "old2", "type": "A", "name": "c6p1old.dns.example.net", "content": "198.51.100.1", "comment": "simcard-dns DoT"},
    {"id": "stale", "type": "A", "name": "z9z9prev.dns.example.net", "content": "203.0.113.10", "comment": "simcard-dns-x DoT"},
    {"id": "keep", "type": "A", "name": "keepme.example.net", "content": "203.0.113.10"},
    {"id": "keep2", "type": "A", "name": "mine.dns.example.net", "content": "203.0.113.10", "comment": "set by hand"},
]
seq = []  # monotonic record ids, like Cloudflare (never reused)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, result, ok=True, code=200):
        body = json.dumps({"success": ok, "result": result,
                           "errors": [] if ok else [{"message": "denied"}]}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def route(self, method):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == "/__state":
            return self.reply(records)
        if self.headers.get("Authorization") != "Bearer tok":
            return self.reply(None, False, 403)
        if u.path == "/zones":
            return self.reply([{"id": "z1", "name": "example.net"}] if q.get("name") == "example.net" else [])
        if u.path == "/zones/z1/dns_records" and method == "GET":
            rs = [r for r in records if all(r.get(k) == v for k, v in q.items() if k in ("type", "name"))]
            return self.reply(rs[: int(q.get("per_page", 100))])
        if u.path == "/zones/z1/dns_records" and method == "POST":
            rec = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seq.append(1); rec["id"] = "new%d" % len(seq); records.append(rec)
            return self.reply(rec)
        if u.path.startswith("/zones/z1/dns_records/") and method == "DELETE":
            rid = u.path.rsplit("/", 1)[1]; records[:] = [r for r in records if r["id"] != rid]
            return self.reply({"id": rid})
        return self.reply(None, False, 404)
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_DELETE(self): self.route("DELETE")
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
python3 "${tmp}/cf.py" > "${tmp}/port" & cf_pid=$!; disown "$cf_pid"
trap 'kill $cf_pid 2>/dev/null; rm -rf "${tmp}"' EXIT
for _ in $(seq 1 50); do [[ -s "${tmp}/port" ]] && break; sleep 0.1; done
PGW_CF_API="http://127.0.0.1:$(cat "${tmp}/port")"
export PGW_CF_API
state() { curl -s "${PGW_CF_API}/__state" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["result"]))'; }

# --- environment and mocks ----------------------------------------------------
CONF_DIR="${tmp}/conf"; mkdir -p "$CONF_DIR"
CF_CREDENTIALS="${tmp}/cloudflare.ini"; CF_CONF="${tmp}/cloudflare.conf"
CF_CERT_NAME="simcard-dns-wildcard"; CF_DOT_LABEL="dns"
MOSDNS_DIR="${tmp}/mosdns"; mkdir -p "$MOSDNS_DIR"
LE_LIVE_DIR="${tmp}/live"; LE_DEPLOY_HOOK_DIR="${tmp}/hooks"; LIB_DIR="${root}/lib"
echo "c6p1old.example.net" > "${CONF_DIR}/.domain"; echo "203.0.113.10" > "${MOSDNS_DIR}/.public_ip"
mkdir -p "${tmp}/bin" "${tmp}/py/certbot_dns_cloudflare"; : > "${tmp}/py/certbot_dns_cloudflare/__init__.py"
export PYTHONPATH="${tmp}/py"
cat > "${tmp}/bin/certbot" <<MOCK
#!/bin/bash
echo "\$*" >> "${tmp}/certbot.log"
mkdir -p "${LE_LIVE_DIR}/simcard-dns-wildcard"
echo cert > "${LE_LIVE_DIR}/simcard-dns-wildcard/fullchain.pem"; echo key > "${LE_LIVE_DIR}/simcard-dns-wildcard/privkey.pem"
MOCK
printf '#!/bin/bash\necho "$*" >> "%s/updater.log"\n[[ ! -f "%s/updater.fail" ]]\n' "$tmp" "$tmp" > "${tmp}/updater"
chmod +x "${tmp}/bin/certbot" "${tmp}/updater"
export PATH="${tmp}/bin:$PATH" PGW_RULES_UPDATER="${tmp}/updater"
routing_lock() { :; }
regenerate_ios_profile() { echo regen >> "${tmp}/ios.log"; }
get_public_ip() { PUBLIC_IP=203.0.113.10; }
# Cloudflare's nameservers serve whatever the mock API holds.
cf_record_visible() { state | python3 -c 'import json,sys; sys.exit(0 if any(r["name"]==sys.argv[1] and r["content"]==sys.argv[2] for r in json.load(sys.stdin)) else 1)' "$1" "$2"; }
domain_resolves_to_public_ip() { echo "public resolvers must not be polled for a new name" >&2; return 1; }

# --- connect ------------------------------------------------------------------
( CF_API_TOKEN=wrong setup_cloudflare ) 2>/dev/null && fail "a rejected token must not be accepted"
[[ ! -e "$CF_CREDENTIALS" ]] || fail "a rejected token must not be stored"
CF_API_TOKEN=tok setup_cloudflare >/dev/null
[[ "$(cf_conf zone)" == example.net && "$(cf_conf zone_id)" == z1 ]] || fail "zone must be discovered from the current domain"
[[ "$(stat -c %a "$CF_CREDENTIALS" 2>/dev/null || stat -f %Lp "$CF_CREDENTIALS")" == 600 ]] || fail "token file must be private"
grep -q -- '--dns-cloudflare' "${tmp}/certbot.log" || fail "wildcard certificate must be requested via DNS-01"
grep -q -- '-d \*.dns.example.net' "${tmp}/certbot.log" || fail "certificate must cover *.dns.<zone>"
[[ -x "${LE_DEPLOY_HOOK_DIR}/99-reload-mosdns.sh" ]] || fail "renewal deploy hook must be installed"

# --- reset --------------------------------------------------------------------
out="$(reset_dot_domain)"
new="$(sed -n 's/^NEW_DOMAIN=//p' <<< "$out")"
[[ "$new" =~ ^[a-z0-9]{20}\.dns\.example\.net$ ]] || fail "new domain must be a random 20-char label: $new"
[[ "$(cat "${CONF_DIR}/.domain")" == "$new" && "$(cat "${MOSDNS_DIR}/.domain")" == "$new" ]] || fail "DoT domain must switch"
[[ "$(cat "${CONF_DIR}/.cert_lineage")" == simcard-dns-wildcard ]] || fail "wildcard lineage must be recorded for renewals"
[[ "$(cat "${MOSDNS_DIR}/certs/fullchain.pem")" == cert ]] || fail "wildcard certificate must be installed for mosdns"
grep -qx -- '--offline' "${tmp}/updater.log" || fail "mosdns must be reloaded"
state | python3 -c '
import json, sys
rs = {r["id"]: r for r in json.load(sys.stdin)}
new = [r for r in rs.values() if r["name"] == sys.argv[1]]
assert len(new) == 1 and new[0]["content"] == "203.0.113.10" and new[0]["proxied"] is False and new[0]["ttl"] == 60, new
assert "old1" not in rs, "the previous DoT record of this server must be deleted"
assert "stale" not in rs, "DoT records left by earlier installs must be deleted too"
assert "old2" in rs, "DoT records pointing at another server must be kept"
assert "keep" in rs and "keep2" in rs, "records this project did not create must be kept"
' "$new" || fail "Cloudflare records are wrong after reset"

# --- failed switch rolls everything back ---------------------------------------
touch "${tmp}/updater.fail"
before="$(cat "${CONF_DIR}/.domain")"
( reset_dot_domain ) >/dev/null 2>&1 && fail "a failed mosdns reload must fail the reset"
[[ "$(cat "${CONF_DIR}/.domain")" == "$before" ]] || fail "domain must roll back"
state | python3 -c '
import json, sys
mine = [r["name"] for r in json.load(sys.stdin)
        if r.get("comment") == "simcard-dns DoT" and r["content"] == "203.0.113.10"]
assert mine == [sys.argv[1]], mine   # only the current name; the failed new record is gone
' "$before" || fail "the record created by a failed reset must be deleted"

# --- waiting asks Cloudflare's nameservers, not public resolvers ------------------
eval "$(awk '/^cf_record_visible\(\)/,/^}/' "${root}/lib/cert.sh")"
cat > "${tmp}/bin/dig" <<'MOCK'
#!/bin/bash
echo "$*" >> "$DIG_LOG"
case "$*" in
  "+short NS example.net") printf 'ns1.example.cf.\nns2.example.cf.\n' ;;
  *"@ns2.example.cf.") echo 203.0.113.10 ;;
esac
MOCK
chmod +x "${tmp}/bin/dig"
export DIG_LOG="${tmp}/dig.log"
cf_record_visible new.dns.example.net 203.0.113.10 || fail "a name served by the zone nameservers must count as visible"
grep -q '@ns1.example.cf.' "$DIG_LOG" || fail "the zone's own nameservers must be asked"
grep -qE '@(1\.1\.1\.1|8\.8\.8\.8)' "$DIG_LOG" && fail "public resolvers must not be asked (they cache 'no such name')"
cf_record_visible new.dns.example.net 198.51.100.9 && fail "a different address must not count"

echo "Cloudflare domain reset policy OK"
