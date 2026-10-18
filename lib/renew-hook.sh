#!/bin/bash
# Let's Encrypt renewal hook - copy certs to mosdns-readable location and reload
set -e

DOMAIN=$(cat /opt/simcard-dns/etc/.domain 2>/dev/null || cat /etc/mosdns/.domain 2>/dev/null || true)
# A reset (random) DoT name is served by a wildcard lineage whose directory is
# named after the certificate, not the domain.
LINEAGE=$(cat /opt/simcard-dns/etc/.cert_lineage 2>/dev/null || true)
if [[ -n "$LINEAGE" && -d "/etc/letsencrypt/live/${LINEAGE}" ]]; then
    LIVE_DIR="/etc/letsencrypt/live/${LINEAGE}"
elif [[ -n "$DOMAIN" && -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
else
    LIVE_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d | grep -v "^/etc/letsencrypt/live$" | head -n1)
fi
if [[ -z "$LIVE_DIR" ]]; then
    echo "[!] No certificate live directory found"
    exit 1
fi

mkdir -p /etc/mosdns/certs
cp "${LIVE_DIR}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
cp "${LIVE_DIR}/privkey.pem" /etc/mosdns/certs/privkey.pem
chown -R mosdns:mosdns /etc/mosdns/certs/
chmod 600 /etc/mosdns/certs/*.pem

if systemctl is-active --quiet mosdns; then
    systemctl restart mosdns
fi
