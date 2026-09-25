# shellcheck shell=bash disable=SC2034  # globals are used by the scripts that source this file
# render.sh - generates the nginx files from the cache and the configuration.
# Output is deterministic (no timestamps) so unchanged data means no reload.

HEADER="# Managed by nginx-block-bad-ips ($NBBI_URL)
# DO NOT EDIT: this file is regenerated. Configure /etc/nginx-block-bad-ips/ instead."

# This server's own addresses (never blocked).
server_addresses() {
    if command -v ip >/dev/null 2>&1; then
        ip -o addr show scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
    else
        hostname -I 2>/dev/null | tr ' ' '\n'
    fi
}

# Realip mode actually applied: managed | external | off. Stored by `update`.
realip_effective() {
    local f="$NBBI_STATE/realip.effective"
    if [ "${CFG[REALIP_MODE]}" = managed ] || [ "${CFG[REALIP_MODE]}" = off ]; then
        echo "${CFG[REALIP_MODE]}"
    elif [ -s "$f" ]; then
        cat "$f"
    else
        echo managed
    fi
}

# Prints "file" for every nginx config file (other than ours) that sets
# real_ip_header, according to nginx -T. Returns 2 when nginx -T fails: a
# broken configuration prints nothing, which must not be read as "none".
external_realip_files() {
    local bin files
    bin=$(nginx_bin) || return 2
    files=$("$bin" -T 2>/dev/null | awk -v ours="$NBBI_NGINX_DIR/" '
        /^# configuration file / { file = $4; sub(/:$/, "", file); next }
        index(file, ours) == 1 { next }
        { line = $0; sub(/#.*/, "", line) }
        line ~ /(^|[ \t;])real_ip_header[ \t]/ { print file }
    ' | sort -u; exit "${PIPESTATUS[0]}") || return 2
    [ -n "$files" ] && printf '%s\n' "$files"
    return 0
}

# Decides and stores the effective realip mode (called by `update`).
resolve_realip() {
    local files
    mkdir -p "$NBBI_STATE"
    case ${CFG[REALIP_MODE]} in
        off)     echo off > "$NBBI_STATE/realip.effective" ;;
        managed) echo managed > "$NBBI_STATE/realip.effective" ;;
        auto)
            if ! files=$(external_realip_files); then
                warn "cannot read the nginx configuration (nginx -T failed); keeping the previous real IP mode ($(cat "$NBBI_STATE/realip.effective" 2>/dev/null || echo "not decided yet"))"
                return 0
            fi
            if [ -n "$files" ]; then
                echo external > "$NBBI_STATE/realip.effective"
                printf '%s\n' "$files" > "$NBBI_STATE/realip.external"
                local missing
                missing=$(realip_missing_cloudflare | paste -sd' ' -)
                [ -n "$missing" ] && warn "the existing real IP config ($(paste -sd' ' "$NBBI_STATE/realip.external")) does not trust these Cloudflare ranges: $missing. Visitors behind them are not checked. Update that config or use REALIP_MODE=managed."
            else
                echo managed > "$NBBI_STATE/realip.effective"
                rm -f "$NBBI_STATE/realip.external"
            fi ;;
    esac
}

# Cloudflare ranges that an external real IP config does not trust (stale
# config): requests from those edges would be checked against Cloudflare's
# address, which is always allowed, so they would bypass the blocklist.
realip_missing_cloudflare() {
    local files trusted cf net
    [ -s "$NBBI_STATE/realip.external" ] || return 0
    mapfile -t files < "$NBBI_STATE/realip.external"
    trusted=$(cat "${files[@]}" 2>/dev/null | sed 's/#.*//' | awk '$1 == "set_real_ip_from" { sub(/;$/, "", $2); print $2 }')
    while IFS= read -r cf; do
        net=${cf%/*}
        [ -n "$(printf '%s\n' "$trusted" | nbbi_awk -v MODE=contains -v IP="$net" 2>/dev/null)" ] || echo "$cf"
    done < <(cloudflare_ranges)
}

trusted_proxies() { split_list "${CFG[TRUSTED_PROXIES]}" | normalize_stream plain 0 0; }

render_realip() {
    local out=$1 hdr=${CFG[REAL_IP_HEADER]}
    {
        printf '%s\n\n' "$HEADER"
        if [ "$(realip_effective)" != managed ]; then
            echo "# Real IP handling is not managed here (mode: $(realip_effective))."
        else
            echo "# Trust Cloudflare (always) and the configured proxies to report the client IP."
            { cloudflare_ranges; trusted_proxies; } | sort -u | awk '{ print "set_real_ip_from " $1 ";" }'
            echo "real_ip_header $hdr;"
            if [ "$(printf '%s' "$hdr" | tr '[:upper:]' '[:lower:]')" = x-forwarded-for ]; then
                echo "real_ip_recursive on;"
            fi
        fi
    } > "$out"
}

render_whitelist() {
    local out=$1
    {
        printf '%s\n' "$HEADER"
        {
            normalize_stream plain 0 0 < "$NBBI_SHARE/builtin-whitelist.txt"
            cloudflare_ranges
            trusted_proxies
            server_addresses | normalize_stream plain 0 0
            [ -r "$NBBI_WHITELIST" ] && normalize_stream plain 0 0 < "$NBBI_WHITELIST"
        } | sort -u | awk '{ print "    " $1 " 1;" }'
    } > "$out"
}

# Cache files of every active list (catalog + custom).
active_list_caches() {
    local name f
    while IFS= read -r name; do
        f=$(list_cache "$name")
        [ -s "$f" ] && echo "$f"
    done < <(split_list "${CFG[LISTS]}")
    while read -r name _; do
        valid_list_name "$name" || continue
        f=$(custom_cache "$name")
        [ -s "$f" ] && echo "$f"
    done < <(custom_lists)
}

render_blocklist() {
    local out=$1 files=()
    mapfile -t files < <(active_list_caches)
    {
        printf '%s\n' "$HEADER"
        if [ "${#files[@]}" -gt 0 ]; then
            sort -u "${files[@]}" | awk '{ print "    " $1 " 1;" }'
        fi
        # Test hook: produces an invalid file to exercise the rollback.
        [ "${NBBI_TEST_BREAK:-0}" = 1 ] && echo "    this-is-not-an-address 1;"
    } > "$out"
}

render_geoip() {
    local out4=$1 out6=$2 gdir="$NBBI_CACHE/geoip" sel cc zones=()
    printf '%s\n' "$HEADER" > "$out4"
    printf '%s\n' "$HEADER" > "$out6"
    [ "${CFG[GEOIP_ENABLED]}" = yes ] || return 0
    sel=$(geoip_countries | paste -sd' ' -)
    if [ -d "$gdir/v4" ]; then
        # Merging ~260k zone lines costs seconds of CPU: reuse the last result
        # while the zone data and the selected countries are unchanged.
        local key merged="$gdir/v4-merged.geo"
        key="$sel|$(stat -c '%i %Y' "$gdir/v4" 2>/dev/null)"
        if [ ! -s "$merged" ] || [ "$(cat "$merged.key" 2>/dev/null)" != "$key" ]; then
            mapfile -t zones < <(find "$gdir/v4" -name '*.zone' | sort)
            if [ "${#zones[@]}" -gt 0 ]; then
                nbbi_awk -v MODE=zones4 -v SEL="$sel" "${zones[@]}" \
                    | sort -n -k1,1 -k2,2 | nbbi_awk -v MODE=merge4 > "$merged.tmp" \
                    && mv -f "$merged.tmp" "$merged" && printf '%s\n' "$key" > "$merged.key"
            fi
        fi
        [ -s "$merged" ] && cat "$merged" >> "$out4"
    else
        warn "geoip: no IPv4 country data yet"
    fi
    {
        # Global unicast IPv6 space counts as "some other country".
        echo "    2000::/3 K;"
        while IFS= read -r cc; do
            [ -s "$gdir/v6/$cc.txt" ] && cat "$gdir/v6/$cc.txt"
        done < <(geoip_countries) | sort -u | awk '$1 != "2000::/3" { print "    " $1 " S;" }'
    } >> "$out6"
}

render_http_conf() {
    local out=$1 d=$NBBI_NGINX_DIR s k u
    {
        printf '%s\n\n' "$HEADER"
        echo "include $d/realip.conf;"
        echo
        echo "# 1 = always allowed (built-in ranges, Cloudflare, this server, whitelist.txt)"
        echo "geo \$nbbi_whitelisted {"
        echo "    default 0;"
        echo "    include $d/whitelist.geo;"
        echo "}"
        echo
        echo "# 1 = present in an enabled blocklist"
        echo "geo \$nbbi_listed {"
        echo "    default 0;"
        echo "    include $d/blocklist.geo;"
        echo "}"
        echo
        if [ "${CFG[GEOIP_ENABLED]}" = yes ]; then
            if [ "${CFG[GEOIP_MODE]}" = allow ]; then s=0; k=1; else s=1; k=0; fi
            if [ "${CFG[GEOIP_UNKNOWN]}" = block ]; then u=1; else u=0; fi
            echo "# GeoIP ($NBBI_NAME): mode=${CFG[GEOIP_MODE]} countries=${CFG[GEOIP_COUNTRIES]} unknown=${CFG[GEOIP_UNKNOWN]}"
            echo "# S = selected country, K = other country, - = no country"
            echo "geo \$nbbi_geo4 {"
            echo "    ranges;"
            echo "    default -;"
            echo "    include $d/geoip-v4.geo;"
            echo "}"
            echo "geo \$nbbi_geo6 {"
            echo "    default -;"
            echo "    include $d/geoip-v6.geo;"
            echo "}"
            echo "map \"\$nbbi_geo4\$nbbi_geo6\" \$nbbi_geo_denied {"
            echo "    default $u;"
            echo "    \"~S\" $s;"
            echo "    \"~K\" $k;"
            echo "}"
            echo "map \$uri \$nbbi_geo_path {"
            if [ -n "${CFG[GEOIP_PATHS]}" ]; then
                echo "    default 0;"
                echo "    \"~*${CFG[GEOIP_PATHS]}\" 1;"
            else
                echo "    default 1;"
            fi
            echo "}"
        else
            echo "# GeoIP disabled"
            echo "map \$nbbi_listed \$nbbi_geo_denied { default 0; }"
            echo "map \$nbbi_listed \$nbbi_geo_path { default 0; }"
        fi
        echo
        echo "# whitelist always wins; then blocklist; then GeoIP on the protected paths"
        echo "map \"\$nbbi_whitelisted\$nbbi_listed\$nbbi_geo_denied\$nbbi_geo_path\" \$nbbi_block {"
        echo "    default 0;"
        echo "    \"~^01\" 1;"
        echo "    \"~^0.11\" 1;"
        echo "}"
    } > "$out"
}

render_enforce() {
    local out=$1
    {
        printf '%s\n' "$HEADER"
        echo "if (\$nbbi_block) {"
        echo "    return ${CFG[BLOCK_STATUS]};"
        echo "}"
    } > "$out"
}

# Renders everything into directory $1 (file names = final names under
# $NBBI_NGINX_DIR, plus http.conf for the conf.d include).
render_all() {
    local stage=$1
    render_realip    "$stage/realip.conf"
    render_whitelist "$stage/whitelist.geo"
    render_blocklist "$stage/blocklist.geo"
    render_geoip     "$stage/geoip-v4.geo" "$stage/geoip-v6.geo"
    render_enforce   "$stage/enforce.conf"
    render_http_conf "$stage/http.conf"
}
