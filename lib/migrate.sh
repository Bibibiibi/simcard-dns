#!/usr/bin/env bash
# simcard-dns module: migrate
# One-time move of a host installed under the old 5GPN-X names (/opt/5gpn,
# /etc/5gpn, 5gpn-* units and helper scripts) to the simcard-dns names.
# --upgrade runs it before anything else. Every file it renames or rewrites is
# archived first; any failure puts the archive back and restarts the old units.
# The Let's Encrypt lineage "5gpn-wildcard" keeps its name (cert.sh reuses it).
# PGW_MIGRATE_ROOT prefixes every path (tests only).
# shellcheck shell=bash

# Rewrite old names inside a file, leaving the certificate lineage alone.
migrate_rewrite_names() {
    perl -pi -e 's{/opt/5gpn/bin/5gpn-ctl}{/opt/simcard-dns/bin/simcard-dns}g;
        s{5gpn-ctl}{simcard-dns}g;
        s{5gpn-(?!wildcard)}{simcard-dns-}g;
        s{(?<=[/.-])5gpn(?=[/.,#"\x27\s:)\]`]|$)}{simcard-dns}g;' "$@"
}
migrate_new_name() {
    local name="$1"
    name="${name//5gpn-ctl/simcard-dns}"
    name="${name//5gpn-/simcard-dns-}"
    printf '%s\n' "${name//5gpn/simcard-dns}"
}
# A real old install has its CLI or config; a bare /opt/5gpn holding only an
# attempt marker (left by a cached old one-line installer) is not one.
legacy_layout_present() {
    local R="${PGW_MIGRATE_ROOT:-}"
    [[ -f "$R/opt/5gpn/bin/5gpn-ctl" || -s "$R/opt/5gpn/etc/.domain" ]]
}
migrate_legacy_layout() {
    local R="${PGW_MIGRATE_ROOT:-}"
    legacy_layout_present || return 0
    if [[ -e "$R/opt/simcard-dns/etc" || -e "$R/opt/simcard-dns/bin" || -e "$R/etc/simcard-dns" ]]; then
        err "Both /opt/5gpn and /opt/simcard-dns exist; refusing to merge them. Move one aside and retry."
        return 1
    fi
    info "Migrating 5GPN-X paths and units to simcard-dns..."
    local sd="$R/etc/systemd/system" ts backup_dir archive f new u
    local -a members=() active=() new_active=() moved=()
    ts="$(date +%Y%m%d%H%M%S)"
    # Existing upgrade backups move first so the archive can live next to them.
    if [[ -d "$R/var/backups/5gpn" && ! -e "$R/var/backups/simcard-dns" ]]; then
        mv -T "$R/var/backups/5gpn" "$R/var/backups/simcard-dns" || return 1
    fi
    backup_dir="$R/var/backups/simcard-dns/migrate.${ts}"
    mkdir -p "$backup_dir" && chmod 700 "$backup_dir" || return 1
    archive="${backup_dir}/legacy.tar.gz"

    # Everything that is renamed or may be rewritten, relative to $R.
    for f in opt/5gpn etc/5gpn var/lib/5gpn var/lib/5gpn-quic etc/systemd/system etc/nftables.conf \
        etc/letsencrypt/renewal etc/letsencrypt/renewal-hooks etc/mosdns etc/sniproxy.conf \
        etc/security/limits.conf etc/systemd/journald.conf.d etc/sysctl.d/99-5gpn.conf \
        etc/modules-load.d/5gpn-net.conf var/log/5gpn-install.log usr/local/bin/update-mosdns-rules.sh; do
        [[ -e "$R/$f" || -L "$R/$f" ]] && members+=("$f")
    done
    for f in "$R"/usr/local/bin/5gpn-*; do
        [[ -e "$f" ]] && members+=("${f#"$R"/}")
    done
    tar -C "${R:-/}" -czf "$archive" "${members[@]}" || { err "Could not archive the old layout; nothing changed"; return 1; }

    # Project units that are running now; they are restarted under new names.
    while read -r u _; do
        [[ -n "$u" ]] && active+=("$u")
    done < <(systemctl list-units --plain --no-legend --state=active \
        '5gpn-*' mosdns.service dot-gate.service sniproxy.service quic-proxy.service wa-shim.service 2>/dev/null || true)

    migrate_restore() {
        warn "Migration failed; restoring the 5GPN-X layout from ${archive}"
        for u in "${new_active[@]}"; do systemctl stop "$u" >/dev/null 2>&1 || true; done
        local m
        for m in "${moved[@]}"; do rm -rf "${R}/${m:?}"; done
        [[ ! -d "$sd" ]] || find "$sd" -depth -name '*simcard-dns*' -exec rm -rf {} + 2>/dev/null || true
        tar -C "${R:-/}" -xzf "$archive" || err "Restore incomplete; archive kept at ${archive}"
        systemctl daemon-reload >/dev/null 2>&1 || true
        [[ ! -f "$R/etc/nftables.conf" ]] || nft -f "$R/etc/nftables.conf" >/dev/null 2>&1 || true
        for u in "${active[@]}"; do systemctl start "$u" >/dev/null 2>&1 || true; done
    }
    migrate_move() { # old new (both relative to $R)
        [[ -e "$R/$1" || -L "$R/$1" ]] || return 0
        mkdir -p "$(dirname "$R/$2")" && mv -T "$R/$1" "$R/$2" && moved+=("$2")
    }

    for u in "${active[@]}"; do systemctl stop "$u" >/dev/null 2>&1 || true; done

    # The bootstrap may already have created /opt/simcard-dns for its attempt
    # marker; carry that marker over the moved runtime tree.
    local pre=""
    if [[ -d "$R/opt/simcard-dns" ]]; then
        pre="${backup_dir}/pre-runtime"
        mv -T "$R/opt/simcard-dns" "$pre" || { migrate_restore; return 1; }
    fi
    if ! { migrate_move opt/5gpn opt/simcard-dns \
        && migrate_move etc/5gpn etc/simcard-dns \
        && migrate_move var/lib/5gpn var/lib/simcard-dns \
        && migrate_move var/lib/5gpn-quic var/lib/simcard-dns-quic \
        && migrate_move etc/sysctl.d/99-5gpn.conf etc/sysctl.d/99-simcard-dns.conf \
        && migrate_move etc/modules-load.d/5gpn-net.conf etc/modules-load.d/simcard-dns-net.conf \
        && migrate_move etc/systemd/journald.conf.d/99-5gpn.conf etc/systemd/journald.conf.d/99-simcard-dns.conf \
        && migrate_move var/log/5gpn-install.log var/log/simcard-dns-install.log; }; then
        migrate_restore; return 1
    fi
    # The old CLI keeps working (with rewritten paths) until --upgrade
    # replaces it; the bot and the timer already call the new name.
    if [[ -f "$R/opt/simcard-dns/bin/5gpn-ctl" ]] \
        && ! mv -T "$R/opt/simcard-dns/bin/5gpn-ctl" "$R/opt/simcard-dns/bin/simcard-dns"; then
        migrate_restore; return 1
    fi
    if [[ -n "$pre" ]]; then
        for f in "$pre"/.install-attempt "$pre"/.installed-commit; do
            [[ -f "$f" ]] && cp -a "$f" "$R/opt/simcard-dns/"
        done
    fi
    # Helper scripts and certbot hooks: rename, then rewrite below.
    for f in "$R"/usr/local/bin/5gpn-* "$R"/etc/letsencrypt/renewal-hooks/*/*5gpn*; do
        [[ -e "$f" ]] || continue
        new="$(dirname "$f")/$(migrate_new_name "$(basename "$f")")"
        if ! mv -T "$f" "$new"; then migrate_restore; return 1; fi
        moved+=("${new#"$R"/}")
    done
    # systemd: unit files and drop-in dirs first, then enablement symlinks
    # (renamed and pointed at the renamed unit, so enabled state is kept).
    if [[ -d "$sd" ]]; then
        while IFS= read -r -d '' f; do
            new="$(dirname "$f")/$(migrate_new_name "$(basename "$f")")"
            mv -T "$f" "$new" || { migrate_restore; return 1; }
        done < <(find "$sd" -depth -name '*5gpn*' ! -type l -print0)
        while IFS= read -r -d '' f; do
            local target
            target="$(readlink "$f")"
            new="$(dirname "$f")/$(migrate_new_name "$(basename "$f")")"
            if ! ln -sfn "$(migrate_new_name "$target")" "$new"; then migrate_restore; return 1; fi
            rm -f "$f"
        done < <(find "$sd" -name '*5gpn*' -type l -print0)
    fi
    rm -f "$R"/var/lib/systemd/timers/stamp-5gpn-* 2>/dev/null || true

    # Rewrite references inside every text file the project wrote.
    local -a scan=()
    # bin/ too: the old programs restarted below must already use the new paths.
    for f in opt/simcard-dns/bin opt/simcard-dns/etc opt/simcard-dns/www etc/simcard-dns var/lib/simcard-dns etc/systemd/system \
        etc/nftables.conf etc/letsencrypt/renewal etc/letsencrypt/renewal-hooks etc/mosdns etc/sniproxy.conf \
        etc/security/limits.conf usr/local/bin/update-mosdns-rules.sh; do
        [[ -e "$R/$f" ]] && scan+=("$R/$f")
    done
    for f in "$R"/usr/local/bin/simcard-dns-*; do
        [[ -e "$f" ]] && scan+=("$f")
    done
    if ((${#scan[@]})); then
        local -a files=()
        while IFS= read -r -d '' f; do files+=("$f"); done \
            < <(find "${scan[@]}" -type f -exec grep -lIZ 5gpn {} + 2>/dev/null)
        if ((${#files[@]})) && ! migrate_rewrite_names "${files[@]}"; then
            migrate_restore; return 1
        fi
    fi
    # Legacy source checkout: kept in the archive directory, not deleted.
    [[ ! -d "$R/opt/5gpn-source" ]] || mv -T "$R/opt/5gpn-source" "${backup_dir}/legacy-source" || true

    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$R/etc/nftables.conf" ]] && grep -q 'simcard-dns/pgw-exit.nft' "$R/etc/nftables.conf"; then
        if ! nft -c -f "$R/etc/nftables.conf" >/dev/null 2>&1 || ! nft -f "$R/etc/nftables.conf" >/dev/null 2>&1; then
            migrate_restore; return 1
        fi
    elif [[ -f "$R/etc/simcard-dns/pgw-exit.nft" ]]; then
        nft -f "$R/etc/simcard-dns/pgw-exit.nft" >/dev/null 2>&1 || true
    fi
    for u in "${active[@]}"; do
        new="$(migrate_new_name "$u")"
        new_active+=("$new")
        if ! systemctl start "$new" >/dev/null 2>&1; then
            err "Unit ${new} failed to start after migration"
            migrate_restore; return 1
        fi
    done
    ok "Migrated to simcard-dns (old layout archived at ${archive})"
}
