#!/usr/bin/env bash
# simcard-dns module: uninstall
# Extracted verbatim from install.sh (original formatting preserved).
# Sourced by install.sh; not meant to run standalone.
# shellcheck shell=bash

do_uninstall() {
    warn "This will remove sniproxy, quic-proxy, mosdns configs, and rules."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }
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
    systemctl stop mosdns dot-gate dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy simcard-dns-ios-profile.socket simcard-dns-ios-profile simcard-dns-exit simcard-dns-geo-update.timer simcard-dns-tgbot 2>/dev/null || true
    systemctl disable mosdns dot-gate dnsdist sniproxy wa-shim quic-proxy china-dns-race-proxy simcard-dns-ios-profile.socket simcard-dns-ios-profile simcard-dns-exit simcard-dns-geo-update.timer simcard-dns-tgbot 2>/dev/null || true
    rm -f /etc/systemd/system/{mosdns,dot-gate,sniproxy,wa-shim,quic-proxy,china-dns-race-proxy,simcard-dns-ios-profile,update-mosdns-rules,simcard-dns-exit,simcard-dns-geo-update,simcard-dns-tgbot}.*
    rm -f /etc/systemd/system/simcard-dns-ios-profile@.service \
        /etc/systemd/system/simcard-dns-mihomo@.service \
        /etc/systemd/system/simcard-dns-singbox@.service
    rm -rf /etc/systemd/system/quic-proxy.service.d /etc/systemd/system/mosdns.service.d \
        /etc/systemd/system/dnsdist.service.d /etc/systemd/system/china-dns-race-proxy.service.d
    systemctl daemon-reload
    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/mosdns /etc/dnsdist /usr/local/bin/update-mosdns-rules.sh
    rm -f /usr/local/bin/update-dnsdist-rules.sh /usr/local/bin/mosdns
    rm -f /usr/local/sbin/sniproxy
    rm -f /usr/local/bin/simcard-dns-apply-exit.sh /usr/local/bin/simcard-dns
    rm -f "${WG_DIR}"/pgw-*.conf
    # Repair the host firewall BEFORE removing /etc/simcard-dns, otherwise a
    # managed /etc/nftables.conf would keep a dangling include and fail to load
    # on reboot (leaving the host with no firewall). Also clears auto-mode
    # persistence and the managed marker.
    firewall_cleanup_on_uninstall
    rm -rf /etc/simcard-dns
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    rm -f /etc/sysctl.d/99-simcard-dns.conf
    rm -f /etc/profile.d/go.sh
    if [[ -f /etc/nftables.conf.pgw-backup ]]; then
        warn "Pre-install firewall backup kept at /etc/nftables.conf.pgw-backup (restore manually if wanted)."
    fi
    userdel "${EXIT_USER}" 2>/dev/null || true
    userdel mosdns 2>/dev/null || true
    warn "SSL certificates in /etc/letsencrypt/live/ are kept. Remove manually if needed."
    if [[ -e /swapfile ]]; then
        warn "Swapfile /swapfile is kept. To remove: swapoff /swapfile && rm -f /swapfile && sed -i '/^\\/swapfile /d' /etc/fstab"
    fi
    ok "Uninstall completed"
}

