#!/usr/bin/env bash
# simcard-dns module: uninstall
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

uninstall_ask() { # question -> 0 when the answer is y
    local reply=""
    read -r -p "$1 [y/N]: " reply || true
    [[ "$reply" =~ ^[Yy]$ ]]
}
# Let's Encrypt lineages this project issued: the wildcard lineage, and any
# certificate whose renewal uses our firewall hooks or Cloudflare token.
uninstall_project_certs() {
    local f name
    for f in /etc/letsencrypt/renewal/*.conf; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .conf)"
        if [[ "$name" == simcard-dns-wildcard || "$name" == 5gpn-wildcard ]] \
            || grep -qE 'simcard-dns-open-cert-http|5gpn-open-cert-http|simcard-dns/cloudflare\.ini|5gpn/cloudflare\.ini' "$f"; then
            printf '%s\n' "$name"
        fi
    done
}
# Drop the nofile block system_tuning appended (marker + its own lines only).
uninstall_limits_block() {
    local conf=/etc/security/limits.conf tmp
    grep -q '^# simcard-dns-limits$' "$conf" 2>/dev/null || return 0
    tmp="$(mktemp)" || return 0
    awk '
        /^# simcard-dns-limits$/ { skip = 4; next }
        skip > 0 && /^(\*|root) (soft|hard) nofile 1048576$/ { skip--; next }
        { skip = 0; print }
    ' "$conf" > "$tmp" && cat "$tmp" > "$conf"
    rm -f "$tmp"
}
do_uninstall() {
    warn "This will remove simcard-dns completely: services, programs, configuration, state, logs and source."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }

    # Ask about the optional items first, then remove everything in one go.
    local -a certs=()
    local c del_certs=0 del_backups=0 del_go=0
    local src="${PGW_SRC_DIR:-/opt/simcard-dns-source}" backups=/var/backups/simcard-dns
    while IFS= read -r c; do [[ -n "$c" ]] && certs+=("$c"); done < <(uninstall_project_certs)
    if ((${#certs[@]})); then
        info "Let's Encrypt certificates issued for simcard-dns: ${certs[*]}"
        uninstall_ask "删除这些证书？（保留的话之后自动续期会失败）" && del_certs=1
    fi
    if [[ -d "$backups" ]]; then
        uninstall_ask "删除备份 ${backups}？（含旧配置、出口节点与令牌）" && del_backups=1
    fi
    if [[ -d /usr/local/go ]]; then
        uninstall_ask "删除 Go 编译器 /usr/local/go？（其他程序若也在用请保留）" && del_go=1
    fi

    # DoT DNS records this project created for this server on Cloudflare
    # (needs the token, so before /etc/simcard-dns is removed).
    if declare -F cf_configured >/dev/null && cf_configured; then
        local dot_ip
        dot_ip="$(cat /etc/mosdns/.public_ip 2>/dev/null || true)"
        if [[ -n "$dot_ip" ]]; then
            cf_retire_dot_records "" "$dot_ip" || warn "Remove the DoT A records of ${dot_ip} in the Cloudflare dashboard"
        fi
    fi
    set_exit local 2>/dev/null || true
    # Older versions stacked one copy per apply; remove them all.
    while ip rule del fwmark "${EXIT_MARK}" table "${EXIT_TABLE}" 2>/dev/null; do :; done
    ip route flush table "${EXIT_TABLE}" 2>/dev/null || true
    shopt -s nullglob
    for f in "${WG_DIR}"/pgw-*.conf; do
        wg-quick down "$(basename "$f" .conf)" 2>/dev/null || true
    done
    for f in "${EXITS_DIR}"/*.type; do
        systemctl stop "$(exit_mihomo_unit "$(basename "$f" .type)")" 2>/dev/null || true
        systemctl stop "simcard-dns-singbox@$(basename "$f" .type).service" 2>/dev/null || true
    done
    shopt -u nullglob
    systemctl stop mosdns dot-gate dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy simcard-dns-ios-profile.socket simcard-dns-ios-profile simcard-dns-exit simcard-dns-geo-update.timer simcard-dns-dot-check.timer update-mosdns-rules.timer simcard-dns-tgbot 2>/dev/null || true
    systemctl disable mosdns dot-gate dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy simcard-dns-ios-profile.socket simcard-dns-ios-profile simcard-dns-exit simcard-dns-geo-update.timer simcard-dns-dot-check.timer update-mosdns-rules.timer simcard-dns-tgbot 2>/dev/null || true
    # rm -r: the glob also matches drop-in dirs such as mosdns.service.d.
    rm -rf /etc/systemd/system/{mosdns,dot-gate,sniproxy,wa-shim,quic-proxy,china-dns-race-proxy,simcard-dns-ios-profile,update-mosdns-rules,simcard-dns-exit,simcard-dns-geo-update,simcard-dns-dot-check,simcard-dns-tgbot}.*
    rm -f /etc/systemd/system/simcard-dns-ios-profile@.service \
        /etc/systemd/system/simcard-dns-mihomo@.service \
        /etc/systemd/system/simcard-dns-singbox@.service
    rm -rf /etc/systemd/system/quic-proxy.service.d /etc/systemd/system/mosdns.service.d \
        /etc/systemd/system/dnsdist.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    # Performance tuning unit (only ours if it carries our THP commands).
    local thp=/etc/systemd/system/disable-transparent-huge-pages.service
    if [[ -f "$thp" ]] && grep -q 'transparent_hugepage/enabled' "$thp"; then
        systemctl disable --now disable-transparent-huge-pages.service 2>/dev/null || true
        rm -f "$thp"
    fi
    rm -f /var/lib/systemd/timers/stamp-simcard-dns-*.timer /var/lib/systemd/timers/stamp-update-mosdns-rules.timer
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/mosdns /etc/dnsdist /usr/local/bin/update-mosdns-rules.sh
    rm -f /usr/local/bin/update-dnsdist-rules.sh /usr/local/bin/mosdns
    rm -f /usr/local/sbin/sniproxy
    rm -f /usr/local/bin/simcard-dns-apply-exit.sh /usr/local/bin/simcard-dns \
        /usr/local/bin/simcard-dns-open-cert-http.sh /usr/local/bin/simcard-dns-restore-firewall.sh
    rm -f "${WG_DIR}"/pgw-*.conf
    # Repair the host firewall BEFORE removing /etc/simcard-dns, otherwise a
    # managed /etc/nftables.conf would keep a dangling include and fail to load
    # on reboot (leaving the host with no firewall). Also clears auto-mode
    # persistence and the managed marker.
    firewall_cleanup_on_uninstall
    rm -rf /etc/simcard-dns
    # Certificate hooks (renewal of any kept certificate no longer opens TCP/80).
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh \
        /etc/letsencrypt/renewal-hooks/pre/10-simcard-dns-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-simcard-dns-restore-firewall.sh
    # State, logs, source checkout (and the bootstrap's staging/backup copies).
    rm -rf /var/lib/simcard-dns /var/lib/simcard-dns-quic
    rm -f /var/log/simcard-dns-install.log /run/lock/simcard-dns-routing.lock
    rm -rf "${src:?}" "${src:?}".staging.* "${src:?}".backup-*
    # Leftovers of the old 5GPN-X name: its source tree, and a bare /opt/5gpn
    # (a real, unmigrated old install is left alone).
    rm -rf /opt/5gpn-source
    if [[ -d /opt/5gpn && ! -f /opt/5gpn/bin/5gpn-ctl && ! -s /opt/5gpn/etc/.domain ]]; then
        rm -rf /opt/5gpn
    fi
    # System settings written by system_tuning.
    rm -f /etc/sysctl.d/99-simcard-dns.conf /etc/modules-load.d/simcard-dns-net.conf
    if grep -q '^# disabled by simcard-dns ' /etc/sysctl.conf 2>/dev/null; then
        local sysctl_tmp
        sysctl_tmp="$(mktemp)" && sed 's/^# disabled by simcard-dns (see 99-simcard-dns.conf): //' /etc/sysctl.conf > "$sysctl_tmp" \
            && cat "$sysctl_tmp" > /etc/sysctl.conf
        rm -f "$sysctl_tmp"
    fi
    uninstall_limits_block
    if [[ -f /etc/systemd/journald.conf.d/99-simcard-dns.conf ]]; then
        rm -f /etc/systemd/journald.conf.d/99-simcard-dns.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi
    if [[ -f /etc/nftables.conf.pgw-backup ]]; then
        warn "Pre-install firewall backup kept at /etc/nftables.conf.pgw-backup (restore manually if wanted)."
    fi
    userdel "${EXIT_USER}" 2>/dev/null || true
    userdel mosdns 2>/dev/null || true

    # Optional items, as answered above.
    if ((${#certs[@]})); then
        if ((del_certs)); then
            for c in "${certs[@]}"; do
                certbot delete --cert-name "$c" --non-interactive >/dev/null 2>&1 \
                    || warn "Could not delete certificate ${c}; remove it with: certbot delete --cert-name ${c}"
            done
        else
            warn "Certificates kept (${certs[*]}). Their renewal will fail; remove with: certbot delete --cert-name <name>"
        fi
    fi
    if ((del_backups)); then rm -rf "$backups"; elif [[ -d "$backups" ]]; then warn "Backups kept at ${backups}"; fi
    if ((del_go)); then
        rm -rf /usr/local/go
        rm -f /etc/profile.d/go.sh
    elif [[ -d /usr/local/go ]]; then
        warn "Go kept at /usr/local/go"
    fi
    if [[ -e /swapfile ]]; then
        warn "Swapfile /swapfile is kept. To remove: swapoff /swapfile && rm -f /swapfile && sed -i '/^\\/swapfile /d' /etc/fstab"
    fi
    info "Kernel settings applied at runtime (for example ip_forward) return to defaults after a reboot."
    ok "Uninstall completed"
}
