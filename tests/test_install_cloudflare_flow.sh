#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # Globals/mocks are used by eval-loaded functions.
# Fresh installs ask for a Cloudflare API token instead of a domain, and the
# Telegram bot is required. Against a local mock of the Cloudflare API: token
# validation, zone choice, the install-time certificate stage (DNS-01 wildcard,
# DNS-only A record for a random name, mosdns cert files, domain markers), and
# the non-interactive guards for the Cloudflare and Telegram inputs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
fail() { echo "$1" >&2; exit 1; }
info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }
for fn in cf_api cf_conf cf_json issue_wildcard_cert cf_random_label cf_save_token cf_list_zones \
    cf_create_a_record collect_cloudflare_token select_cloudflare_zone install_cloudflare_cert; do
    eval "$(awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/cert.sh")"
done
eval "$(awk '/^read_tgbot_setting\(\)/,/^}/' "${root}/lib/services.sh")"
eval "$(sed -n '/^collect_tgbot_settings()/,/^install_ctl_entrypoint()/p' "${root}/lib/services.sh" | sed '$d')"

# --- static flow ---------------------------------------------------------------
main_body="$(awk '/^main_install\(\)/,/^}/' "${root}/install.sh")"
deps_line="$(grep -n '安装系统依赖' <<< "$main_body" | head -1 | cut -d: -f1)"
cf_line="$(grep -n 'collect_cloudflare_token' <<< "$main_body" | head -1 | cut -d: -f1)"
tg_line="$(grep -n 'TG_BOT_REQUIRED=1 collect_tgbot_settings' <<< "$main_body" | head -1 | cut -d: -f1)"
[[ -n "$cf_line" && -n "$tg_line" && "$cf_line" -lt "$deps_line" && "$tg_line" -lt "$deps_line" ]] \
    || fail "Cloudflare and Telegram must both be asked before the long dependency install"
grep -qF 'install_stage_cloudflare_certificate' <<< "$main_body" || fail "fresh installs must issue the certificate through Cloudflare"
grep -qF '[[ -z "${DOMAIN:-}" ]] || use_cloudflare=0' <<< "$main_body" || fail "DOMAIN must keep the own-domain flow as an advanced option"
grep -qF 'read -rsp "Cloudflare API Token' "${root}/lib/cert.sh" || fail "the Cloudflare token must be typed without echo"
grep -qF -- 'collect_tgbot_settings' <<< "$(awk '/^install_stage_finalize\(\)/,/^}/' "${root}/install.sh")" \
    && fail "the bot must not be asked late in the install"

# --- mock Cloudflare API ------------------------------------------------------
cat > "${tmp}/cf.py" <<'PY'
import json, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
records = []
ZONES = {"Bearer tok": [{"id": "z1", "name": "example.net"}],
         "Bearer multi": [{"id": "za", "name": "a.example"}, {"id": "zb", "name": "b.example"}]}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, result, ok=True, code=200):
        body = json.dumps({"success": ok, "result": result,
                           "errors": [] if ok else [{"message": "Invalid API Token"}]}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def route(self, method):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/__state":
            return self.reply(records)
        zones = ZONES.get(self.headers.get("Authorization"))
        if zones is None:
            return self.reply(None, False, 403)
        if u.path == "/zones":
            return self.reply(zones)
        if u.path.endswith("/dns_records") and method == "POST":
            rec = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            rec["id"] = "r%d" % (len(records) + 1); rec["zone"] = u.path.split("/")[2]; records.append(rec)
            return self.reply(rec)
        return self.reply(None, False, 404)
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
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

CONF_DIR="${tmp}/conf"; mkdir -p "$CONF_DIR"
CF_CREDENTIALS="${tmp}/etc/cloudflare.ini"; CF_CONF="${tmp}/etc/cloudflare.conf"
CF_CERT_NAME="simcard-dns-wildcard"; CF_DOT_LABEL="dns"
MOSDNS_DIR="${tmp}/mosdns"; LE_LIVE_DIR="${tmp}/live"; LE_DEPLOY_HOOK_DIR="${tmp}/hooks"; LIB_DIR="${root}/lib"
unset CF_API_TOKEN CF_ZONE TG_BOT_TOKEN TG_ADMIN_IDS

# --- token + zone selection (stdin is not a terminal here) --------------------------
(collect_cloudflare_token) </dev/null 2>/dev/null && fail "a non-interactive install without CF_API_TOKEN must stop"
CF_API_TOKEN=bad CF_PENDING_TOKEN=bad
(select_cloudflare_zone) </dev/null 2>/dev/null && fail "a rejected token must stop a non-interactive install"
[[ ! -e "$CF_CREDENTIALS" ]] || fail "a rejected token must not stay on disk"

CF_API_TOKEN=tok; collect_cloudflare_token </dev/null
select_cloudflare_zone </dev/null || fail "a token with one zone must be accepted"
[[ "$CF_ZONE" == example.net && "$CF_ZONE_ID" == z1 ]] || fail "the only zone must be chosen automatically"
[[ "$(cf_conf zone)" == example.net && "$(cf_conf zone_id)" == z1 ]] || fail "zone must be saved for renewals and resets"
grep -qx 'dns_cloudflare_api_token = tok' "$CF_CREDENTIALS" || fail "token must be saved for certbot"
[[ "$(stat -c %a "$CF_CREDENTIALS" 2>/dev/null || stat -f %Lp "$CF_CREDENTIALS")" == 600 ]] || fail "token file must be mode 600"
[[ -z "${CF_PENDING_TOKEN:-}" ]] || fail "the token must not stay in a shell variable"

CF_API_TOKEN=multi; collect_cloudflare_token </dev/null
(select_cloudflare_zone) </dev/null 2>/dev/null && fail "several zones without CF_ZONE must stop a non-interactive install"
CF_API_TOKEN=multi; collect_cloudflare_token </dev/null; CF_ZONE=B.example
select_cloudflare_zone </dev/null || fail "CF_ZONE must pick one of several zones"
[[ "$CF_ZONE" == b.example && "$CF_ZONE_ID" == zb ]] || fail "CF_ZONE must select the matching zone"
CF_API_TOKEN=multi; collect_cloudflare_token </dev/null; CF_ZONE=c.example
(select_cloudflare_zone) </dev/null 2>/dev/null && fail "a zone the token cannot manage must be refused"

# --- install-time certificate stage --------------------------------------------------
CF_API_TOKEN=tok; unset CF_ZONE; collect_cloudflare_token </dev/null; select_cloudflare_zone </dev/null
label="$(cf_random_label)"
[[ "$label" =~ ^[a-z0-9]{20}$ ]] || fail "DoT label must be 20 random lowercase characters"
DOMAIN="${label}.dns.example.net"; PUBLIC_IP=192.0.2.10
ensure_mosdns_user() { :; }
mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/certbot" <<MOCK
#!/bin/bash
echo "\$*" >> "${tmp}/certbot.log"
mkdir -p "${LE_LIVE_DIR}/simcard-dns-wildcard"
echo cert > "${LE_LIVE_DIR}/simcard-dns-wildcard/fullchain.pem"; echo key > "${LE_LIVE_DIR}/simcard-dns-wildcard/privkey.pem"
MOCK
chmod +x "${tmp}/bin/certbot"
PATH="${tmp}/bin:${PATH}" install_cloudflare_cert || fail "the Cloudflare certificate stage must succeed"
grep -q -- '--dns-cloudflare' "${tmp}/certbot.log" || fail "the certificate must use DNS-01 (no TCP/80)"
grep -qF -- '-d *.dns.example.net' "${tmp}/certbot.log" || fail "the certificate must be the *.dns.<zone> wildcard"
python3 - "$(state)" "$DOMAIN" <<'PY' || fail "exactly one DNS-only A record for the new name must be created"
import json, sys
recs, name = json.loads(sys.argv[1]), sys.argv[2]
assert len(recs) == 1, recs
r = recs[0]
assert (r["type"], r["name"], r["content"], r["proxied"], r["zone"]) == ("A", name, "192.0.2.10", False, "z1"), r
PY
[[ "$(cat "${CONF_DIR}/.domain")" == "$DOMAIN" ]] || fail "the random name must become the DoT domain"
[[ "$(cat "${CONF_DIR}/.cert_lineage")" == simcard-dns-wildcard ]] || fail "renewals must use the wildcard lineage"
[[ -s "${MOSDNS_DIR}/certs/fullchain.pem" && -s "${MOSDNS_DIR}/certs/privkey.pem" ]] || fail "mosdns must get the certificate"
[[ -x "${LE_DEPLOY_HOOK_DIR}/99-reload-mosdns.sh" ]] || fail "the renewal deploy hook must be installed"

# --- Telegram is required on fresh installs --------------------------------------------
(TG_BOT_REQUIRED=1 collect_tgbot_settings) </dev/null 2>/dev/null && fail "a fresh install without TG_BOT_TOKEN must stop"
(TG_BOT_REQUIRED=1 TG_BOT_TOKEN='123:ABC' TG_ADMIN_IDS='' collect_tgbot_settings) </dev/null 2>/dev/null \
    && fail "a fresh install without an admin ID must stop"
(TG_BOT_REQUIRED=1 TG_BOT_TOKEN='not-a-token' TG_ADMIN_IDS=1 collect_tgbot_settings) </dev/null 2>/dev/null \
    && fail "an invalid token must stop a non-interactive install"
TG_BOT_REQUIRED=1; TG_BOT_TOKEN='123:ABC_def'; TG_ADMIN_IDS='12, 34'
collect_tgbot_settings </dev/null || fail "valid Telegram settings must be accepted"
[[ "$TG_BOT_TOKEN" == '123:ABC_def' && "$TG_ADMIN_IDS" == 12,34 && "$TG_BOT_SETTINGS_COLLECTED" == 1 ]] \
    || fail "Telegram settings must be normalised and marked collected"
TG_BOT_REQUIRED=0; TG_BOT_TOKEN=''; TG_ADMIN_IDS=''
collect_tgbot_settings </dev/null || fail "--setup-tgbot outside the installer may still skip"
[[ -z "$TG_BOT_TOKEN" ]] || fail "an optional empty token must skip the bot"

echo "install Cloudflare flow OK"
