# shellcheck shell=bash disable=SC2034  # globals are used by the scripts that source this file
# panels.sh - adds/removes the per-vhost enforcement include:
#   HestiaCP  per-domain nginx.conf_* / nginx.ssl.conf_* custom include files
#   Plesk     marker block in /var/www/vhosts/system/<domain>/conf/vhost_nginx.conf
#   plain     opt-in: a marked include line after each "server {"
#
# Every function that changes a file calls txn_track first, and never from a
# subshell (the transaction bookkeeping lives in shell variables). Sync
# functions set PANEL_CHANGED=1; remove functions append to REMOVED_FILES.

PANEL_CHANGED=0
PLESK_RECONFIGURE=()
REMOVED_FILES=()
HESTIA_FILE="nginx-block-bad-ips"
PLESK_BEGIN="# BEGIN nginx-block-bad-ips (managed block: do not edit, removed by uninstall.sh)"
PLESK_END="# END nginx-block-bad-ips"
PLAIN_TAG="# nginx-block-bad-ips"

include_line() { echo "include $NBBI_ENFORCE;"; }

state_add() {  # state_add LISTFILE LINE
    local f="$NBBI_STATE/$1"
    [ "$NBBI_DRY_RUN" = 1 ] && return 0
    mkdir -p "$NBBI_STATE"
    touch "$f"
    grep -qxF -- "$2" "$f" || printf '%s\n' "$2" >> "$f"
}

state_del() {
    local f="$NBBI_STATE/$1" tmp
    [ -f "$f" ] || return 0
    tmp=$(mktemp "$NBBI_STATE/.st.XXXXXX")
    grep -vxF -- "$2" "$f" > "$tmp" || true
    mv -f "$tmp" "$f"
}

state_has() { [ -f "$NBBI_STATE/$1" ] && grep -qxF -- "$2" "$NBBI_STATE/$1"; }

# ---------------------------------------------------------------- HestiaCP ---

# Prints "dir|base" for every custom include pattern found in Hestia's
# generated domain configs, e.g. "/home/u/conf/web/example.com|nginx.ssl.conf_".
hestia_targets() {
    local d="$NGINX_DIR/conf.d/domains"
    [ -d "$d" ] || return 0
    grep -hoE 'include[[:space:]]+[^;]*/nginx(\.ssl)?\.conf_\*' "$d"/*.conf 2>/dev/null \
        | awk '{ p = $2; sub(/\*$/, "", p); n = split(p, a, "/"); base = a[n]; dir = substr(p, 1, length(p) - length(base) - 1); print dir "|" base }' \
        | sort -u
}

hestia_file_content() {
    printf '# Managed by nginx-block-bad-ips: blocks bad IPs for this domain.\n# Removed automatically by uninstall.sh. Do not edit.\n%s\n' "$(include_line)"
}

hestia_sync() {
    local dir base f tmp
    while IFS='|' read -r dir base; do
        [ -d "$dir" ] || continue
        f="$dir/${base}$HESTIA_FILE"
        if [ "$NBBI_DRY_RUN" = 1 ]; then
            [ -f "$f" ] || info "[dry-run] would create $f"
            continue
        fi
        tmp=$(mktemp "$dir/.nbbi.XXXXXX")
        hestia_file_content > "$tmp"
        chown root:root "$tmp"
        if install_if_changed "$tmp" "$f" 0644; then
            PANEL_CHANGED=1
            state_add hestia.files "$f"
        fi
    done < <(hestia_targets)
}

hestia_remove() {
    local f list
    list=$(mktemp "$NBBI_VAR/.rm.XXXXXX")
    {
        [ -f "$NBBI_STATE/hestia.files" ] && cat "$NBBI_STATE/hestia.files"
        find /home -maxdepth 5 -path '*/conf/web/*' -name "nginx*.conf_$HESTIA_FILE" 2>/dev/null
    } | sort -u > "$list"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        txn_track "$f"
        rm -f -- "$f"
        REMOVED_FILES+=("$f")
    done < "$list"
    rm -f -- "$list"
}

hestia_coverage() {  # prints "covered total"
    local total=0 covered=0 dir base
    while IFS='|' read -r dir base; do
        total=$((total + 1))
        [ -f "$dir/${base}$HESTIA_FILE" ] && covered=$((covered + 1))
    done < <(hestia_targets)
    echo "$covered $total"
}

# ------------------------------------------------------------------- Plesk ---

plesk_vhost_confs() { ls -1 "$NGINX_DIR"/plesk.conf.d/vhosts/*.conf 2>/dev/null; }

plesk_block() { printf '%s\n%s\n%s\n' "$PLESK_BEGIN" "$(include_line)" "$PLESK_END"; }

plesk_httpdmng() {
    if [ -x /usr/local/psa/admin/sbin/httpdmng ]; then
        /usr/local/psa/admin/sbin/httpdmng "$@"
    else
        plesk sbin httpdmng "$@"
    fi
}

plesk_sync() {
    local vconf domain target sysdir tmp included
    PLESK_RECONFIGURE=()
    while IFS= read -r vconf; do
        domain=$(basename "$vconf" .conf)
        target=$(grep -oE 'include[[:space:]]+"?[^";]*/vhost_nginx\.conf' "$vconf" 2>/dev/null | head -1 | sed -E 's/^include[[:space:]]+"?//')
        sysdir="/var/www/vhosts/system/$domain/conf"
        included=1
        [ -n "$target" ] || { target="$sysdir/vhost_nginx.conf"; included=0; }
        [ -d "$(dirname "$target")" ] || continue
        if [ -f "$target" ]; then
            if ! grep -qF "$PLESK_BEGIN" "$target"; then
                if [ "$NBBI_DRY_RUN" = 1 ]; then
                    info "[dry-run] would add the enforcement block to $target"
                else
                    txn_track "$target"
                    local nl=""
                    [ -s "$target" ] && [ -n "$(tail -c1 "$target")" ] && nl=1
                    { [ -n "$nl" ] && echo; echo; plesk_block; } >> "$target"
                    state_add plesk.modified "$target"
                    PANEL_CHANGED=1
                fi
            fi
            # File present but not included (e.g. left empty by a rollback):
            # ask Plesk once to regenerate; suspended domains stay excluded.
            if [ "$included" = 0 ] && ! state_has plesk.reconfigured "$domain"; then
                [ "$NBBI_DRY_RUN" = 1 ] || PLESK_RECONFIGURE+=("$domain")
            fi
        else
            # Plesk only includes vhost_nginx.conf when it exists: create it and
            # let Plesk regenerate this domain's config (without restarting anything).
            if [ "$NBBI_DRY_RUN" = 1 ]; then info "[dry-run] would create $target and reconfigure $domain"; continue; fi
            txn_track "$target" keep-empty
            tmp=$(mktemp "$(dirname "$target")/.nbbi.XXXXXX")
            plesk_block > "$tmp"
            if [ -f "$(dirname "$target")/nginx.conf" ]; then
                chown --reference="$(dirname "$target")/nginx.conf" "$tmp" 2>/dev/null || true
                chmod --reference="$(dirname "$target")/nginx.conf" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
            else
                chmod 0600 "$tmp"
            fi
            mv -f -- "$tmp" "$target"
            state_add plesk.created "$target"
            PLESK_RECONFIGURE+=("$domain")
            PANEL_CHANGED=1
        fi
    done < <(plesk_vhost_confs)
    if [ "${#PLESK_RECONFIGURE[@]}" -gt 0 ]; then
        # Plesk rewrites these generated files; snapshot them for the rollback.
        for domain in "${PLESK_RECONFIGURE[@]}"; do
            for vconf in "$NGINX_DIR/plesk.conf.d/vhosts/$domain.conf" "/var/www/vhosts/system/$domain/conf/nginx.conf"; do
                [ -e "$vconf" ] && txn_track "$(readlink -f "$vconf")"
            done
            state_add plesk.reconfigured "$domain"
        done
        PANEL_CHANGED=1
        info "plesk: regenerating the web server config of ${#PLESK_RECONFIGURE[@]} domain(s) so they include vhost_nginx.conf"
        plesk_httpdmng --reconfigure-domains "$(IFS=,; echo "${PLESK_RECONFIGURE[*]}")" -no-restart >&2 \
            || warn "plesk: httpdmng reported an error; nginx -t will decide"
    fi
}

# Removes our marker block (and the files we created).
plesk_remove() {
    local f tmp domain reconf=()
    {
        [ -f "$NBBI_STATE/plesk.created" ] && cat "$NBBI_STATE/plesk.created"
        [ -f "$NBBI_STATE/plesk.modified" ] && cat "$NBBI_STATE/plesk.modified"
        grep -lF "$PLESK_BEGIN" /var/www/vhosts/system/*/conf/vhost_nginx.conf 2>/dev/null
    } | sort -u > "$NBBI_VAR/.plesk-remove.list"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        txn_track "$f"
        tmp=$(mktemp "$(dirname "$f")/.nbbi.XXXXXX")
        awk -v b="$PLESK_BEGIN" -v e="$PLESK_END" '
            $0 == b { skip = 1; next }
            skip && $0 == e { skip = 0; next }
            !skip { print }
        ' "$f" > "$tmp"
        # drop trailing blank lines we added
        sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
        if state_has plesk.created "$f" && ! grep -q '[^[:space:]]' "$tmp"; then
            rm -f -- "$tmp" "$f"
            domain=$(basename "$(dirname "$(dirname "$f")")")
            reconf+=("$domain")
        else
            chown --reference="$f" "$tmp" 2>/dev/null || true
            chmod --reference="$f" "$tmp" 2>/dev/null || true
            mv -f -- "$tmp" "$f"
        fi
        REMOVED_FILES+=("$f")
    done < "$NBBI_VAR/.plesk-remove.list"
    rm -f "$NBBI_VAR/.plesk-remove.list"
    if [ "${#reconf[@]}" -gt 0 ]; then
        for domain in "${reconf[@]}"; do
            for f in "$NGINX_DIR/plesk.conf.d/vhosts/$domain.conf" "/var/www/vhosts/system/$domain/conf/nginx.conf"; do
                [ -e "$f" ] && txn_track "$(readlink -f "$f")"
            done
        done
        plesk_httpdmng --reconfigure-domains "$(IFS=,; echo "${reconf[*]}")" -no-restart >&2 \
            || warn "plesk: httpdmng reported an error"
    fi
}

plesk_coverage() {
    local total=0 covered=0 vconf target
    while IFS= read -r vconf; do
        total=$((total + 1))
        target=$(grep -oE 'include[[:space:]]+"?[^";]*/vhost_nginx\.conf' "$vconf" 2>/dev/null | head -1 | sed -E 's/^include[[:space:]]+"?//')
        [ -n "$target" ] && [ -f "$target" ] && grep -qF "$PLESK_BEGIN" "$target" && covered=$((covered + 1))
    done < <(plesk_vhost_confs)
    echo "$covered $total"
}

# ------------------------------------------------------------- plain nginx ---

# Real files (symlinks resolved) that may contain http server blocks.
plain_candidates() {
    local f
    for f in "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/conf.d/*.conf; do
        [ -e "$f" ] || continue
        f=$(readlink -f "$f")
        [ "$f" = "$(readlink -f "$NBBI_NGINX_CONF")" ] && continue
        [ -f "$f" ] && echo "$f"
    done | sort -u
}

# Inserts the include after each "server {" line that does not have it yet.
plain_inject_file() {
    local f=$1 tmp
    tmp=$(mktemp "$(dirname "$f")/.nbbi.XXXXXX")
    awk -v inc="    $(include_line) $PLAIN_TAG" -v tag="$PLAIN_TAG" '
        pending { if (index($0, tag) == 0) print inc; pending = 0 }
        { print }
        /^[ \t]*server[ \t]*\{[ \t]*(#.*)?$/ { pending = 1 }
        END { if (pending) print inc }
    ' "$f" > "$tmp"
    if cmp -s "$tmp" "$f"; then rm -f -- "$tmp"; return 1; fi
    txn_track "$f"
    chown --reference="$f" "$tmp" 2>/dev/null || true
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f"
    return 0
}

plain_sync() {
    local f dflt="$NGINX_DIR/default.d" tmp
    [ "${CFG[AUTO_INJECT]}" = yes ] || return 0
    while IFS= read -r f; do
        grep -qE '^[[:space:]]*server[[:space:]]*\{' "$f" || continue
        if [ "$NBBI_DRY_RUN" = 1 ]; then info "[dry-run] would add the enforcement include to server blocks in $f"; continue; fi
        if plain_inject_file "$f"; then
            PANEL_CHANGED=1
            state_add plain.files "$f"
        fi
    done < <(plain_candidates)
    # Rocky/RHEL: the default server in nginx.conf includes default.d/*.conf.
    if [ -d "$dflt" ] && grep -qE "include[[:space:]]+[^;]*default\.d/\*\.conf" "$NGINX_DIR/nginx.conf" 2>/dev/null; then
        [ "$NBBI_DRY_RUN" = 1 ] && return 0
        tmp=$(mktemp "$dflt/.nbbi.XXXXXX")
        printf '%s\n%s\n' "$PLAIN_TAG: enforcement for the default server" "$(include_line)" > "$tmp"
        if install_if_changed "$tmp" "$dflt/nginx-block-bad-ips.conf" 0644; then
            PANEL_CHANGED=1
            state_add plain.files "$dflt/nginx-block-bad-ips.conf"
        fi
    fi
}

plain_remove() {
    local f tmp list
    list=$(mktemp "$NBBI_VAR/.rm.XXXXXX")
    {
        [ -f "$NBBI_STATE/plain.files" ] && cat "$NBBI_STATE/plain.files"
        grep -lF "$PLAIN_TAG" "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/conf.d/*.conf "$NGINX_DIR"/default.d/*.conf 2>/dev/null
    } | while IFS= read -r f; do readlink -f "$f" 2>/dev/null; done | sort -u > "$list"
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        [ "$f" = "$(readlink -f "$NBBI_NGINX_CONF")" ] && continue
        txn_track "$f"
        if [ "$(basename "$f")" = nginx-block-bad-ips.conf ] && [ "$(basename "$(dirname "$f")")" = default.d ]; then
            rm -f -- "$f"
        else
            tmp=$(mktemp "$(dirname "$f")/.nbbi.XXXXXX")
            grep -vF "$PLAIN_TAG" "$f" > "$tmp" || true
            chown --reference="$f" "$tmp" 2>/dev/null || true
            chmod --reference="$f" "$tmp" 2>/dev/null || true
            mv -f -- "$tmp" "$f"
        fi
        REMOVED_FILES+=("$f")
    done < "$list"
    rm -f -- "$list"
}

plain_coverage() {
    local total=0 covered=0 f n c
    while IFS= read -r f; do
        n=$(grep -cE '^[[:space:]]*server[[:space:]]*\{' "$f" || true)
        c=$(grep -cF "$(include_line)" "$f" || true)
        total=$((total + n)); covered=$((covered + c))
    done < <(plain_candidates)
    echo "$covered $total"
}

# --------------------------------------------------------------- dispatch ---

panel_sync() {
    case $(effective_panel) in
        hestia) hestia_sync ;;
        plesk)  plesk_sync ;;
        none)   plain_sync ;;
    esac
}

# Removes enforcement for every panel type (safe even if never installed).
panel_remove_all() {
    hestia_remove
    [ -d /var/www/vhosts/system ] && plesk_remove
    plain_remove
}

panel_coverage() {
    case $(effective_panel) in
        hestia) hestia_coverage ;;
        plesk)  plesk_coverage ;;
        none)   plain_coverage ;;
    esac
}
