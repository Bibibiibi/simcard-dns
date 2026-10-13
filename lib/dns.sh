#!/usr/bin/env bash
# 5GPN-X module: dns
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

render_sniproxy_dns_nameservers() {
    local input="${1:-}"
    local dns_list=()
    local item
    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_REMOTE_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" == *://* ]]; then
            item=$(python3 - "$item" <<'PYEOF'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PYEOF
)
        elif [[ "$item" == \[*\]:* ]]; then
            item="${item#\[}"
            item="${item%%\]:*}"
        elif [[ "$item" =~ ^([0-9]+\.){3}[0-9]+:[0-9]+$ ]]; then
            item="${item%:*}"
        fi
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid sniproxy DNS address: $item"
            continue
        fi
        printf '    nameserver %s\n' "$item"
    done
}

first_plain_dns() {
    local rendered
    rendered=$(render_sniproxy_dns_nameservers "${1:-}")
    awk 'NR == 1 { print $2 }' <<< "$rendered"
}

normalize_dns_list() {
    local input="${1:-}"
    local dns_list=() out=() item
    input="${input//,/ }"
    read -r -a dns_list <<< "$input"
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            err "Invalid DNS address: $item"
            exit 1
        fi
        python3 - "$item" <<'PYEOF' || { err "Invalid DNS address: $item"; exit 1; }
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PYEOF
        out+=("$item")
    done
    [[ ${#out[@]} -gt 0 ]] || { err "DNS list cannot be empty"; exit 1; }
    printf '%s' "${out[*]}"
}

normalize_dns_upstreams() {
    local input="${1:-}"
    local dns_list=() out=() item host port
    input="${input//,/ }"
    read -r -a dns_list <<< "$input"
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ "$item" == *://* ]]; then
            err "Encrypted or scheme DNS upstreams are unsupported by all consumers; use an IP address or IP:53: $item"
            exit 1
        fi
        if [[ "$item" == *:* ]]; then
            if python3 - "$item" <<'PYEOF' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PYEOF
            then
                host="$item"
                port="53"
            else
                host="${item%:*}"
                port="${item##*:}"
            fi
        else
            host="$item"
            port="53"
        fi
        [[ "$port" =~ ^[0-9]+$ && "$port" -eq 53 ]] || { err "DNS upstream custom ports are unsupported by sniproxy/quic-proxy; use IP or IP:53: $item"; exit 1; }
        python3 - "$host" <<'PYEOF' || { err "Invalid DNS upstream IP: $item"; exit 1; }
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1])
PYEOF
        if [[ "$port" == "53" ]]; then
            out+=("$host")
        else
            out+=("$host:$port")
        fi
    done
    [[ ${#out[@]} -gt 0 ]] || { err "DNS upstream list cannot be empty"; exit 1; }
    printf '%s' "${out[*]}"
}

rewrite_sniproxy_dns() {
    local sniproxy_dns="${1:-}" nameservers
    [[ -f /etc/sniproxy.conf ]] || return 0
    nameservers=$(render_sniproxy_dns_nameservers "$sniproxy_dns")
    python3 - /etc/sniproxy.conf "$nameservers" <<'PYEOF'
import sys

path, nameservers = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

start = None
end = None
for idx, line in enumerate(lines):
    if line.strip() == "resolver {":
        start = idx
        break
if start is not None:
    for idx in range(start + 1, len(lines)):
        if lines[idx].strip() == "}":
            end = idx
            break
if start is None or end is None:
    raise SystemExit("resolver block not found in /etc/sniproxy.conf")

replacement = ["resolver {"] + nameservers.splitlines() + ["    mode ipv4_only", "}"]
new_lines = lines[:start] + replacement + lines[end + 1:]
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(new_lines) + "\n")
PYEOF
}

configure_dns_upstreams() {
    local remote_selected="${REMOTE_DNS:-${DNS_UPSTREAMS:-${OVERSEAS_DNS:-${PRIVATE_OVERSEAS_DNS:-${SNIPROXY_DNS:-}}}}}"
    local local_selected="${LOCAL_DNS:-}"
    local mosdns_dir="${MOSDNS_DIR:-/etc/mosdns}"
    if [[ -z "$remote_selected" ]]; then
        remote_selected=$(cat "${mosdns_dir}/.remote_dns" 2>/dev/null || cat /etc/dnsdist/.remote_dns 2>/dev/null || true)
    fi
    if [[ -z "$local_selected" ]]; then
        local_selected=$(cat "${mosdns_dir}/.local_dns" 2>/dev/null || cat /etc/dnsdist/.local_dns 2>/dev/null || true)
    fi
    if [[ -z "$remote_selected" && -t 0 && "${PROMPT_DNS:-0}" == "1" ]]; then
        read -r -p "国际 DNS remote [1.1.1.1,8.8.8.8,9.9.9.9]: " remote_selected
    fi
    if [[ -z "$local_selected" && -t 0 && "${PROMPT_DNS:-0}" == "1" ]]; then
        read -r -p "国内 DNS local [101.226.4.6,218.30.118.6,180.76.76.76,119.29.29.29]: " local_selected
    fi
    [[ -n "$remote_selected" ]] || remote_selected="${DEFAULT_REMOTE_DNS[*]}"
    [[ -n "$local_selected" ]] || local_selected="${DEFAULT_LOCAL_DNS[*]}"
    REMOTE_DNS=$(normalize_dns_upstreams "$remote_selected")
    LOCAL_DNS=$(normalize_dns_upstreams "$local_selected")
    mkdir -p "$CONF_DIR"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.remote_dns"
    echo "$LOCAL_DNS" > "${CONF_DIR}/.local_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_private_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.overseas_public_dns"
    echo "$REMOTE_DNS" > "${CONF_DIR}/.sniproxy_dns"
    if [[ -n "${INSTALL_LOG:-}" ]]; then
        info "DNS: remote=$REMOTE_DNS local=$LOCAL_DNS" >> "$INSTALL_LOG"
    else
        info "DNS: remote=$REMOTE_DNS local=$LOCAL_DNS"
    fi
}

configure_overseas_dns() { configure_dns_upstreams; }

write_quic_dns_file() {
    local value="${1:-}"
    [[ -n "$value" ]] || return 1
    local dir=/var/lib/5gpn-quic path=/var/lib/5gpn-quic/remote-dns tmp
    # Keep the non-secret resolver snapshot in a dedicated readable directory;
    # do not relax /etc/5gpn permissions, which also contains exit credentials.
    install -d -o root -g root -m 0755 "$dir" || return 1
    path="$dir/remote-dns"
    tmp="$(mktemp "$dir/.remote-dns.XXXXXX")" || return 1
    printf '%s\n' "$value" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path"
}

set_custom_dns() {
    routing_lock
    local remote_dns local_dns backup_dir sniproxy_backup=""
    [[ -n "${1:-}" ]] || { err "Usage: $0 --set-dns <remote-dns> [local-dns]"; exit 1; }
    remote_dns=$(normalize_dns_upstreams "$1")
    local_dns=$(normalize_dns_upstreams "${2:-$(cat /etc/mosdns/.local_dns 2>/dev/null || printf '%s' "${DEFAULT_LOCAL_DNS[*]}")}")
    mkdir -p "$CONF_DIR" /etc/mosdns
    backup_dir=$(mktemp -d)
    for f in \
        "${CONF_DIR}/.remote_dns" \
        "${CONF_DIR}/.local_dns" \
        "${CONF_DIR}/.overseas_dns" \
        "${CONF_DIR}/.overseas_private_dns" \
        "${CONF_DIR}/.overseas_public_dns" \
        "${CONF_DIR}/.sniproxy_dns" \
        "${CONF_DIR}/wa-shim.env" \
        /etc/mosdns/.remote_dns \
        /etc/mosdns/.local_dns \
        /etc/mosdns/.overseas_dns \
        /etc/mosdns/.overseas_private_dns \
        /etc/mosdns/.overseas_public_dns \
        /etc/mosdns/.sniproxy_dns \
            /var/lib/5gpn-quic/remote-dns; do
        [[ -f "$f" ]] && cp -a "$f" "${backup_dir}/${f//\//__}"
    done
    if [[ -f /etc/sniproxy.conf ]]; then
        sniproxy_backup="${backup_dir}/sniproxy.conf"
        cp -a /etc/sniproxy.conf "$sniproxy_backup"
    fi
    restore_dns_backup() {
        local f b
        for f in \
            "${CONF_DIR}/.remote_dns" \
            "${CONF_DIR}/.local_dns" \
            "${CONF_DIR}/.overseas_dns" \
            "${CONF_DIR}/.overseas_private_dns" \
            "${CONF_DIR}/.overseas_public_dns" \
            "${CONF_DIR}/.sniproxy_dns" \
            "${CONF_DIR}/wa-shim.env" \
            /etc/mosdns/.remote_dns \
            /etc/mosdns/.local_dns \
            /etc/mosdns/.overseas_dns \
            /etc/mosdns/.overseas_private_dns \
            /etc/mosdns/.overseas_public_dns \
            /etc/mosdns/.sniproxy_dns \
            /var/lib/5gpn-quic/remote-dns; do
            b="${backup_dir}/${f//\//__}"
            if [[ -f "$b" ]]; then
                cp -a "$b" "$f"
            else
                rm -f "$f"
            fi
        done
        if [[ -n "$sniproxy_backup" && -f "$sniproxy_backup" ]]; then
            cp -a "$sniproxy_backup" /etc/sniproxy.conf
        fi
    }
    # Create the QUIC snapshot before changing any live DNS inputs. A
    # permission or filesystem failure therefore leaves the old transaction
    # untouched and can be reported without partial publication.
    if ! write_quic_dns_file "$remote_dns"; then
        rm -rf "$backup_dir"
        err "Unable to publish QUIC DNS snapshot; DNS upstreams were not changed"
        exit 1
    fi
    echo "$remote_dns" > "${CONF_DIR}/.remote_dns"
    echo "$local_dns" > "${CONF_DIR}/.local_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_private_dns"
    echo "$remote_dns" > "${CONF_DIR}/.overseas_public_dns"
    echo "$remote_dns" > "${CONF_DIR}/.sniproxy_dns"
    echo "$remote_dns" > /etc/mosdns/.remote_dns
    echo "$local_dns" > /etc/mosdns/.local_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_private_dns
    echo "$remote_dns" > /etc/mosdns/.overseas_public_dns
    echo "$remote_dns" > /etc/mosdns/.sniproxy_dns
    if [[ -f "${CONF_DIR}/wa-shim.env" ]]; then
        sed -i -E "s#^WA_SHIM_RESOLVER=.*#WA_SHIM_RESOLVER=$(first_plain_dns "$remote_dns"),8.8.8.8#" "${CONF_DIR}/wa-shim.env"
    fi
    if ! rewrite_sniproxy_dns "$remote_dns"; then
        restore_dns_backup
        rm -rf "$backup_dir"
        err "sniproxy config update failed; DNS upstreams rolled back"
        exit 1
    fi
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_dns_backup
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            rm -rf "$backup_dir"
            err "mosdns config update failed; DNS upstreams rolled back"
            exit 1
        fi
    else
        if ! systemctl restart mosdns; then
            restore_dns_backup
            rm -rf "$backup_dir"
            err "mosdns restart failed; DNS upstreams rolled back"
            exit 1
        fi
    fi
    systemctl restart sniproxy 2>/dev/null || true
    systemctl restart wa-shim 2>/dev/null || true
    rm -rf "$backup_dir"
    ok "DNS upstreams updated"
    echo "Remote DNS: $remote_dns"
    echo "Local DNS: $local_dns"
}

# Change which public source networks are treated as clients: they receive
# the server IP for proxied domains and may reach the reverse proxy.
set_client_cidrs() {
    routing_lock
    local cidrs backup_dir f
    [[ -n "${1:-}" ]] || { err "Usage: $0 --set-client-cidrs \"<cidr> [cidr...]\""; exit 1; }
    cidrs="$(normalize_client_cidrs "$1")" || { err "Client CIDRs not changed"; exit 1; }
    # Every later consumer (wa-shim env, pgw_exit, host firewall) resolves the
    # list through current_client_cidrs; pin it so an exported CLIENT_CIDRS
    # from the install shell cannot override what was just written.
    # shellcheck disable=SC2034 # read by current_client_cidrs in common.sh
    CLIENT_CIDRS="$cidrs"
    local files=("${CLIENT_CIDRS_FILE}" "${CONF_DIR}/wa-shim.env" "${PGW_EXIT_NFT}")
    backup_dir="$(mktemp -d)"
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && cp -a "$f" "${backup_dir}/${f//\//__}"
    done
    # Restore all three inputs and re-apply them so DNS, wa-shim and the
    # egress table agree again on the previous list.
    rollback_client_cidrs() {
        local b
        for f in "${files[@]}"; do
            b="${backup_dir}/${f//\//__}"
            if [[ -f "$b" ]]; then cp -a "$b" "$f"; else rm -f "$f"; fi
        done
        unset CLIENT_CIDRS
        [[ -x /usr/local/bin/update-mosdns-rules.sh ]] && /usr/local/bin/update-mosdns-rules.sh --offline >/dev/null 2>&1
        systemctl restart wa-shim 2>/dev/null || true
        if command -v nft >/dev/null 2>&1 && [[ -f "${PGW_EXIT_NFT}" ]]; then
            nft -f "${PGW_EXIT_NFT}" 2>/dev/null || true
        fi
        rm -rf "$backup_dir"
    }
    mkdir -p "$(dirname "${CLIENT_CIDRS_FILE}")"
    printf '%s\n' "$cidrs" > "${CLIENT_CIDRS_FILE}"
    if [[ -x /usr/local/bin/update-mosdns-rules.sh ]] && ! /usr/local/bin/update-mosdns-rules.sh --offline; then
        rollback_client_cidrs
        err "mosdns config update failed; client CIDRs rolled back"
        exit 1
    fi
    if [[ -f "${CONF_DIR}/wa-shim.env" ]]; then
        sed -i -E "s#^WA_SHIM_ALLOW_CIDR=.*#WA_SHIM_ALLOW_CIDR=${cidrs// /,},127.0.0.0/8#" "${CONF_DIR}/wa-shim.env"
        systemctl restart wa-shim 2>/dev/null || true
    fi
    # Re-applies the egress-marking exclusions and, per FIREWALL_MODE, the
    # reverse-proxy allow rules (preserve only prints what to open).
    if ! setup_firewall; then
        rollback_client_cidrs
        err "Firewall update failed; client CIDRs rolled back (DNS, wa-shim and egress rules restored)"
        exit 1
    fi
    rm -rf "$backup_dir"
    ok "Client CIDRs updated: $cidrs"
    # managed must be requested explicitly on every run; a host that was set
    # up that way still has the OLD list in its INPUT rules unless asked.
    if [[ "$(resolve_firewall_mode 2>/dev/null)" != managed && -f "${PGW_FW_MARK:-/etc/5gpn/.firewall-managed}" ]]; then
        warn "This host's firewall was installed in managed mode; its 80/443 allow rules still use the previous client list."
        warn "Re-run with FIREWALL_MODE=managed to update them: FIREWALL_MODE=managed $0 --set-client-cidrs \"$cidrs\""
    fi
}

set_dot_domain() {
    local new_domain="${1:-}" resolved="" old_conf_domain="" old_mosdns_domain="" old_cert_basename=""
    [[ -n "$new_domain" ]] || { err "Usage: $0 --set-dot-domain <domain>"; exit 1; }
    if ! is_valid_domain "$new_domain"; then
        err "Invalid domain: '$new_domain'. Provide a fully-qualified domain like dns.example.com"
        exit 1
    fi
    get_public_ip
    info "DNS 解析检查"
    info "域名: $new_domain"
    info "需要的 A 记录值: $PUBLIC_IP"
    resolved=$(resolve_domain_a_records "$new_domain" | paste -sd',' - || true)
    if ! domain_resolves_to_public_ip "$new_domain" "$PUBLIC_IP"; then
        err "$new_domain 当前解析到 ${resolved:-无}，不是本机 $PUBLIC_IP"
        err "请先把 A 记录指向本机公网 IP 后重试。"
        exit 1
    fi
    old_conf_domain=$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)
    old_mosdns_domain=$(cat /etc/mosdns/.domain 2>/dev/null || true)
    old_cert_basename=$(cat "${CONF_DIR}/.cert_basename" 2>/dev/null || true)
    DOMAIN="$new_domain"
    install_cert
    mkdir -p "$CONF_DIR" /etc/mosdns
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    echo "$DOMAIN" > /etc/mosdns/.domain
    rm -f "${CONF_DIR}/.cert_basename"
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
            restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
            restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            err "mosdns config update failed; DoT domain rolled back"
            exit 1
        fi
    elif ! systemctl restart mosdns; then
        restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
        restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
        restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
        err "mosdns restart failed; DoT domain rolled back"
        exit 1
    fi
    regenerate_ios_profile || warn "iOS profile regeneration failed"
    ok "DoT domain updated: $DOMAIN"
}

force_set_dot_domain() {
    local new_domain="${1:-}" resolved="" old_conf_domain="" old_mosdns_domain="" old_cert_basename=""
    [[ -n "$new_domain" ]] || { err "Usage: $0 --set-dot-domain-force <domain>"; exit 1; }
    if ! is_valid_domain "$new_domain"; then
        err "Invalid domain: '$new_domain'. Provide a fully-qualified domain like dns.example.com"
        exit 1
    fi
    get_public_ip
    resolved=$(resolve_domain_a_records "$new_domain" | paste -sd',' - || true)
    if ! domain_resolves_to_public_ip "$new_domain" "$PUBLIC_IP"; then
        warn "$new_domain 当前解析到 ${resolved:-无}，不是本机 $PUBLIC_IP；按强制模式继续。"
    fi
    old_conf_domain=$(cat "${CONF_DIR}/.domain" 2>/dev/null || true)
    old_mosdns_domain=$(cat /etc/mosdns/.domain 2>/dev/null || true)
    old_cert_basename=$(cat "${CONF_DIR}/.cert_basename" 2>/dev/null || true)
    DOMAIN="$new_domain"
    mkdir -p "$CONF_DIR" /etc/mosdns
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
    echo "$DOMAIN" > /etc/mosdns/.domain
    rm -f "${CONF_DIR}/.cert_basename"
    if [[ -f /usr/local/bin/update-mosdns-rules.sh ]]; then
        if ! /usr/local/bin/update-mosdns-rules.sh; then
            restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
            restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
            restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
            /usr/local/bin/update-mosdns-rules.sh >/dev/null 2>&1 || true
            err "mosdns config update failed; DoT domain rolled back"
            exit 1
        fi
    elif ! systemctl restart mosdns; then
        restore_or_remove_file "$old_conf_domain" "${CONF_DIR}/.domain"
        restore_or_remove_file "$old_mosdns_domain" /etc/mosdns/.domain
        restore_or_remove_file "$old_cert_basename" "${CONF_DIR}/.cert_basename"
        err "mosdns restart failed; DoT domain rolled back"
        exit 1
    fi
    regenerate_ios_profile || warn "iOS profile regeneration failed"
    warn "DoT domain forcibly updated without issuing a new certificate. Run --renew-cert after fixing certbot/port 80 issues."
    ok "DoT domain forcibly updated: $DOMAIN"
}
