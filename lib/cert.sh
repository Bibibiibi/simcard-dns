#!/usr/bin/env bash
# simcard-dns module: cert
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

resolve_domain_a_records() {
    local domain="${1:-}" resolver="" line=""
    local records=()
    local public_resolvers=(1.1.1.1 8.8.8.8 9.9.9.9 223.5.5.5 114.114.114.114)
    if command -v dig >/dev/null 2>&1; then
        for resolver in "${public_resolvers[@]}"; do
            while IFS= read -r line; do
                [[ "$line" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && records+=("$line")
            done < <(dig +time=2 +tries=1 +short A "$domain" @"$resolver" 2>/dev/null || true)
        done
    fi
    if command -v getent >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && records+=("$line")
        done < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ ${#records[@]} -gt 0 ]]; then
        printf '%s\n' "${records[@]}" | awk '!seen[$0]++'
    fi
}

domain_resolves_to_public_ip() {
    local domain="${1:-}" expected_ip="${2:-}" ip=""
    [[ -n "$domain" && -n "$expected_ip" ]] || return 1
    while IFS= read -r ip; do
        [[ "$ip" == "$expected_ip" ]] && return 0
    done < <(resolve_domain_a_records "$domain")
    return 1
}

certbot_diagnostics() {
    local domain="${1:-}" resolved=""
    resolved=$(resolve_domain_a_records "$domain" | paste -sd',' - || true)
    echo "诊断: domain=${domain:-未知}"
    echo "诊断: public_ip=${PUBLIC_IP:-未知}"
    echo "诊断: resolved=${resolved:-无}"
    echo "诊断: certbot=$(command -v certbot 2>/dev/null || echo missing)"
    if command -v ss >/dev/null 2>&1; then
        echo "诊断: tcp80_listen=$(ss -H -ltnp 'sport = :80' 2>/dev/null | head -n 3 | sed 's/[[:space:]]\+/ /g' | paste -sd ';' - || true)"
    fi
}

is_valid_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]
}

generate_domain() {
    if [[ -n "${DOMAIN:-}" ]]; then
        DOMAIN="${DOMAIN,,}"  # normalize to lowercase (certbot always lowercases)
        if ! is_valid_domain "$DOMAIN"; then
            err "Invalid DOMAIN: '$DOMAIN'. Provide a fully-qualified domain like dns.example.com"
            exit 1
        fi
        [[ -z "${INSTALL_LOG:-}" ]] || info "Using pre-configured domain: $DOMAIN" >> "$INSTALL_LOG"
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi
    if [[ ! -t 0 ]]; then
        err "No domain provided. Set the DOMAIN environment variable (e.g. DOMAIN=dns.example.com) for non-interactive installs."
        exit 1
    fi
    local input=""
    while true; do
        read -r -p "域名（如 dns.example.com）: " input
        input="${input## }"; input="${input%% }"
        input="${input#http://}"; input="${input#https://}"
        input="${input%/}"
        if is_valid_domain "$input"; then
            DOMAIN="$input"
            DOMAIN="${DOMAIN,,}"  # normalize to lowercase
            break
        fi
        warn "无效域名，请输入形如 dns.example.com 的完整域名"
    done
    [[ -z "${INSTALL_LOG:-}" ]] || info "Using domain: $DOMAIN" >> "$INSTALL_LOG"
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
}

validate_domain_dns() {
    local resolved confirm=""
    resolved="$(resolve_domain_a_records "$DOMAIN" | head -n1 || true)"
    if [[ -z "$resolved" ]]; then
        err "域名 $DOMAIN 无法解析。请先添加 A 记录指向本机（Cloudflare 须使用仅 DNS/灰云）。"
        return 1
    fi
    if ! domain_resolves_to_public_ip "$DOMAIN" "$PUBLIC_IP"; then
        warn "域名解析到 $resolved，与本机 $PUBLIC_IP 不一致。"
        warn "若使用 Cloudflare，请确认已关闭橙云代理。"
        if [[ -t 0 ]]; then
            read -r -p "仍要继续？[y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || { warn "已取消使用该域名。"; return 1; }
        fi
    else
        ok "域名 $DOMAIN -> $PUBLIC_IP"
    fi
}

install_cert() {
    local certbot_cmd cert_live_dir
    ensure_mosdns_user
    CERTBOT_LAST_OUTPUT=""
    install_certbot_firewall_hooks
    cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos -n --keep-until-expiring -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/simcard-dns-open-cert-http.sh \
        --post-hook /usr/local/bin/simcard-dns-restore-firewall.sh)
    local cb_cmd=("${certbot_cmd[@]}")
    if [[ -s "${cert_live_dir}/fullchain.pem" && -s "${cert_live_dir}/privkey.pem" ]]; then
        info "已存在证书，跳过签发。"
    else
        info "申请 Let's Encrypt 证书 for $DOMAIN..."
        run_certbot() {
            prepare_certbot_standalone || return 1
            trap cleanup_certbot_standalone RETURN
            local out rc
            if out="$("${cb_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
            CERTBOT_LAST_OUTPUT="$out"
            [[ -z "${INSTALL_LOG:-}" ]] || printf '%s\n' "$out" >> "$INSTALL_LOG"
            if [[ $rc -eq 0 ]]; then
                return 0
            fi
            if grep -q "AttributeError" <<<"$out"; then
                warn "Certbot Python dependency mismatch. Repair certbot using your OS package manager or a dedicated isolated environment; no root pip upgrade was attempted."
            fi
            return 1
        }
        if ! run_certbot; then
            err "证书申请失败。请检查:"
            err "  1. 域名 $DOMAIN 是否正确解析到本机 ($PUBLIC_IP)"
            err "  2. 端口 80 是否被占用"
            err "  3. 防火墙是否放行 80"
            err "  4. 是否触发了 Let's Encrypt 速率限制 (同一域名 7 天内限 5 次)"
            if [[ -n "${CERTBOT_LAST_OUTPUT:-}" ]]; then
                err "certbot 最后输出:"
                printf '%s\n' "$CERTBOT_LAST_OUTPUT" | tail -n 30 >&2
            fi
            exit 1
        fi
    fi
    info "Copying certificates to /etc/mosdns/certs/ ..."
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/mosdns/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/mosdns/certs/privkey.pem
        chown -R mosdns:mosdns /etc/mosdns/certs/
        chmod 600 /etc/mosdns/certs/*.pem
        ok "Certificates copied to /etc/mosdns/certs/"
    else
        warn "Could not find certificate live directory: $cert_live_dir"
    fi
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    if [[ -f "${LIB_DIR}/renew-hook.sh" ]]; then
        cp "${LIB_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        ok "证书已就绪，自动续期 Hook 已部署"
    else
        warn "renew-hook.sh not found in ${LIB_DIR}; keeping existing renewal hook"
        ok "证书已就绪"
    fi
}

prepare_certbot_standalone() {
    CERT_STOPPED_SNIPROXY=0
    CERT_STOPPED_WA_SHIM=0
    if systemctl is-active --quiet wa-shim 2>/dev/null; then
        info "Stopping wa-shim temporarily during certificate maintenance..."
        systemctl stop wa-shim || { warn "Could not stop wa-shim for certbot"; return 1; }
        CERT_STOPPED_WA_SHIM=1
    fi
    if systemctl is-active --quiet sniproxy 2>/dev/null; then
        info "Stopping sniproxy temporarily so certbot can bind TCP/80..."
        systemctl stop sniproxy || { warn "Could not stop sniproxy for certbot"; cleanup_certbot_standalone; return 1; }
        CERT_STOPPED_SNIPROXY=1
    fi
    if ! open_cert_http_port; then
        warn "TCP/80 preparation failed; aborting certbot and restoring services."
        cleanup_certbot_standalone
        return 1
    fi
}

cleanup_certbot_standalone() {
    local rc=$?
    restore_reverse_proxy_firewall
    if [[ "${CERT_STOPPED_SNIPROXY:-0}" == "1" ]]; then
        info "Starting sniproxy after certbot..."
        systemctl start sniproxy || warn "sniproxy failed to restart after certbot; run: systemctl status sniproxy"
    fi
    if [[ "${CERT_STOPPED_WA_SHIM:-0}" == "1" ]]; then
        systemctl start wa-shim || warn "wa-shim failed to restart after certbot"
    fi
    return $rc
}

install_certbot_firewall_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
    cat > /usr/local/bin/simcard-dns-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
systemctl stop sniproxy 2>/dev/null || true
systemctl stop wa-shim 2>/dev/null || true
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    nft insert rule inet filter input tcp dport 80 accept comment '"simcard-dns-cert-http"' 2>/dev/null || { echo "Failed to open TCP/80 for certbot" >&2; /usr/local/bin/simcard-dns-restore-firewall.sh; exit 1; }
elif command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport 80 -m comment --comment simcard-dns-cert-http -j ACCEPT 2>/dev/null || { echo "Failed to open TCP/80 for certbot" >&2; /usr/local/bin/simcard-dns-restore-firewall.sh; exit 1; }
fi
EOF
    cat > /usr/local/bin/simcard-dns-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
# Delete only the tagged temporary rule. Reloading /etc/nftables.conf here
# would be wrong when the firewall is user-managed (FIREWALL_MODE=preserve).
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
    while h="$(nft --handle list chain inet filter input 2>/dev/null | awk '/simcard-dns-cert-http/ { print $NF; exit }')" && [ -n "$h" ]; do
        nft delete rule inet filter input handle "$h" 2>/dev/null || break
    done
fi
if command -v iptables >/dev/null 2>&1; then
    while iptables -D INPUT -p tcp --dport 80 -m comment --comment simcard-dns-cert-http -j ACCEPT 2>/dev/null; do :; done
fi
systemctl start sniproxy 2>/dev/null || true
systemctl start wa-shim 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/simcard-dns-open-cert-http.sh /usr/local/bin/simcard-dns-restore-firewall.sh
    cp /usr/local/bin/simcard-dns-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh
    cp /usr/local/bin/simcard-dns-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh
}

force_renew_cert() {
    ensure_mosdns_user
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot renew."
        exit 1
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        err "certbot 不存在，无法签发/续期证书。请重新运行安装脚本安装依赖。"
        exit 1
    fi
    # Wildcard (Cloudflare) mode: renew through DNS-01 using the saved
    # renewal settings; no TCP/80 or service interruption is involved.
    local lineage
    lineage="$(cat "${CONF_DIR}/.cert_lineage" 2>/dev/null || true)"
    if [[ -n "$lineage" && -d "${LE_LIVE_DIR}/${lineage}" ]]; then
        local wout wrc=0
        wout="$(certbot renew --cert-name "$lineage" --force-renewal -n 2>&1)" || wrc=$?
        printf '%s\n' "$wout"
        if (( wrc != 0 )); then
            err "通配符证书续期失败。certbot 最后输出:"
            printf '%s\n' "$wout" | tail -n 30 >&2
            return "$wrc"
        fi
        # The deploy hook copied the new files and restarted mosdns.
        ok "Wildcard certificate renewed"
        return 0
    fi
    get_public_ip
    certbot_diagnostics "$DOMAIN"
    local certbot_cmd=()
    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
            --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
            --pre-hook /usr/local/bin/simcard-dns-open-cert-http.sh \
            --post-hook /usr/local/bin/simcard-dns-restore-firewall.sh)
    else
        certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
            --pre-hook /usr/local/bin/simcard-dns-open-cert-http.sh \
            --post-hook /usr/local/bin/simcard-dns-restore-firewall.sh)
    fi
    prepare_certbot_standalone || return 1
    trap cleanup_certbot_standalone RETURN
    local out rc
    if out="$("${certbot_cmd[@]}" 2>&1)"; then rc=0; else rc=$?; fi
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]]; then
        if grep -q "AttributeError" <<<"$out"; then
            warn "Certbot Python dependency mismatch. Repair with OS packages or a dedicated isolated environment; no root pip upgrade was attempted."
        fi
        err "证书续期/签发失败。certbot 最后输出:"
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" | tail -n 30 >&2
        else
            err "certbot 没有输出；请检查 TCP/80 是否可达、端口监听和 DNS。"
        fi
        cleanup_certbot_standalone
        trap - RETURN
        return "$rc"
    fi
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        mkdir -p /etc/mosdns/certs
        cp "${cert_live_dir}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
        cp "${cert_live_dir}/privkey.pem" /etc/mosdns/certs/privkey.pem
        chown -R mosdns:mosdns /etc/mosdns/certs/
        chmod 600 /etc/mosdns/certs/*.pem
    fi
    if systemctl is-active --quiet mosdns; then
        systemctl restart mosdns && ok "Certificate renewed and mosdns reloaded"
    else
        systemctl start mosdns && ok "Certificate renewed and mosdns started"
    fi
}

# ---- Cloudflare: wildcard certificate + one-click domain reset -------------
# With a Cloudflare API token (Zone.DNS edit) the DoT name becomes a random
# <label>.dns.<zone> covered by one wildcard certificate "*.dns.<zone>":
# resetting the name needs no new certificate, never publishes the name in
# Certificate Transparency logs, and the old name dies with its A record.
CF_CREDENTIALS="${PGW_CF_CREDENTIALS:-/etc/simcard-dns/cloudflare.ini}"
CF_CONF="${PGW_CF_CONF:-/etc/simcard-dns/cloudflare.conf}"
CF_DOT_LABEL="dns"
MOSDNS_DIR="${PGW_MOSDNS_DIR:-/etc/mosdns}"
LE_LIVE_DIR="${PGW_LE_LIVE:-/etc/letsencrypt/live}"
CF_CERT_NAME="simcard-dns-wildcard"
# Hosts migrated from 5GPN-X keep renewing their existing wildcard lineage
# instead of issuing a second certificate.
if [[ -d "${LE_LIVE_DIR}/5gpn-wildcard" && ! -d "${LE_LIVE_DIR}/${CF_CERT_NAME}" ]]; then
    CF_CERT_NAME="5gpn-wildcard"
fi
LE_DEPLOY_HOOK_DIR="${PGW_LE_DEPLOY_HOOKS:-/etc/letsencrypt/renewal-hooks/deploy}"

# cf_api METHOD PATH [JSON] -> prints the "result" member as JSON.
cf_api() {
    python3 - "$CF_CREDENTIALS" "$@" <<'PY'
import json, os, sys, urllib.error, urllib.request
cred, method, path = sys.argv[1:4]
body = sys.argv[4] if len(sys.argv) > 4 else None
token = ""
try:
    for line in open(cred, encoding="utf-8"):
        key, sep, value = line.partition("=")
        if sep and key.strip() == "dns_cloudflare_api_token":
            token = value.strip()
except OSError:
    pass
if not token:
    sys.exit("Cloudflare API token missing: " + cred)
base = os.environ.get("PGW_CF_API", "https://api.cloudflare.com/client/v4")
req = urllib.request.Request(base + path, method=method,
                             data=body.encode() if body else None,
                             headers={"Authorization": "Bearer " + token,
                                      "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
except urllib.error.HTTPError as exc:
    try:
        data = json.load(exc)
    except Exception:
        sys.exit("Cloudflare API %s %s failed: HTTP %d" % (method, path, exc.code))
except Exception as exc:
    sys.exit("Cloudflare API %s %s failed: %s" % (method, path, exc))
if not data.get("success"):
    errors = "; ".join(e.get("message", "") for e in data.get("errors") or []) or "unknown error"
    sys.exit("Cloudflare API %s %s failed: %s" % (method, path, errors))
print(json.dumps(data.get("result")))
PY
}

cf_conf() { # key -> value from CF_CONF
    sed -n "s/^${1}=//p" "$CF_CONF" 2>/dev/null | head -n1
}

cf_configured() {
    [[ -s "$CF_CREDENTIALS" && -n "$(cf_conf zone_id)" && -n "$(cf_conf zone)" ]]
}

cf_json() { # python expression over parsed stdin "r" -> printed result
    python3 -c 'import json,sys; r=json.load(sys.stdin); v='"$1"'; print("\n".join(v) if isinstance(v, list) else v)'
}

issue_wildcard_cert() {
    local zone out rc=0
    zone="$(cf_conf zone)"
    [[ -n "$zone" ]] || { err "Cloudflare zone not configured"; return 1; }
    info "Issuing wildcard certificate *.${CF_DOT_LABEL}.${zone} via Cloudflare DNS-01..."
    out="$(certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 30 -d "*.${CF_DOT_LABEL}.${zone}" \
        --cert-name "$CF_CERT_NAME" --agree-tos -n --keep-until-expiring \
        -m "${EMAIL:-admin@${zone}}" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        err "Wildcard certificate request failed. certbot output:"
        printf '%s\n' "$out" | tail -n 20 >&2
        return 1
    fi
    mkdir -p "$LE_DEPLOY_HOOK_DIR"
    if [[ -f "${LIB_DIR}/renew-hook.sh" ]]; then
        install -m 0755 "${LIB_DIR}/renew-hook.sh" "${LE_DEPLOY_HOOK_DIR}/99-reload-mosdns.sh" || return 1
    fi
    ok "Wildcard certificate ready: *.${CF_DOT_LABEL}.${zone}"
}

# Connect a Cloudflare API token (Zone -> DNS -> Edit on the DoT zone). The
# token is read from CF_API_TOKEN or typed without echo; never pass it as an
# argument (it would land in shell history and process listings).
setup_cloudflare() {
    local zone_arg="${1:-}" token="${CF_API_TOKEN:-}" tmp domain candidate zone="" zone_id="" candidates=()
    command -v certbot >/dev/null 2>&1 || { err "certbot is required"; exit 1; }
    python3 -c 'import certbot_dns_cloudflare' 2>/dev/null \
        || { err "certbot Cloudflare plugin missing (install python3-certbot-dns-cloudflare)"; exit 1; }
    if [[ -z "$token" ]]; then
        [[ -t 0 ]] || { err "Set CF_API_TOKEN or run interactively"; exit 1; }
        read -rsp "Cloudflare API Token（输入时不显示）: " token; echo
    fi
    [[ -n "$token" && "$token" != *[[:space:]]* ]] || { err "Invalid token"; exit 1; }
    mkdir -p "$(dirname "$CF_CREDENTIALS")"
    tmp="$(mktemp "${CF_CREDENTIALS}.XXXXXX")" || exit 1
    chmod 600 "$tmp"
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$tmp"
    if [[ -n "$zone_arg" ]]; then
        candidates=("$zone_arg")
    else
        domain="$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)"
        while [[ "$domain" == *.*.* ]]; do candidates+=("$domain"); domain="${domain#*.}"; done
        [[ -n "$domain" ]] && candidates+=("$domain")
    fi
    for candidate in "${candidates[@]}"; do
        zone_id="$(CF_CREDENTIALS="$tmp" cf_api GET "/zones?name=${candidate}" | cf_json 'r[0]["id"] if r else ""')" \
            || { rm -f "$tmp"; err "Cloudflare token rejected"; exit 1; }
        if [[ -n "$zone_id" ]]; then zone="$candidate"; break; fi
    done
    [[ -n "$zone" ]] || { rm -f "$tmp"; err "No Cloudflare zone found for: ${candidates[*]:-current domain} (pass the zone name)"; exit 1; }
    CF_CREDENTIALS="$tmp" cf_api GET "/zones/${zone_id}/dns_records?per_page=1" >/dev/null \
        || { rm -f "$tmp"; err "Token cannot read DNS records of ${zone}"; exit 1; }
    mv -f "$tmp" "$CF_CREDENTIALS"
    printf 'zone=%s\nzone_id=%s\n' "$zone" "$zone_id" > "$CF_CONF"
    chmod 600 "$CF_CONF"
    ok "Cloudflare connected: zone ${zone}"
    issue_wildcard_cert || exit 1
}

# Point the running DoT service at NEW (covered by the wildcard lineage).
# Rolls back domain files and certificates if mosdns cannot be reloaded.
apply_wildcard_dot_domain() {
    local new="$1" live="${LE_LIVE_DIR}/${CF_CERT_NAME}" backup f
    [[ -s "${live}/fullchain.pem" && -s "${live}/privkey.pem" ]] || { err "Wildcard certificate missing: $live"; return 1; }
    backup="$(mktemp -d)"
    for f in "${CONF_DIR}/.domain" "${MOSDNS_DIR}/.domain" "${CONF_DIR}/.cert_lineage" "${CONF_DIR}/.cert_basename" \
             "${MOSDNS_DIR}/certs/fullchain.pem" "${MOSDNS_DIR}/certs/privkey.pem"; do
        [[ -f "$f" ]] && cp -a "$f" "${backup}/${f//\//__}"
    done
    restore_wildcard_switch() {
        for f in "${CONF_DIR}/.domain" "${MOSDNS_DIR}/.domain" "${CONF_DIR}/.cert_lineage" "${CONF_DIR}/.cert_basename" \
                 "${MOSDNS_DIR}/certs/fullchain.pem" "${MOSDNS_DIR}/certs/privkey.pem"; do
            if [[ -f "${backup}/${f//\//__}" ]]; then cp -a "${backup}/${f//\//__}" "$f"; else rm -f "$f"; fi
        done
    }
    mkdir -p "${MOSDNS_DIR}/certs" "$CONF_DIR"
    cp "${live}/fullchain.pem" "${MOSDNS_DIR}/certs/fullchain.pem"
    cp "${live}/privkey.pem" "${MOSDNS_DIR}/certs/privkey.pem"
    chown -R mosdns:mosdns "${MOSDNS_DIR}/certs/" 2>/dev/null || true
    chmod 600 "${MOSDNS_DIR}"/certs/*.pem
    echo "$new" > "${CONF_DIR}/.domain"
    echo "$new" > "${MOSDNS_DIR}/.domain"
    echo "$CF_CERT_NAME" > "${CONF_DIR}/.cert_lineage"
    rm -f "${CONF_DIR}/.cert_basename"
    local updater="${PGW_RULES_UPDATER:-/usr/local/bin/update-mosdns-rules.sh}"
    if [[ -x "$updater" ]]; then
        if ! "$updater" --offline >/dev/null; then
            restore_wildcard_switch; "$updater" --offline >/dev/null 2>&1 || true; rm -rf "$backup"
            err "mosdns reload failed; DoT domain rolled back"
            return 1
        fi
    elif ! systemctl restart mosdns; then
        restore_wildcard_switch; rm -rf "$backup"
        err "mosdns restart failed; DoT domain rolled back"
        return 1
    fi
    rm -rf "$backup"
    regenerate_ios_profile >/dev/null || warn "iOS profile regeneration failed"
}

# One click: random <label>.dns.<zone>, A record, switch, delete the old record.
reset_dot_domain() {
    routing_lock
    cf_configured || { err "Cloudflare not connected; run: $0 --setup-cloudflare"; exit 1; }
    local zone zone_id label new old ip new_id id waited=0
    zone="$(cf_conf zone)"; zone_id="$(cf_conf zone_id)"
    if [[ ! -s "${LE_LIVE_DIR}/${CF_CERT_NAME}/fullchain.pem" ]]; then
        issue_wildcard_cert || exit 1
    fi
    label="$(python3 -c 'import secrets,string; a=string.ascii_lowercase+string.digits; print("".join(secrets.choice(a) for _ in range(20)))')"
    new="${label}.${CF_DOT_LABEL}.${zone}"
    ip="$(cat "${MOSDNS_DIR}/.public_ip" 2>/dev/null || true)"
    [[ -n "$ip" ]] || { get_public_ip; ip="$PUBLIC_IP"; }
    old="$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)"
    new_id="$(cf_api POST "/zones/${zone_id}/dns_records" \
        "{\"type\":\"A\",\"name\":\"${new}\",\"content\":\"${ip}\",\"ttl\":60,\"proxied\":false,\"comment\":\"simcard-dns-x DoT\"}" \
        | cf_json 'r["id"]')" || { err "Could not create the DNS record"; exit 1; }
    info "A record created: ${new} -> ${ip}; waiting until it resolves..."
    until domain_resolves_to_public_ip "$new" "$ip"; do
        (( waited >= 90 )) && break
        sleep 5; waited=$((waited + 5))
    done
    if ! domain_resolves_to_public_ip "$new" "$ip"; then
        cf_api DELETE "/zones/${zone_id}/dns_records/${new_id}" >/dev/null || true
        err "${new} did not resolve within 90s; nothing was changed"
        exit 1
    fi
    if ! apply_wildcard_dot_domain "$new"; then
        cf_api DELETE "/zones/${zone_id}/dns_records/${new_id}" >/dev/null || true
        exit 1
    fi
    # Retire the previous name: only A records of that exact name that point
    # at this server are deleted, so unrelated records are never touched.
    if [[ -n "$old" && "$old" != "$new" && "$old" == *".${zone}" ]]; then
        for id in $(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${old}" \
                    | cf_json "[x['id'] for x in r if x.get('content') == '${ip}']" 2>/dev/null); do
            cf_api DELETE "/zones/${zone_id}/dns_records/${id}" >/dev/null \
                || warn "Could not delete the old DNS record of ${old}"
        done
    fi
    ok "DoT domain reset: ${new}"
    printf 'NEW_DOMAIN=%s\n' "$new"
}
