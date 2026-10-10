#!/usr/bin/env bash
#
# One-click installer for 5gpn — downloads the repo and runs install.sh.
#
#   With no PGW_COMMIT, resolve the current main commit before checkout.
#   PGW_COMMIT may be set explicitly for a reviewed immutable install.
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
RUNTIME_DIR="/opt/5gpn"
MARKER="${RUNTIME_DIR}/.installed-commit"
ATTEMPT="${RUNTIME_DIR}/.install-attempt"

RED='\033[0;31m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Run the installer as root (for example: curl ... | sudo bash)"
    exit 1
fi

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
    elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@"
    else return 1; fi
}

# Management commands are not install/upgrade requests, even when offline.
if [[ $# -gt 0 && -f "${RUNTIME_DIR}/bin/5gpn-ctl" ]]; then
    exec bash "${RUNTIME_DIR}/bin/5gpn-ctl" "$@"
fi
# Never check out source inside the live data tree (including symlink aliases).
source_real="$(realpath -m "$SOURCE_DIR")"
source_nominal="$(realpath -m -s "$SOURCE_DIR")"
runtime_real="$(realpath -m "$RUNTIME_DIR")"
if [[ "$source_real" == "$runtime_real" || "$source_real" == "$runtime_real/"* || "$runtime_real" == "$source_real/"* ]]; then
    err "Source and runtime directories must be separate"
    exit 1
fi

command -v git >/dev/null 2>&1 || pkg_install git || { err "git is required"; exit 1; }

if [[ -z "$COMMIT" ]]; then
    COMMIT="$(git ls-remote "https://github.com/${REPO}.git" refs/heads/main | awk 'NR==1 {print $1}')" || {
        err "Unable to resolve main from GitHub"
        exit 1
    }
fi
if [[ ! "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    err "Unable to resolve a complete main commit; set PGW_COMMIT to a 40-hex commit and retry"
    exit 1
fi

COMMIT="${COMMIT,,}"
export PGW_COMMIT="$COMMIT"
mode=install
if [[ $# -eq 0 ]]; then
    # A checkout alone is NOT an installation. Recognize deployed runtime
    # state, including historical non-Git installs without a version marker.
    if [[ -f "$MARKER" || -f "$ATTEMPT" || -f "${RUNTIME_DIR}/bin/5gpn-ctl" || -s "${RUNTIME_DIR}/etc/.domain" ]]; then
        mode=upgrade
        installed="$(cat "$MARKER" 2>/dev/null || true)"
        if [[ "$installed" == "$COMMIT" && ! -e "$ATTEMPT" ]]; then
            ok "已是当前版本 ${COMMIT}，无需升级。"
            exit 0
        fi
        info "检测到已有安装（${installed:-legacy/unversioned}），保留配置并升级。"
    else
        info "未检测到已有安装，开始首次安装。"
    fi
fi

info "Downloading ${REPO}@${COMMIT} into ${SOURCE_DIR} ..."
# Reject ambiguous paths rather than rename a symlink target or a traversal.
if [[ "$SOURCE_DIR" != /* || "/$SOURCE_DIR/" == */../* || "/$SOURCE_DIR/" == */./* ||
      "$source_nominal" != "$source_real" ]]; then
    err "Source path must be absolute and must not contain symlinks or traversal"
    exit 1
fi
SOURCE_DIR="$source_real"
# Renames are safe only within a trusted parent. Check ancestors too, allowing
# sticky directories such as /tmp (the immediate parent must still be private).
parent="$(dirname -- "$SOURCE_DIR")"
check_parent="$parent"
while [[ "$check_parent" != / ]]; do
    if [[ -d "$check_parent" ]]; then
        owner="$(stat -c %u -- "$check_parent")"
        permissions="$(stat -c %a -- "$check_parent")"
        if [[ "$owner" != "$EUID" ]] ||
           { (( (8#$permissions & 0022) != 0 )) &&
              { [[ "$check_parent" == "$parent" ]] || (( (8#$permissions & 01000) == 0 )); }; }; then
            err "Source parent must be root-owned and not writable by other users: $check_parent"
            exit 1
        fi
    fi
    check_parent="$(dirname -- "$check_parent")"
done

stage_source() {
    local stage
    mkdir -p "$(dirname -- "$SOURCE_DIR")" || return 1
    stage="$(mktemp -d "${SOURCE_DIR}.staging.XXXXXX")" || return 1
    # The staging checkout is disposable; the existing source is not touched
    # until clone, checkout, and commit verification have all succeeded.
    if ! git clone --no-checkout "https://github.com/${REPO}.git" "$stage" >&2 ||
       ! git -C "$stage" checkout --quiet --detach "$COMMIT" ||
       [[ "$(git -C "$stage" rev-parse HEAD)" != "${COMMIT,,}" ]]; then
        rm -rf -- "$stage"
        err "Unable to prepare a clean source checkout; existing source was preserved"
        return 1
    fi
    printf '%s\n' "$stage"
}

replace_source_atomically() {
    local stage="$1" backup
    # A private, unique container prevents collisions without overwriting any
    # backup. Moving into it is a same-filesystem atomic rename; retain modes,
    # ownership and ignored files inside, protected by the root-only container.
    if ! backup="$(mktemp -d "${SOURCE_DIR}.backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"; then
        err "Unable to reserve source backup; old source unchanged; prepared checkout: $stage"
        return 1
    fi
    info "Preserving previous source at ${backup}/source (retained even if interrupted)"
    if ! mv -T -- "$SOURCE_DIR" "$backup/source"; then
        err "Unable to archive existing source; old source unchanged; prepared checkout: $stage"
        return 1
    fi
    if mv -T -- "$stage" "$SOURCE_DIR"; then
        info "Previous source preserved at ${backup}/source"
        return 0
    fi
    # Do not replace a path created by another process during the failure.
    err "Unable to publish clean source; old source preserved at ${backup}/source; prepared checkout: $stage"

    return 1
}

if [[ -d "${SOURCE_DIR}/.git" ]]; then
    info "Existing source checkout found; checking out trusted commit..."
    source_status="$(git -C "${SOURCE_DIR}" status --porcelain --untracked-files=all --ignored)"
    if [[ -n "$source_status" ]]; then
        info "Local source changes found; preparing a clean checkout and archiving the old tree"
        stage="$(stage_source)" || exit 1
        replace_source_atomically "$stage" || exit 1
    else
        git -C "${SOURCE_DIR}" fetch "https://github.com/${REPO}.git" "$COMMIT" --quiet
        git -C "${SOURCE_DIR}" checkout --quiet --detach "$COMMIT"
    fi
elif [[ -e "${SOURCE_DIR}" ]]; then
    err "Source destination exists but is not a git checkout; refusing to remove it"
    exit 1
else
    stage="$(stage_source)" || exit 1
    mv -T -- "$stage" "$SOURCE_DIR"
fi
[[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" == "${COMMIT,,}" ]] || { err "Commit verification failed"; exit 1; }
ok "Source ready at ${SOURCE_DIR}; existing /opt/5gpn runtime data was not removed"

cd "${SOURCE_DIR}"
# Arguments retain stdin verbatim and never create installation markers.
if [[ $# -gt 0 ]]; then
    exec bash ./install.sh "$@"
fi
mkdir -p "$RUNTIME_DIR"
umask 077
printf 'mode=%s\ntarget=%s\nstarted=%s\n' "$mode" "$COMMIT" "$(date -u +%FT%TZ)" > "$ATTEMPT"
trap 'rc=$?; if (( rc != 0 )); then err "安装/升级未完成；保留旧版本标记。诊断: $ATTEMPT 、${RUNTIME_DIR}/.upgrade-attempt 或 /var/log/5gpn-install.log；检查备份后重试。"; fi' EXIT
info "Launching ${mode} at ${COMMIT}..."
if [[ "$mode" == upgrade ]]; then
    bash ./install.sh --upgrade < /dev/null
elif [[ ! -t 0 ]] && ( : < /dev/tty ) 2>/dev/null; then
    bash ./install.sh < /dev/tty
else
    bash ./install.sh
fi
# A resolved checkout is not a successful deployment. Publish only on success.
marker_tmp="$(mktemp "${MARKER}.XXXXXX")"
printf '%s\n' "$COMMIT" > "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -f "$ATTEMPT"
ok "${mode} 完成，版本提交 ${COMMIT}"
