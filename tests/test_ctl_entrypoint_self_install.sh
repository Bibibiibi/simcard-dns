#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are read by the eval-loaded function.
# install_ctl_entrypoint is also reached from the installed simcard-dns (e.g.
# --setup-tgbot), where LIB_DIR is the destination itself. Copying a file onto
# itself must be skipped instead of failing the whole command.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "$1" >&2; exit 1; }
err() { echo "$*" >&2; }
eval "$(awk '/^install_ctl_entrypoint\(\)/,/^}/' "${root}/lib/services.sh")"

# From a source checkout: modules are copied next to the installed CLI.
BASE_DIR="${tmp}/opt"
LIB_DIR="${root}/lib"
SCRIPT_PATH="${root}/install.sh"
export PGW_CTL_SHIM="${tmp}/usr-local-bin/simcard-dns"
install_ctl_entrypoint || fail "install from a checkout must succeed"
[[ -f "${BASE_DIR}/bin/simcard-dns" && -f "${BASE_DIR}/bin/lib/host-setup.sh" && -f "${BASE_DIR}/bin/lib/migrate.sh" ]] \
    || fail "checkout install must ship simcard-dns with its modules"
# The PATH command is a wrapper (the entrypoint finds lib/ next to itself).
[[ -x "$PGW_CTL_SHIM" && ! -L "$PGW_CTL_SHIM" ]] || fail "simcard-dns must be on PATH as a wrapper, not a symlink"
grep -qF "exec bash ${BASE_DIR}/bin/simcard-dns \"\$@\"" "$PGW_CTL_SHIM" || fail "wrapper must exec the installed entrypoint"

# From the installed CLI: source and destination are the same files.
LIB_DIR="${BASE_DIR}/bin/lib"
SCRIPT_PATH="${BASE_DIR}/bin/simcard-dns"
out="$(install_ctl_entrypoint 2>&1)" || fail "re-running from the installed CLI must succeed: ${out}"
[[ "$out" != *"same file"* ]] || fail "must not try to copy files onto themselves"

echo "ctl entrypoint self-install OK"
