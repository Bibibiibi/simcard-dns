#!/usr/bin/env bash
#
# One-click installer for 5gpn — downloads the repo and runs install.sh.
#
#   See README for the pinned launcher command; launcher and PGW_COMMIT must match.
#
# (Avoid `sudo bash <(curl ...)`: newer sudo closes the process-substitution
#  fd, which fails as "/dev/fd/63: No such file or directory" on e.g. Debian 13.)
#
# Any extra args are passed straight through to install.sh, e.g.:
#   sudo bash /tmp/5gpn.sh --status
#
set -euo pipefail

REPO="Xiuyixx/5GPN-X"
# Keep source checkout separate from the live runtime/data tree. The
# installer deploys into /opt/5gpn and never removes an existing runtime tree.
SOURCE_DIR="${PGW_SRC_DIR:-/opt/5gpn-source}"
COMMIT="${PGW_COMMIT:-}"

RED='\033[0;31m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Run the pinned launcher as root with PGW_COMMIT (see README)"
    exit 1
fi

if [[ ! "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    err "PGW_COMMIT must be an explicit 40-hex trusted commit (refusing floating branch installs)"
    exit 1
fi

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
    elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@"
    else return 1; fi
}

command -v git >/dev/null 2>&1 || pkg_install git || { err "git is required"; exit 1; }

info "Downloading ${REPO}@${COMMIT} into ${SOURCE_DIR} ..."
if [[ -d "${SOURCE_DIR}/.git" ]]; then
    info "Existing source checkout found; checking out trusted commit..."
    source_status="$(git -C "${SOURCE_DIR}" status --porcelain --untracked-files=all)"
    if [[ -n "$source_status" ]]; then
        err "Existing source tree has local changes; refusing to overwrite it"
        exit 1
    fi
    git -C "${SOURCE_DIR}" fetch "https://github.com/${REPO}.git" "$COMMIT" --quiet
    git -C "${SOURCE_DIR}" checkout --quiet --detach "$COMMIT"
else
    if [[ -e "${SOURCE_DIR}" ]]; then
        err "Source destination exists but is not a git checkout; refusing to remove it"
        exit 1
    fi
    if ! git clone --no-checkout "https://github.com/${REPO}.git" "${SOURCE_DIR}"; then
        err "git clone failed. Check network access to github.com."
        exit 1
    fi
    git -C "${SOURCE_DIR}" checkout --quiet --detach "$COMMIT"
fi
[[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" == "${COMMIT,,}" ]] || { err "Commit verification failed"; exit 1; }
ok "Source ready at ${SOURCE_DIR}; existing /opt/5gpn runtime data was not removed"

cd "${SOURCE_DIR}"
chmod +x install.sh quick-install.sh lib/update-rules.sh 2>/dev/null || true
info "Launching installer..."
exec bash ./install.sh "$@"
