#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317 # Literal assertions; globals/mocks are used by eval-loaded functions.
# The DoT record self-check (simcard-dns --check-dot-record, every 15 minutes):
# when the current DoT name has no A record on Cloudflare pointing at this
# server it is recreated, and the result is written for the bot's status card.
set -euo pipefail
exec </dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
fail() { echo "$1" >&2; exit 1; }
info() { :; }; warn() { echo "WARN $*" >> "${tmp}/warn"; }; ok() { :; }; err() { echo "$*" >&2; }
for fn in cf_api cf_conf cf_configured cf_json cf_create_a_record dot_check_write check_dot_record install_dot_check_timer; do
    eval "$(awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/cert.sh")"
done

# --- wiring ------------------------------------------------------------------------
grep -qF -- '    --check-dot-record)' "${root}/install.sh" || fail "--check-dot-record must be dispatched"
grep -qF 'install_dot_check_timer' <<< "$(awk '/^setup_schedules\(\)/,/^}/' "${root}/lib/services.sh")" \
    || fail "fresh installs must schedule the check"
grep -qF 'install_dot_check_timer' "${root}/install.sh" || fail "upgrades must schedule the check"
grep -qF 'simcard-dns-dot-check' "${root}/lib/uninstall.sh" || fail "uninstall must remove the timer"
mkdir -p "${tmp}/units"
systemctl() { echo "systemctl $*" >> "${tmp}/systemctl.log"; }
BASE_DIR=/opt/simcard-dns PGW_DOT_CHECK_UNIT_DIR="${tmp}/units" install_dot_check_timer
grep -q 'ExecStart=/opt/simcard-dns/bin/simcard-dns --check-dot-record' "${tmp}/units/simcard-dns-dot-check.service" \
    || fail "the service must run the check"
grep -q 'OnUnitActiveSec=15min' "${tmp}/units/simcard-dns-dot-check.timer" || fail "the check must run every 15 minutes"
grep -q 'enable --now simcard-dns-dot-check.timer' "${tmp}/systemctl.log" || fail "the timer must be enabled"

# --- mock Cloudflare API --------------------------------------------------------------
cat > "${tmp}/cf.py" <<'PY'
import json, os, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
records = []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, result, ok=True, code=200):
        body = json.dumps({"success": ok, "result": result, "errors": [] if ok else [{"message": "x"}]}).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def route(self, method):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == "/__state":
            return self.reply(records)
        if u.path == "/__clear":
            records.clear(); return self.reply([])
        if os.path.exists(os.environ["CF_DOWN"]):
            return self.reply(None, False, 500)
        if u.path == "/zones/z1/dns_records" and method == "GET":
            return self.reply([r for r in records if all(r.get(k) == v for k, v in q.items() if k in ("type", "name"))])
        if u.path == "/zones/z1/dns_records" and method == "POST":
            rec = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            rec["id"] = "r%d" % (len(records) + 1); records.append(rec)
            return self.reply(rec)
        return self.reply(None, False, 404)
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
export CF_DOWN="${tmp}/cf-down"
python3 "${tmp}/cf.py" > "${tmp}/port" & cf_pid=$!; disown "$cf_pid"
trap 'kill $cf_pid 2>/dev/null; rm -rf "${tmp}"' EXIT
for _ in $(seq 1 50); do [[ -s "${tmp}/port" ]] && break; sleep 0.1; done
PGW_CF_API="http://127.0.0.1:$(cat "${tmp}/port")"
export PGW_CF_API
api() { python3 -c 'import json,sys,urllib.request; print(json.dumps(json.load(urllib.request.urlopen(sys.argv[1]))["result"]))' "${PGW_CF_API}/$1"; }

CONF_DIR="${tmp}/conf"; MOSDNS_DIR="${tmp}/mosdns"; mkdir -p "$CONF_DIR" "$MOSDNS_DIR"
CF_CREDENTIALS="${tmp}/cloudflare.ini"; CF_CONF="${tmp}/cloudflare.conf"; CF_DOT_LABEL=dns
DOT_CHECK_STATUS="${tmp}/state/dot-record.status"
routing_lock() { :; }
get_public_ip() { PUBLIC_IP=192.0.2.10; }
echo 192.0.2.10 > "${MOSDNS_DIR}/.public_ip"
state_of() { sed -n "s/^$1=//p" "$DOT_CHECK_STATUS"; }

# The real command runs under `set -euo pipefail` (install.sh) and the first run
# has no status file yet; it must not stop silently.
# A separate bash process: errexit inside `( ... ) || fail` would be ignored.
echo abc.dns.example.org > "${CONF_DIR}/.domain"
{
    echo 'set -euo pipefail'
    echo 'info() { :; }; warn() { :; }; ok() { :; }; err() { echo "$*" >&2; }; routing_lock() { :; }'
    for fn in cf_conf cf_configured dot_check_write check_dot_record; do
        awk "/^${fn}\\(\\)/,/^}/" "${root}/lib/cert.sh"
    done
    printf 'CONF_DIR=%q; CF_CONF=%q; CF_CREDENTIALS=%q; CF_DOT_LABEL=dns; DOT_CHECK_STATUS=%q\n' \
        "$CONF_DIR" "${tmp}/none.conf" "${tmp}/none.ini" "$DOT_CHECK_STATUS"
    echo 'check_dot_record'
    echo 'echo reached-end'
} > "${tmp}/first-run.sh"
set +e; first_run="$(bash "${tmp}/first-run.sh" 2>&1)"; set -e
[[ "$first_run" == *reached-end* ]] || fail "the first run (no status file yet) must work under set -euo pipefail: $first_run"
rm -f "$DOT_CHECK_STATUS"

# Not on Cloudflare: nothing to check.
echo dns.example.org > "${CONF_DIR}/.domain"
check_dot_record || fail "an own-domain install must not fail the check"
[[ "$(state_of state)" == not-cloudflare ]] || fail "own-domain installs must be reported as not managed"

printf 'dns_cloudflare_api_token = tok\n' > "$CF_CREDENTIALS"
printf 'zone=example.net\nzone_id=z1\n' > "$CF_CONF"
echo abc123.dns.example.net > "${CONF_DIR}/.domain"

# Missing record: recreated, pointing here, DNS only, with our comment.
check_dot_record || fail "a missing record must be recreated"
python3 - "$(api __state)" <<'PY' || fail "the recreated record must be a DNS-only A record for the current name"
import json, sys
recs = json.loads(sys.argv[1])
assert len(recs) == 1, recs
r = recs[0]
assert (r["type"], r["name"], r["content"], r["proxied"], r["comment"]) == ("A", "abc123.dns.example.net", "192.0.2.10", False, "simcard-dns DoT"), r
PY
[[ "$(state_of state)" == ok && -n "$(state_of recreated_at)" ]] || fail "the status must record that the record was recreated"
grep -q 'was missing on Cloudflare; recreated' "${tmp}/warn" || fail "recreating must be logged"
recreated="$(state_of recreated_at)"

# Present record: nothing created, recreation time kept for the bot.
check_dot_record || fail "an existing record must pass"
[[ "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$(api __state)")" == 1 ]] || fail "no duplicate may be created"
[[ "$(state_of state)" == ok && "$(state_of recreated_at)" == "$recreated" ]] || fail "a later ok run must keep the last recreation time"

# A record of the same name pointing elsewhere does not count.
api __clear >/dev/null
python3 - "$PGW_CF_API" <<'PY'
import json, sys, urllib.request
body = json.dumps({"type": "A", "name": "abc123.dns.example.net", "content": "198.51.100.1"}).encode()
req = urllib.request.Request(sys.argv[1] + "/zones/z1/dns_records", data=body, method="POST",
                             headers={"Authorization": "Bearer tok", "Content-Type": "application/json"})
urllib.request.urlopen(req).read()
PY
check_dot_record
[[ "$(python3 -c 'import json,sys; print(sorted(r["content"] for r in json.loads(sys.argv[1])))' "$(api __state)")" == "['192.0.2.10', '198.51.100.1']" ]] \
    || fail "a record pointing at another server must not count as ours"

# Cloudflare unreachable: reported, not hidden.
touch "$CF_DOWN"
check_dot_record 2>/dev/null && fail "an unreachable API must fail the check"
[[ "$(state_of state)" == error ]] || fail "an unreachable API must be reported"
rm -f "$CF_DOWN"

echo "DoT record check OK"
