#!/usr/bin/env bash
# The fwmark policy rule must stay a single rule no matter how often the exit
# is applied, and copies stacked by older versions must be pruned. Runs the
# real apply-exit helper and set_exit against a fake `ip` (and `nft`) that
# keeps an in-memory rule table, so the host's routing is never touched.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "$1" >&2; exit 1; }

bin="${tmp}/bin"
mkdir -p "$bin"
rules="${tmp}/rules"     # one "<prio> <mark> <table>" per line
calls="${tmp}/ip.calls"
: > "$rules"
: > "$calls"

cat > "${bin}/ip" <<'EOF'
#!/usr/bin/env bash
# Minimal `ip rule` model: auto-priority like the kernel (one below the lowest
# non-zero priority), `del` removes the first match and fails when none does.
printf '%s\n' "$*" >> "${FAKE_IP_CALLS}"
[[ "${1:-}" == "-4" ]] && shift
case "${1:-} ${2:-}" in
    "rule show"|"rule list"|"rule ")
        echo "0:	from all lookup local"
        sort -n "${FAKE_IP_RULES}" | while read -r p m t; do
            printf '%s:\tfrom all fwmark %s lookup %s\n' "$p" "$m" "$t"
        done
        echo "32766:	from all lookup main"
        echo "32767:	from all lookup default"
        exit 0 ;;
    "rule add"|"rule del")
        op="$2"; shift 2
        prio="" mark="" table=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                priority|pref|prio) prio="$2"; shift 2 ;;
                fwmark) mark="$2"; shift 2 ;;
                table|lookup) table="$2"; shift 2 ;;
                *) echo "fake ip: unsupported argument $1" >&2; exit 2 ;;
            esac
        done
        if [[ "$op" == "add" ]]; then
            if [[ -z "$prio" ]]; then
                low="$(sort -n "${FAKE_IP_RULES}" | head -n1 | cut -d' ' -f1)"
                prio=$(( ${low:-32766} - 1 ))
            fi
            printf '%s %s %s\n' "$prio" "$mark" "$table" >> "${FAKE_IP_RULES}"
            exit 0
        fi
        awk -v p="$prio" -v m="$mark" -v t="$table" '
            !done && (p == "" || $1 == p) && (m == "" || $2 == m) && (t == "" || $3 == t) { done = 1; next }
            { print }
            END { exit done ? 0 : 1 }
        ' "${FAKE_IP_RULES}" > "${FAKE_IP_RULES}.new" || { rm -f "${FAKE_IP_RULES}.new"; exit 2; }
        mv "${FAKE_IP_RULES}.new" "${FAKE_IP_RULES}"
        exit 0 ;;
    "route "*) exit 0 ;;
    "link "*) exit 1 ;;
esac
echo "fake ip: unsupported command $*" >&2
exit 2
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "${bin}/nft"
chmod +x "${bin}/ip" "${bin}/nft"
export PATH="${bin}:${PATH}" FAKE_IP_RULES="$rules" FAKE_IP_CALLS="$calls"

# shellcheck disable=SC2034 # Consumed by the eval'd install_apply_exit_helper/set_exit.
{
    EXIT_MARK="0x1"
    EXIT_TABLE="100"
    CONF_DIR="${tmp}/conf"
    EXITS_DIR="${tmp}/exits"
    WG_DIR="${tmp}/wg"
}
EXIT_RULE_PRIO="$(sed -n 's/^EXIT_RULE_PRIO="\([0-9]*\)"$/\1/p' "${root}/install.sh")"
[[ -n "$EXIT_RULE_PRIO" ]] || fail "install.sh must define a numeric EXIT_RULE_PRIO"
mkdir -p "$CONF_DIR" "$EXITS_DIR" "$WG_DIR"
echo local > "${CONF_DIR}/current-exit"

# Print one top-level function from lib/exits.sh. A function whose heredoc has
# its own column-0 "}" lines is cut at the next function ($2) instead.
fn_body() {
    awk -v f="$1" -v next_fn="${2:-}" '
        $0 ~ "^" f "\\(\\) \\{" { copy = 1; print; next }
        copy && next_fn != "" && $0 ~ "^" next_fn "\\(\\) \\{" { exit }
        copy { print }
        copy && next_fn == "" && /^}$/ { exit }
    ' "${root}/lib/exits.sh"
}
eval "$(fn_body sync_exit_rule)"
# Generate the helper into the sandbox instead of /usr/local/bin.
helper="${tmp}/apply-exit.sh"
eval "$(fn_body install_apply_exit_helper setup_exit_switching | sed "s#/usr/local/bin/simcard-dns-apply-exit.sh#${helper}#g")"
install_apply_exit_helper
[[ -x "$helper" ]] || fail "apply-exit helper was not generated"

expect_single_rule() {  # $1: context
    local got want
    got="$(cat "$rules")"
    want="${EXIT_RULE_PRIO} ${EXIT_MARK} ${EXIT_TABLE}"
    [[ "$got" == "$want" ]] || fail "$1: expected exactly '${want}', got:"$'\n'"${got}"
}

# --- repeated applies keep a single rule --------------------------------------
for _ in 1 2 3 4 5; do
    "$helper" >/dev/null
done
expect_single_rule "five helper runs"
[[ "$(grep -c '^rule add' "$calls")" == "1" ]] || fail "helper must add the rule only once across runs"

# --- duplicates stacked by older versions are pruned to one -------------------
: > "$rules"
for _ in $(seq 1 28); do ip rule add fwmark "$EXIT_MARK" table "$EXIT_TABLE"; done
[[ "$(ip rule show | grep -c fwmark)" == "28" ]] || fail "fixture: expected 28 stacked rules"
"$helper" >/dev/null
expect_single_rule "helper on 28 legacy duplicates"

# --- a duplicate at the target priority itself is pruned too ------------------
printf '%s %s %s\n' "$EXIT_RULE_PRIO" "$EXIT_MARK" "$EXIT_TABLE" >> "$rules"
printf '%s %s %s\n' 32700 "$EXIT_MARK" "$EXIT_TABLE" >> "$rules"
"$helper" >/dev/null
expect_single_rule "helper with a same-priority duplicate"

# --- unrelated rules are left alone -------------------------------------------
printf '%s\n' "200 0x2 100" "300 0x1 200" >> "$rules"
"$helper" >/dev/null
[[ "$(sort -n "$rules")" == $'200 0x2 100\n300 0x1 200\n'"${EXIT_RULE_PRIO} ${EXIT_MARK} ${EXIT_TABLE}" ]] \
    || fail "rules with another mark or table must not be touched"
: > "$rules"

# --- set_exit (CLI / Bot switch) is idempotent as well -----------------------
ensure_proxy_user() { :; }
setup_exit_switching() { :; }
exit_down() { :; }
ok() { :; }
eval "$(fn_body set_exit)"
for _ in 1 2 3; do (set_exit local) >/dev/null; done
expect_single_rule "three set_exit runs"
for _ in 1 2 3; do ip rule add fwmark "$EXIT_MARK" table "$EXIT_TABLE"; done
(set_exit local) >/dev/null
expect_single_rule "set_exit on legacy duplicates"

# --- no call site may add the rule without going through sync_exit_rule ------
# shellcheck disable=SC2016 # Matches the literal "$prio" in the source.
bare="$(grep -n 'ip rule add' "${root}/lib/exits.sh" "${root}/install.sh" \
    | grep -v -e ':[[:space:]]*#' -e 'priority "\$prio"' || true)"
[[ -z "$bare" ]] || fail "unguarded 'ip rule add' left:"$'\n'"${bare}"

# --- upgrades regenerate the helper, so existing hosts get the fix -----------
upgrade_body="$(awk '/^upgrade_code\(\) \(/{c=1} c{print} c&&/^\)$/{exit}' "${root}/install.sh")"
[[ "$upgrade_body" == *install_apply_exit_helper* ]] || fail "upgrade_code must regenerate the apply-exit helper"
[[ "$upgrade_body" == *'/usr/local/bin/simcard-dns-apply-exit.sh'* ]] \
    || fail "upgrade_code must snapshot the apply-exit helper for rollback"

echo "test_exit_rule_idempotent: OK"
