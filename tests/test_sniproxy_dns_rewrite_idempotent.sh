#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/bin/systemctl"

mkdir -p "${tmp}/etc/mosdns" "${tmp}/opt/etc"
cat > "${tmp}/sniproxy.conf" <<'EOF'
user pxout
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 9.9.9.9
    mode ipv4_only
}

listener 80 {
    proto http
}
EOF
cat > "${tmp}/update-mosdns-rules.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/update-mosdns-rules.sh"

script="${tmp}/install-wrapper.sh"
# install.sh sources lib/*.sh relative to its own directory. The DNS-mutating
# functions now live in lib/dns.sh (and helpers in the other modules), so the
# path-redirecting sed below must be applied to the modules too, not only to
# install.sh. We therefore build a rewritten lib/ next to the wrapper instead of
# symlinking the pristine repo lib/.
mkdir -p "${tmp}/lib"
sed_redirect() {
  sed \
    -e "s#/etc/sniproxy.conf#${tmp}/sniproxy.conf#g" \
    -e "s#/etc/mosdns#${tmp}/etc/mosdns#g" \
    -e "s#/opt/simcard-dns#${tmp}/opt#g" \
    -e "s#/usr/local/bin/update-mosdns-rules.sh#${tmp}/update-mosdns-rules.sh#g" \
    -e "s#/var/lib/simcard-dns-quic#${tmp}/var/lib/simcard-dns-quic#g" \
    "$1"
}
for _m in "${root}"/lib/*; do
  base="$(basename "${_m}")"
  [[ -d "${_m}" ]] && continue
  case "${base}" in
    *.sh) sed_redirect "${_m}" > "${tmp}/lib/${base}" ;;
    *)    cp "${_m}" "${tmp}/lib/${base}" ;;
  esac
done
sed_redirect "${root}/install.sh" > "${script}"
chmod +x "${script}"

# The temporary lib/ tree keeps this wrapper self-contained; no bootstrap
# download is needed. Isolate the routing lock as well as runtime paths.
export PGW_ROUTING_LOCK_FILE="${tmp}/routing.lock"
PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns \
  "1.1.1.1 8.8.8.8 9.9.9.9" \
  "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29"
PATH="${tmp}/bin:${PATH}" bash "${script}" --set-dns \
  "1.1.1.1 8.8.8.8 9.9.9.9" \
  "101.226.4.6 218.30.118.6 180.76.76.76 119.29.29.29"

grep -q 'nameserver 1.1.1.1' "${tmp}/sniproxy.conf" || { echo "sniproxy remote DNS missing" >&2; exit 1; }
grep -q 'nameserver 8.8.8.8' "${tmp}/sniproxy.conf" || { echo "sniproxy secondary remote DNS missing" >&2; exit 1; }
grep -q 'mode ipv4_only' "${tmp}/sniproxy.conf" || { echo "sniproxy ipv4_only missing" >&2; exit 1; }
[[ "$(grep -c '^resolver {$' "${tmp}/sniproxy.conf")" -eq 1 ]] || { echo "resolver block duplicated" >&2; exit 1; }

echo "sniproxy DNS rewrite idempotency OK"
