#!/usr/bin/env bash
# shellcheck disable=SC2034 # Globals are read by the eval-loaded function.
# install_ctl_entrypoint is also reached from the installed 5gpn-ctl (e.g.
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
install_ctl_entrypoint || fail "install from a checkout must succeed"
[[ -f "${BASE_DIR}/bin/5gpn-ctl" && -f "${BASE_DIR}/bin/lib/host-setup.sh" ]] \
    || fail "checkout install must ship 5gpn-ctl with its modules"

# From the installed CLI: source and destination are the same files.
LIB_DIR="${BASE_DIR}/bin/lib"
SCRIPT_PATH="${BASE_DIR}/bin/5gpn-ctl"
out="$(install_ctl_entrypoint 2>&1)" || fail "re-running from the installed CLI must succeed: ${out}"
[[ "$out" != *"same file"* ]] || fail "must not try to copy files onto themselves"

echo "ctl entrypoint self-install OK"
